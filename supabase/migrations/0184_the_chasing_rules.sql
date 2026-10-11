-- Zion Vocational Rehab CRM — the chasing rules
--
-- Rules 6, 7 and 8 of the Intake Automation Brief. Rules 1-5 were about what
-- arrives; these three are about what does not:
--
--   6. A referral with no authorization after a week. The counselor is asked,
--      twice, and after that it is Margaret's to chase.
--   7. An authorization about to run out with work still in it. Nobody is
--      emailed automatically - Margaret is given the draft and sends it.
--   8. A client hired. The placement clock starts, and the paperwork that
--      becomes due is raised on the authorization that will be billed.
--
-- Rules 6 and 7 are the practice's day read once: they look at what is on file
-- and say what is owed, which is what generate_notifications() has done since
-- 0011. Rule 8 is not - it happens the moment somebody records a hire, so it
-- is a trigger on that.

-- ── who hears about the money ────────────────────────────────
-- Rule 7's notification "also goes to billing@zionvocrehab.com". That is
-- Melanie today, and a setting rather than an address in a function, for the
-- same reason intake_staff_id is (0182): a role no longer names a person.
alter table public.org_settings
  add column if not exists billing_notify_staff_id uuid references public.staff (id);

comment on column public.org_settings.billing_notify_staff_id is
  'Who else hears when an authorization is about to run out. Melanie, at billing@zionvocrehab.com, at the time of writing.';

grant select (billing_notify_staff_id) on public.org_settings to authenticated;
grant update (billing_notify_staff_id) on public.org_settings to authenticated;

update public.org_settings set
  billing_notify_staff_id = coalesce(billing_notify_staff_id,
    (select id from public.staff
      where lower(email) = 'billing@zionvocrehab.com' and active
      order by created_at limit 1));

-- ── what was sent, and when ──────────────────────────────────
-- The nudges have to be countable: twice and no more (Rule 6), once per
-- authorization (Rule 7). The contact log says a nudge was sent, which is what
-- the brief asks for and what a person reads - but it is prose, and counting
-- prose is how something gets sent three times. So the count lives here.
create table if not exists public.chase_sent (
  id         uuid primary key default gen_random_uuid(),
  rule       text not null,
  client_id  uuid references public.clients (id) on delete cascade,
  auth_id    uuid references public.authorizations (id) on delete cascade,
  nth        int not null default 1,
  to_address text not null default '',
  sent_at    timestamptz not null default now(),
  constraint chase_sent_rule_known check (rule = any (array['referral nudge', 'ending chase'])),
  constraint chase_sent_nth_sane check (nth between 1 and 2)
);

create unique index if not exists chase_sent_once
  on public.chase_sent (rule, coalesce(client_id, auth_id), nth);

comment on table public.chase_sent is
  'Which chasing email has gone out, so a nudge is sent twice and never a third time. The contact log is what a person reads; this is what the rule counts.';

-- Deliberately no body column. The first version kept one and
-- verify_mail.sql refused it: nothing in this system stores a message body,
-- and the few columns called `body` are the practice''s own templates rather
-- than anything sent or received. Keeping the sent text here would have been
-- the first exception that is neither - and it would have been pointless, as
-- the words are built from a template by referrals_without_authorization and
-- can be read there, while the contact log already records that the nudge
-- went and what it was about.

alter table public.chase_sent enable row level security;
drop policy if exists chase_sent_read on public.chase_sent;
create policy chase_sent_read on public.chase_sent
  for select using ((select public.is_active_staff()));
grant select on public.chase_sent to authenticated;
select public.apply_system_read_only('public.chase_sent'::regclass);

/**
 * When a client's referral was received.
 *
 * Three places could answer and they disagree in the ordinary case, so the
 * earliest wins: the contact log entry the intake writes (which carries the
 * date off the form, and is the truest answer), the stage history's arrival at
 * Referral, and failing both the day the record was made.
 */
create or replace function public.referral_received_on(p_client uuid)
returns date
language sql stable security definer set search_path = public as $$
  select least(
    coalesce((select min(l.date) from public.contact_log l
               where l.client_id = p_client and l.topic = 'Referral received'), 'infinity'::date),
    coalesce((select min(h.at)::date from public.client_stage_history h
               where h.client_id = p_client and h.stage = 'Referral'), 'infinity'::date),
    coalesce((select c.created_at::date from public.clients c where c.id = p_client), 'infinity'::date)
  )
