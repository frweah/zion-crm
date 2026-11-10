-- Zion Vocational Rehab CRM — drafting the weekly update
--
-- The facts, the words, and the four things a person can do with a draft.
--
-- Every sentence in a weekly update comes from this file. Nothing reads a
-- note, a contact log entry, a report or an authorization, and that is the
-- whole safety argument: a draft cannot carry health, benefits, legal or
-- employer-internal detail because there is no path from any of those into
-- it. What there is, is counts and dates.

begin;

-- ── the facts ────────────────────────────────────────────────

create or replace function public.weekly_update_facts(p_client uuid, p_from date, p_to date)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  -- Who is asking. A definer function a signed-in person can call has to
  -- check: this one would otherwise answer "how many jobs has this client
  -- applied for" to anybody with a session, a client in the portal included.
  -- verify_portal_rls asks the question that found it.
  select case when public.reader_may_answer() then jsonb_build_object(
    'from', p_from,
    'to', p_to,
    -- Jobs applied for. A count, not a list: which employer rejected
    -- somebody is between them and the employer, and a text listing five
    -- employers is a text that reads as a report.
    'applied', (select count(*) from public.lead_matches m
                 where m.client_id = p_client and m.applied_on between p_from and p_to),
    'interviews', (select count(*) from public.lead_matches m
                    where m.client_id = p_client and m.interview_on between p_from and p_to),
    -- The next interview that has not happened yet, which is the one thing a
    -- person most wants reminding of.
    'interview_next', (select min(m.interview_on) from public.lead_matches m
                        where m.client_id = p_client
                          and m.interview_on > p_to
                          and m.interview_on <= p_to + 14),
    -- A job that started this week. The employer is named here and nowhere
    -- else in the draft: the client works there, so it is not news to them,
    -- and it is the one fact worth a sentence of its own.
    'started', (select jsonb_build_object('employer', pl.employer, 'on', pl.start_date)
                  from public.placements pl
                 where pl.client_id = p_client and pl.start_date between p_from and p_to
                 order by pl.start_date limit 1),
    -- The next appointment with the practice. The kind and the time, never
    -- the title: a title is staff-written and could say anything.
    'next_appointment', (select min(e.starts_at) from public.calendar_events e
                          where e.client_id = p_client and e.starts_at > now()
                            and e.starts_at < now() + interval '14 days')
  ) end;
$$;

comment on function public.weekly_update_facts is
  'The week in counts and dates, which is all a weekly update is made of. '
  'Nothing here reads a note, a contact log entry, a report or an '
  'authorization, so there is no path from one into a text.';

revoke all on function public.weekly_update_facts(uuid, date, date) from public, anon;
grant execute on function public.weekly_update_facts(uuid, date, date) to authenticated, service_role;

-- ── the words ────────────────────────────────────────────────

create or replace function public.weekly_update_body(
  p_client uuid, p_contact uuid, p_facts jsonb
) returns text
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_may           boolean := public.reader_may_answer();
  v_client_first  text;
  v_to_first      text;
  v_subject       text;
  v_has           text;
  v_applied       integer := coalesce((p_facts ->> 'applied')::integer, 0);
  v_interviews    integer := coalesce((p_facts ->> 'interviews')::integer, 0);
  v_started       jsonb   := p_facts -> 'started';
  v_next_iv       date    := (p_facts ->> 'interview_next')::date;
  v_next_appt     timestamptz := (p_facts ->> 'next_appointment')::timestamptz;
  v_lines         text[] := '{}';
  v_opening       text;