$$;

comment on function public.referral_received_on is
  'The day a client''s referral arrived: the contact log first, then the stage history, then the day the record was made.';

/**
 * Rule 6 — a referral with no authorization.
 *
 * Returns what is owed today, one row per client, for the job to act on. The
 * decision is here rather than in the job so it can be tested without a
 * mailbox, and so "what would it send today" is a question somebody can ask.
 *
 *   `nth` 1 at seven days, 2 at fourteen. `send` is true only on those two
 *   days and only if that one has not gone yet.
 *
 * Why exactly those two days and not "seven days or more": the brief says
 * "Repeat once at 14 days with the same text; after that, task only." A client
 * who has been at Referral for three months has had both days pass, so they
 * get the task and no email. That is the reading that matters on the day this
 * goes live - the other one would email every counselor in the practice about
 * every referral ever left open.
 */
create or replace function public.referrals_without_authorization(p_today date default null)
returns table (
  client_id      uuid,
  client_name    text,
  counselor_id   uuid,
  counselor_name text,
  counselor_email text,
  received_on    date,
  days_waiting   int,
  nth            int,
  send           boolean,
  body           text
)
language sql stable security definer set search_path = public as $$
  with today as (select coalesce(p_today, public.practice_today()) as d),
  waiting as (
    select c.id, c.name, c.counselor_id, co.name as counselor_name, co.email as counselor_email,
           public.referral_received_on(c.id) as received_on,
           (select d from today) - public.referral_received_on(c.id) as days_waiting
      from public.clients c
      left join public.counselors co on co.id = c.counselor_id
     where c.stage = 'Referral'
       and c.status = 'Active'
       and c.merged_into is null
       and not exists (
         select 1 from public.authorizations a
          where a.client_id = c.id and a.parent_id is null
       )
  )
  select w.id, w.name, w.counselor_id, coalesce(w.counselor_name, ''), coalesce(w.counselor_email, ''),
         w.received_on, w.days_waiting,
         case when w.days_waiting >= 14 then 2 else 1 end as nth,
         -- Sent on the seventh and the fourteenth day only, and only once each.
         (w.days_waiting in (7, 14)
          and coalesce(w.counselor_email, '') <> ''
          and not exists (
            select 1 from public.chase_sent s
             where s.rule = 'referral nudge' and s.client_id = w.id
               and s.nth = case when w.days_waiting >= 14 then 2 else 1 end
          )) as send,
         format(
           'Hi %s — we received %s''s referral on %s and wanted to check whether an authorization is on its way. Thank you.',
           coalesce(nullif(split_part(btrim(coalesce(w.counselor_name, '')), ' ', 1), ''), 'there'),
           w.name,
           to_char(w.received_on, 'FMDD FMMonth YYYY')
         ) as body
    from waiting w
   where w.days_waiting >= 7
   order by w.days_waiting desc, w.name
$$;

comment on function public.referrals_without_authorization is
  'Rule 6: clients at Referral with no authorization after a week, and the words to send. send is true only on day seven and day fourteen, and only once each.';

revoke all on function public.referrals_without_authorization(date) from anon, authenticated;
grant execute on function public.referrals_without_authorization(date) to authenticated;

-- An earlier shape of this took the body it was about to send. It does not
-- any more (see above), and the old one would be left behind as a second
-- overload, making every unqualified reference to the name ambiguous.
drop function if exists public.record_referral_nudge(uuid, int, text, text);

/**
 * Record a nudge: the contact log for a person to read, the count for the rule.
 *
 * Both or neither - a send recorded in one and not the other is how a
 * counselor gets asked twice in a morning.
 */
create or replace function public.record_referral_nudge(
  p_client uuid,
  p_nth    int,
  p_to     text
)
returns boolean
language plpgsql security definer set search_path = public as $$
declare
  cfg public.org_settings;
  v_counsel uuid;
begin
  select * into cfg from public.org_settings limit 1;
  select counselor_id into v_counsel from public.clients where id = p_client;

  insert into public.chase_sent (rule, client_id, nth, to_address)
  values ('referral nudge', p_client, p_nth, lower(btrim(coalesce(p_to, ''))))
  on conflict do nothing;
  if not found then
    return false;   -- already sent; the caller sends nothing
  end if;

  insert into public.contact_log (client_id, counselor_id, date, method, topic, outcome, staff_id)
  values (p_client, v_counsel, public.practice_today(), 'Email',
          'Authorization chased',
          format('Asked the counselor whether an authorization is coming (nudge %s of 2).', p_nth),
          cfg.intake_staff_id);
  return true;
end;
$$;

comment on function public.record_referral_nudge(uuid, int, text) is
  'Rule 6: record that the counselor was asked - the count and the contact log together. False when it has already gone.';

revoke all on function public.record_referral_nudge(uuid, int, text) from anon, authenticated;

/**
 * Rule 7 — an authorization about to run out with work still in it.
 *
 * Thirty days before the end date, and nothing is emailed: Margaret is given
 * the task and the draft, and she sends it. That is the brief's decision and a
 * good one - a renewal request is a conversation, and the practice's side of it
 * should not arrive automatically.
 *
 * "Still has hours remaining (or is a flat fee not yet submitted)" is read off
 * authorization_economics, which already knows that a coaching parent's hours
 * are logged on its months (0172).
 */
create or replace function public.authorizations_ending_soon(p_today date default null)
returns table (
  auth_id        uuid,
  client_id      uuid,
  client_name    text,
  auth_number    text,
  service_type   text,
  end_date       date,
  days_left      int,
  hours_left     numeric,
  counselor_name text,
  counselor_email text,
  body           text
)
language sql stable security definer set search_path = public as $$
  with today as (select coalesce(p_today, public.practice_today()) as d)
  select e.auth_id, e.client_id, c.name, e.auth_number, e.service_type, e.end_date,
         e.end_date - (select d from today) as days_left,
         e.hours_left,
         coalesce(co.name, ''), coalesce(co.email, ''),
         format(
           'Hi %s — %s''s authorization %s for %s runs to %s. %s Could we arrange a renewal so the work can continue? Thank you.',
           coalesce(nullif(split_part(btrim(coalesce(co.name, '')), ' ', 1), ''), 'there'),
           c.name,
           coalesce(nullif(btrim(e.auth_number), ''), '(no number)'),
           e.service_type,
           to_char(e.end_date, 'FMDD FMMonth YYYY'),
           case when e.hours_left is not null
                then format('There are %s hours left on it.', public.fmt_hours(e.hours_left))
                else 'The service is not yet submitted.' end
         ) as body
    from public.authorization_economics e
    join public.clients c on c.id = e.client_id
    left join public.counselors co on co.id = c.counselor_id
   where e.end_date is not null
     and e.end_date - (select d from today) between 0 and 30
     and e.status not in ('Paid', 'Closed', 'Submitted')
     and c.status <> 'Closed'
     and not exists (select 1 from public.authorizations p where p.parent_id = e.auth_id)
     and (
       (e.rate_type = 'Hourly' and coalesce(e.hours_left, 0) > 0)
       or (e.rate_type = 'Flat Fee' and e.status <> 'Submitted')
     )
   order by e.end_date, c.name
$$;

comment on function public.authorizations_ending_soon is
  'Rule 7: authorizations inside thirty days of their end date with work still in them, and the renewal request to send. Nothing is sent from here - Margaret sends it.';

revoke all on function public.authorizations_ending_soon(date) from anon, authenticated;
grant execute on function public.authorizations_ending_soon(date) to authenticated;