begin
  -- The same check, for the same reason: this one would read a client's and
  -- a contact's names out to anybody with a session.
  if not v_may then
    raise exception 'Only staff and the Friday sweep draft the weekly updates.'
      using errcode = 'insufficient_privilege';
  end if;

  select split_part(btrim(c.name), ' ', 1) into v_client_first
    from public.clients c where c.id = p_client;
  if p_contact is null then
    v_to_first := v_client_first;
    v_subject := 'You';
    v_has := 'have';
  else
    select split_part(btrim(t.name), ' ', 1) into v_to_first
      from public.client_contacts t where t.id = p_contact;
    v_subject := v_client_first;
    v_has := 'has';
  end if;

  -- ── what happened ──────────────────────────────────────────
  if v_applied = 1 then
    v_lines := v_lines || format('%s applied for one job this week.', v_subject);
  elsif v_applied > 1 then
    v_lines := v_lines || format('%s applied for %s jobs this week.', v_subject, v_applied);
  end if;

  if v_interviews = 1 then
    v_lines := v_lines || format('%s had an interview.',
      case when p_contact is null then 'You' else v_client_first end);
  elsif v_interviews > 1 then
    v_lines := v_lines || format('%s had %s interviews.',
      case when p_contact is null then 'You' else v_client_first end, v_interviews);
  end if;

  if v_started is not null and v_started <> 'null'::jsonb then
    v_lines := v_lines || format('%s started at %s on %s.',
      v_subject,
      coalesce(nullif(btrim(v_started ->> 'employer'), ''), 'a new job'),
      to_char((v_started ->> 'on')::date, 'FMDay FMDD FMMonth'));
  end if;

  -- ── and what is next ───────────────────────────────────────
  if v_next_iv is not null then
    v_lines := v_lines || format('%s %s an interview on %s.', v_subject, v_has,
      to_char(v_next_iv, 'FMDay FMDD FMMonth'));
  end if;
  if v_next_appt is not null then
    v_lines := v_lines || format('%s next appointment with us is %s.',
      case when p_contact is null then 'Your' else v_client_first || '''s' end,
      to_char(v_next_appt at time zone 'America/Denver', 'FMDay FMDD FMMonth at FMHH12:MIam'));
  end if;

  -- ── the opening, and the week with nothing in it ───────────
  if p_contact is null then
    v_opening := format('Hi %s. Here is your week from Zion.', coalesce(v_to_first, 'there'));
  else
    v_opening := format('Hi %s. Here is this week about %s, from Zion.',
      coalesce(v_to_first, 'there'), coalesce(v_client_first, 'them'));
  end if;

  /*
   * A week with nothing in it asks a question instead (the owner's ruling).
   *
   * Not "no activity this week", which reads as an accusation when it is the
   * practice that has nothing to report. A question is the honest thing: the
   * record is empty, and the person at the other end knows what happened.
   */
  if array_length(v_lines, 1) is null then
    if p_contact is null then
      return v_opening || ' We have nothing to report from our side. How did you get on with what we agreed? '
             || 'Do you have any updates for us this week?';
    end if;
    return v_opening || format(' We have nothing to report from our side. Do you have any updates for us about %s this week?',
                               coalesce(v_client_first, 'them'));
  end if;

  return v_opening || ' ' || array_to_string(v_lines, ' ')
         || case when p_contact is null
                 then ' If anything has changed, reply to this text.'
                 else ' If anything has changed, reply to this text.' end;
end;
$$;

comment on function public.weekly_update_body is
  'The words of a weekly update, from the facts and nothing else. A week with '
  'nothing in it asks a question rather than reporting an absence.';

revoke all on function public.weekly_update_body(uuid, uuid, jsonb) from public, anon;
grant execute on function public.weekly_update_body(uuid, uuid, jsonb) to authenticated, service_role;

-- ── the Friday sweep ─────────────────────────────────────────

create or replace function public.draft_weekly_updates(p_week_start date)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_from  date := p_week_start;
  v_to    date := p_week_start + 6;
  v_made  integer := 0;
  r       record;
  v_facts jsonb;
begin
  if coalesce(auth.role(), '') <> 'service_role' and not public.is_active_staff() then
    raise exception 'Only the Friday sweep and staff draft the weekly updates.'
      using errcode = 'insufficient_privilege';
  end if;
  if extract(isodow from p_week_start) <> 1 then
    raise exception 'A week starts on a Monday.' using errcode = 'check_violation';
  end if;

  -- The client themselves, for every active client.
  for r in
    select c.id, c.language from public.clients c
     where c.status = 'Active' and c.merged_into is null
  loop
    v_facts := public.weekly_update_facts(r.id, v_from, v_to);
    insert into public.weekly_updates
      (week_start, client_id, contact_id, phone, language, body, facts)
    values
      (p_week_start, r.id, null, public.client_texting_number(r.id), r.language,
       public.weekly_update_body(r.id, null, v_facts), v_facts)
    on conflict do nothing;
    if found then v_made := v_made + 1; end if;
  end loop;

  -- And each contact who receives them, on an active client. A contact with
  -- no number gets a draft too: the screen says it cannot be sent and why,
  -- which is how somebody finds out that a number is missing.
  for r in
    select t.id as contact_id, t.client_id, t.phone, c.language
      from public.client_contacts t
      join public.clients c on c.id = t.client_id
     where t.active and t.receives_updates
       and c.status = 'Active' and c.merged_into is null
  loop
    v_facts := public.weekly_update_facts(r.client_id, v_from, v_to);
    insert into public.weekly_updates
      (week_start, client_id, contact_id, phone, language, body, facts)
    values
      (p_week_start, r.client_id, r.contact_id, r.phone, r.language,
       public.weekly_update_body(r.client_id, r.contact_id, v_facts), v_facts)
    on conflict do nothing;
    if found then v_made := v_made + 1; end if;
  end loop;

  return v_made;
end;
$$;

comment on function public.draft_weekly_updates is
  'One draft per active client and per contact who receives updates, for one '
  'week. Run again safely: a draft that exists is left alone, edits and all.';

revoke all on function public.draft_weekly_updates(date) from public, anon;
grant execute on function public.draft_weekly_updates(date) to authenticated, service_role;

-- ── what a person does with one ──────────────────────────────

create or replace function public.edit_weekly_update(p_id uuid, p_body text)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_staff uuid := public.current_staff_id();
begin
  if not public.keeps_client_records() then
    raise exception 'Your role does not send the weekly updates.' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(btrim(p_body), '') = '' then
    raise exception 'A text with no words in it says nothing.' using errcode = 'check_violation';
  end if;
  if length(p_body) > 1200 then
    raise exception 'That is longer than a text should be — keep it to a paragraph or two.'
      using errcode = 'check_violation';
  end if;

  update public.weekly_updates
     set body = btrim(p_body), edited_by = v_staff, edited_at = now()
   where id = p_id and state in ('Draft', 'Approved');
  if not found then
    raise exception 'That update has gone out or been closed, so it cannot be changed.'
      using errcode = 'check_violation';
  end if;
end;
$$;

revoke all on function public.edit_weekly_update(uuid, text) from public, anon, authenticated;
grant execute on function public.edit_weekly_update(uuid, text) to authenticated;

create or replace function public.approve_weekly_update(p_id uuid, p_approved boolean)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_staff uuid := public.current_staff_id();
begin
  if not public.keeps_client_records() then
    raise exception 'Your role does not send the weekly updates.' using errcode = 'insufficient_privilege';
  end if;

  update public.weekly_updates
     set state = case when p_approved then 'Approved' else 'Draft' end,
         decided_by = v_staff, decided_at = now()
   where id = p_id and state in ('Draft', 'Approved');
  if not found then
    raise exception 'That update has gone out or been closed.' using errcode = 'check_violation';
  end if;
end;
$$;

revoke all on function public.approve_weekly_update(uuid, boolean) from public, anon, authenticated;
grant execute on function public.approve_weekly_update(uuid, boolean) to authenticated;

/*
 * Sent, once the text itself is written.
 *
 * Nothing in the database sends a text. The row in `sms_messages` is the
 * send, and every rule about it - consent for that number, 8am to 9pm, STOP -
 * is on that table where it has always been. This records that a particular
 * draft became a particular text, so the two can be read against each other
 * afterwards.
 */
create or replace function public.weekly_update_sent(p_id uuid, p_sms uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_update public.weekly_updates%rowtype;
  v_sms    public.sms_messages%rowtype;
begin
  if not public.keeps_client_records() then
    raise exception 'Your role does not send the weekly updates.' using errcode = 'insufficient_privilege';
  end if;

  select * into v_update from public.weekly_updates where id = p_id for update;
  if not found then
    raise exception 'That update does not exist.' using errcode = 'no_data_found';
  end if;
  if v_update.state <> 'Approved' then
    raise exception 'Only an approved update goes out. That one is %.', lower(v_update.state)
      using errcode = 'check_violation';
  end if;

  select * into v_sms from public.sms_messages where id = p_sms;
  if not found then
    raise exception 'That text does not exist.' using errcode = 'no_data_found';
  end if;
  -- The text has to be to the person the draft is for, or the record would
  -- say one thing and the thread another.
  if v_sms.client_id is distinct from v_update.client_id
     or v_sms.contact_id is distinct from v_update.contact_id then
    raise exception 'That text was not the one this update was for.' using errcode = 'check_violation';
  end if;

  update public.weekly_updates
     set state = 'Sent', sent_at = now(), sms_id = p_sms,
         decided_by = public.current_staff_id(), decided_at = now()
   where id = p_id;
end;
$$;

revoke all on function public.weekly_update_sent(uuid, uuid) from public, anon, authenticated;
grant execute on function public.weekly_update_sent(uuid, uuid) to authenticated;

create or replace function public.discard_weekly_update(p_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if not public.keeps_client_records() then
    raise exception 'Your role does not send the weekly updates.' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'Say why it is not going.' using errcode = 'check_violation';
  end if;

  update public.weekly_updates
     set state = 'Not sent', reason = btrim(p_reason),
         decided_by = public.current_staff_id(), decided_at = now()
   where id = p_id and state in ('Draft', 'Approved');
  if not found then
    raise exception 'That update has gone out or is already closed.' using errcode = 'check_violation';
  end if;
end;
$$;

revoke all on function public.discard_weekly_update(uuid, text) from public, anon, authenticated;
grant execute on function public.discard_weekly_update(uuid, text) to authenticated;

/*
 * The Sunday night the week ends on.
 *
 * A week-old update sent on a Monday is worse than no update: it tells
 * somebody about a week that is over as though it were news. So a draft
 * nobody approved, and an approved one nobody sent, are logged as not sent
 * with the reason, and the list is empty again by Monday morning.
 */
create or replace function public.expire_weekly_updates()
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_closed integer;
begin
  if coalesce(auth.role(), '') <> 'service_role' and not public.is_active_staff() then
    raise exception 'Only the sweep closes the week.' using errcode = 'insufficient_privilege';
  end if;

  update public.weekly_updates
     set state = 'Not sent',
         reason = case when state = 'Approved'
                       then 'Approved and not sent before the week ended'
                       else 'The week ended before anybody approved it' end,
         decided_at = now()
   where state in ('Draft', 'Approved')
     -- Monday of this week: anything belonging to an earlier week is over.
     and week_start < (public.practice_today()
                       - ((extract(isodow from public.practice_today())::integer - 1) * interval '1 day'))::date;
  get diagnostics v_closed = row_count;
  return v_closed;
end;
$$;

comment on function public.expire_weekly_updates is
  'Drafts for a week that has ended, logged as not sent with the reason. A '
  'week-old update sent on a Monday reads as news and is not.';

revoke all on function public.expire_weekly_updates() from public, anon;
grant execute on function public.expire_weekly_updates() to authenticated, service_role;

commit;