-- ── Rule 8: the placement starts the clock ───────────────────
--
-- Somebody records a hire, and four things become true at once. Until now all
-- four were somebody's to remember, and the message on the screen said so:
-- "Create the placement when you are ready - it is a separate step on
-- purpose." That was a deliberate decision and the brief reverses it, so it is
-- worth saying plainly that this is the reversal: a hire now starts the clock
-- by itself.
--
-- What it does, and what it deliberately does not:
--
--   The hire date is recorded, and the placement gets it as its start date.
--   One is created if the match has none, because there is nothing to hang a
--   start date on otherwise.
--
--   The four-week milestone is set as the match's own follow-up date, not as a
--   calendar entry of its own. sync_match_reminders already turns that field
--   into a task and a calendar event and pushes it to Outlook (0117) - so this
--   sets the date and lets the one mechanism do the rest. A second way to put
--   a milestone on the calendar is a second thing to keep right.
--
--   The placement authorization gets the first day of work, which is what its
--   bill-by is derived from: Job Placement's bill-by anchor is
--   'first_work_day' in bill_by_defaults, plus however many days that row
--   says - seven, since 0188. The number is not written here; it is computed
--   by bill_by_for from the one fact this records, which is the only way the
--   two can never disagree and the reason 0188 had to change nothing but a
--   row.
--
--   The outstanding forms are *already* USOR 60 and 92. form_templates marks
--   both required_for_billing for Job Placement, and authorization_missing_forms
--   reads that - so there is nothing to raise. verify_the_chasing_rules.sql
--   asserts it rather than this writing it a second time.
--
--   It does not create the authorization. If there is no placement
--   authorization, Margaret is asked to request one, which is the brief's own
--   carve-out and the right one: an authorization is USOR's to issue.
create or replace function public.hire_starts_the_clock()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_hired date;
begin
  -- Only the move into Hired, and only once. An edit to a match that was
  -- already hired must not reset the clock to today.
  if new.status <> 'Hired' or coalesce(old.status, '') = 'Hired' then
    return new;
  end if;

  -- The hire date, which has to be set before the row is written. The rest of
  -- Rule 8 needs the row to exist, so it happens after (placement_clock_started).
  new.decided_on := coalesce(new.decided_on, public.practice_today());
  return new;
end;
$$;

drop trigger if exists lead_matches_hired on public.lead_matches;
create trigger lead_matches_hired
  before update on public.lead_matches
  for each row execute function public.hire_starts_the_clock();

comment on function public.hire_starts_the_clock is
  'Rule 8: a hire records its date. The rest of it needs the written row, so it happens after.';

/**
 * And then everything a hire starts, without anybody remembering to ask.
 *
 * An AFTER trigger rather than a call from the screen, because the brief says
 * "when a job match is set to Hired" - not "when somebody hires through the
 * client record". A hire recorded any other way starts the same clock.
 */
create or replace function public.hired_starts_everything()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'Hired' and coalesce(old.status, '') <> 'Hired' then
    perform public.placement_clock_started(new.id);
  end if;
  return null;
end;
$$;

drop trigger if exists lead_matches_hired_after on public.lead_matches;
create trigger lead_matches_hired_after
  after update of status on public.lead_matches
  for each row execute function public.hired_starts_everything();

comment on function public.hired_starts_everything is
  'Rule 8: a hire starts the placement, the milestone and the paperwork, however the hire was recorded.';

/**
 * The rest of Rule 8, which needs rows rather than a changed row.
 *
 * Separate from the trigger above because it writes to three other tables and
 * notifies two people, and a BEFORE trigger is the wrong place to do that -
 * the row it is deciding about has not been written yet. Called after.
 */
create or replace function public.placement_clock_started(p_match uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  cfg        public.org_settings;
  m          public.lead_matches;
  v_client   public.clients;
  v_employer text := '';
  v_title    text := '';
  v_place    uuid;
  v_auth     uuid;
  v_hired    date;
  v_due      date;
  v_notify   jsonb := '[]'::jsonb;
  r          record;
begin
  select * into cfg from public.org_settings limit 1;
  select * into m from public.lead_matches where id = p_match;
  if not found or m.status <> 'Hired' then
    raise exception 'That job match is not a hire (%).', p_match using errcode = 'no_data_found';
  end if;
  select * into v_client from public.clients where id = m.client_id;

  v_hired := coalesce(m.decided_on, public.practice_today());

  -- Four weeks, and this is the retention milestone only: whether the
  -- placement held. It was the same number as the bill-by until 0188 moved
  -- that to seven days, which is exactly why the two are now named apart -
  -- one number serving two purposes is one of them changing and breaking the
  -- other. Billing's date is computed from bill_by_defaults, below.
  v_due := v_hired + 28;

  select l.title, e.name into v_title, v_employer
    from public.job_leads l join public.employers e on e.id = l.employer_id
   where l.id = m.lead_id;

  -- ── the four-week retention milestone ──────────────────────
  -- Rei's check on whether the placement held, and nothing to do with when
  -- the bill goes out (0188). Set as the match's own follow-up date: the existing
  -- reminder sync (0117) turns that field into a task and a calendar entry and
  -- pushes it to Outlook. Written as its own update statement naming the
  -- column, because that sync fires on `update of ... follow_up_on` - which is
  -- about the columns a statement names, not about what changed. A BEFORE
  -- trigger setting the field does not fire it, which is how the first version
  -- of this quietly put nothing on the calendar.
  if m.follow_up_on is null then
    update public.lead_matches set follow_up_on = v_due where id = p_match;
  end if;

  -- ── the placement, with its start date ─────────────────────
  v_place := m.placement_id;
  if v_place is null then
    insert into public.placements (client_id, employer, title, start_date)
    values (m.client_id, coalesce(v_employer, ''), coalesce(v_title, ''), v_hired)
    returning id into v_place;
    update public.lead_matches set placement_id = v_place where id = p_match;
  else
    -- An existing placement keeps everything except a start date it has not
    -- got. What somebody typed is not overwritten by a hire date.
    update public.placements set start_date = coalesce(start_date, v_hired)
     where id = v_place;
  end if;

  -- ── the placement authorization ────────────────────────────
  select a.id into v_auth
    from public.authorizations a
   where a.client_id = m.client_id
     and a.service_type in ('Job Placement', 'Job Placement (SE)')
     and a.status not in ('Paid', 'Closed')
     and a.parent_id is null
   order by a.start_date desc nulls last
   limit 1;

  if v_auth is null then
    -- The brief's carve-out: a hire does not conjure an authorization.
    for r in select * from public.notify_person(
      cfg.intake_staff_id, 'placement_authorization',
      format('%s was hired at %s on %s and has no placement authorization. Ask the counselor for one.',
             v_client.name, coalesce(nullif(v_employer, ''), 'an employer'),
             to_char(v_hired, 'FMDD FMMonth')),
      p_match::text, '/clients/' || m.client_id::text, m.client_id,
      format('Request a placement authorization for %s', v_client.name),
      public.practice_today(), 'bad', null)
    loop
      v_notify := v_notify || jsonb_build_object('name', r.staff_name, 'email', r.email, 'message', r.message);
    end loop;
  else
    -- The first day of work is the fact; the bill-by follows from it, computed
    -- by the same function the rest of the billing uses - a week, since 0188,
    -- and nothing here needs to know that.
    update public.authorizations a set
      first_work_day = coalesce(a.first_work_day, v_hired),
      bill_by = public.bill_by_for(a.service_type, coalesce(a.received_on, a.created_at::date),
                                   a.period, coalesce(a.first_work_day, v_hired))
     where a.id = v_auth;
  end if;

  -- ── Rei hears, with the milestone date ─────────────────────
  if cfg.placement_staff_id is not null then
    for r in select * from public.notify_person(
      cfg.placement_staff_id, 'placement_authorization',
      format('%s started at %s on %s. The four-week milestone is %s.',
             v_client.name, coalesce(nullif(v_employer, ''), 'an employer'),
             to_char(v_hired, 'FMDD FMMonth'), to_char(v_due, 'FMDD FMMonth')),
      p_match::text || ':hired', '/clients/' || m.client_id::text, m.client_id,
      format('Four weeks since %s started at %s', v_client.name,
             coalesce(nullif(v_employer, ''), 'an employer')),
      v_due, 'warn', null)
    loop
      v_notify := v_notify || jsonb_build_object('name', r.staff_name, 'email', r.email, 'message', r.message);
    end loop;
  end if;

  return jsonb_build_object(
    'placement_id', v_place,
    'authorization_id', v_auth,
    'started_on', v_hired,
    'milestone_on', v_due,
    'notify', v_notify);
end;
$$;

comment on function public.placement_clock_started is
  'Rule 8: the placement and its start date, the first day of work on the authorization its bill-by is derived from, and Rei told the milestone date. Asks for an authorization rather than creating one.';

revoke all on function public.placement_clock_started(uuid) from anon, authenticated;
grant execute on function public.placement_clock_started(uuid) to authenticated;
