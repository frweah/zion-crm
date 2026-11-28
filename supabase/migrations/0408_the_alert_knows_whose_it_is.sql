-- The alert knows whose it is.
--
-- 0407 addressed an overdue task and a counselor follow-up to the roles that
-- work the client, because the engine's seven agreed columns carried a staff
-- *name* and a name is not something to join staff on. The whole verify
-- suite said what that cost: verify_two_assignments has held since it was
-- written that a task's alert goes to the person it is on, and it stopped.
--
-- So the engine carries the id as well. `whose` is the eighth column - the
-- task's assignee, the logger of a follow-up, the billing seat for billing
-- work, the job-search seat for job-search work - and the nightly addresses
-- each alert exactly as it did before. The visibility change reported to the
-- owner is withdrawn: nothing about who sees what has moved.
--
-- The dedupe key gains the link, so two authorizations on one client that
-- happen to need the same sentence - two waiting for service - stay two
-- alerts rather than collapsing into one.
--
-- Tolerates the old code: `whose` is an added column and the live code reads
-- next_steps by name, not by position; nothing deployed selects it yet.

begin;

drop function if exists public.next_steps(text, uuid, uuid);

create or replace function public.next_steps(
  p_scope text,
  p_person uuid,
  p_client uuid
)
 returns table (
   client_id uuid,
   "when" timestamptz,
   what text,
   who text,
   kind text,
   action_href text,
   severity integer,
   whose uuid
 )
 language sql
 stable
 security definer
 set search_path to 'public'
as $function$
  select * from (
    with day as (select public.practice_today() as today),
    /*
     * Whose work this question is about.
     *
     * Four scopes and no else-branch that means "everybody": an unknown word
     * returns nothing, because a scope nobody recognised answering with the
     * whole practice is how a Job Coach ends up reading Billing's list.
     *
     *   client  one record's strip
     *   person  the clients one member of staff is on, by either assignment -
     *           job search or billing, which is how tasks already work
     *   board   every active client, for the Clients board
     *   owner   the same, for the practice-wide view and the nightly alerts
     */
    scope_clients as (
      select c.id, c.name,
             coalesce(sa.name, sb.name) as owner_name,
             sb.name as billing_name,
             sa.name as search_name,
             coalesce(c.assigned_staff_id, c.billing_staff_id) as owner_id,
             c.billing_staff_id as billing_id,
             c.assigned_staff_id as search_id
        from public.clients c
        left join public.staff sa on sa.id = c.assigned_staff_id
        left join public.staff sb on sb.id = c.billing_staff_id
       where c.merged_into is null
         and case p_scope
               when 'client' then p_client is not null and c.id = p_client
               when 'person' then p_person is not null
                                  and c.status = 'Active'
                                  and (c.assigned_staff_id = p_person
                                       or c.billing_staff_id = p_person)
               when 'board' then c.status = 'Active'
               when 'owner' then c.status = 'Active'
               else false
             end
    ),
    threads as (
      select t.client_id,
             max(t.waiting_hours) as waiting_hours,
             min(t.quiet_days) as quiet_days,
             bool_or(coalesce(t.consent_missing, false)) as consent_missing
        from public.client_threads_board() t
        join scope_clients s on s.id = t.client_id
       group by t.client_id
    ),
    live_auths as (
      select a.id, a.client_id, coalesce(nullif(a.number, ''), a.service_type) as label
        from public.authorizations a
        join scope_clients s on s.id = a.client_id
       where a.status in ('Authorized', 'Due', 'Submitted')
         and not a.is_placeholder
    )

    -- They spoke last and nobody has answered, on any channel.
    select s.id, now(), 'Unanswered - they spoke ' || t.waiting_hours || ' hours ago',
           s.owner_name, 'reply',
           '/clients/' || s.id || '?tab=messages', 1, s.owner_id
      from scope_clients s
      join threads t on t.client_id = s.id
     where t.waiting_hours is not null

    union all
    -- An open task. The board used to show the next one whatever its date,
    -- the bell only an overdue one, and Home one due today or earlier. One
    -- rule now, and the date decides how loud it is rather than whether it
    -- exists at all.
    select s.id,
           (k.due::timestamp at time zone 'America/Denver'),
           case when k.due is null then 'Task: ' || k.title
                when k.due < (select today from day) then 'Overdue task: ' || k.title
                else 'Task: ' || k.title end,
           coalesce(ts.name, s.owner_name), 'task',
           '/clients/' || s.id || '?tab=dashboard',
           case
             when k.due is null then 4
             when k.due <= (select today from day) then 1
             when k.due <= (select today from day) + 7 then 2
             else 3
           end,
           coalesce(k.assigned_staff_id, s.owner_id)
      from scope_clients s
      join public.tasks k on k.client_id = s.id and k.status = 'Open'
      left join public.staff ts on ts.id = k.assigned_staff_id
     where p_scope <> 'person' or k.assigned_staff_id is null or k.assigned_staff_id = p_person

    union all
    -- A task on nobody's client, which only the practice-wide view can see.
    select null::uuid,
           (k.due::timestamp at time zone 'America/Denver'),
           case when k.due is not null and k.due < (select today from day)
                  then 'Overdue task: ' || k.title else 'Task: ' || k.title end,
           ts.name, 'task', '/tasks',
           case
             when k.due is null then 4
             when k.due <= (select today from day) then 1
             when k.due <= (select today from day) + 7 then 2
             else 3
           end,
           k.assigned_staff_id
      from public.tasks k
      left join public.staff ts on ts.id = k.assigned_staff_id
     where k.status = 'Open' and k.client_id is null
       and (p_scope = 'owner'
            or (p_scope = 'person' and k.assigned_staff_id = p_person))

    union all
    -- The authorization sentence, as the board and the bell already said it.
    select s.id, null::timestamptz,
           a.label || ' - ' || t.attention,
           s.billing_name, 'authorization',
           '/billing/authorizations/' || a.id,
           case
             when t.urgency <= 1 then 1
             when t.urgency <= 3 then 2
             when t.urgency <= 6 then 3
             else 4
           end,
           s.billing_id
      from scope_clients s
      join live_auths a on a.client_id = s.id
      join public.authorization_attention_for(
             array(select id from live_auths), (select today from day)) t on t.auth_id = a.id
     where coalesce(t.attention, '') <> ''

    union all
    -- A form that is holding up billing.
    select s.id, null::timestamptz,
           p.usor || ' needed - ' || p.form_name
             || coalesce(' for ' || p.month, '')
             || ' - ' || trim(to_char(p.hours_logged, 'FM999990.9')) || ' hours logged',
           s.billing_name, 'form',
           '/billing/report?client=' || s.id, 2, s.billing_id
      from scope_clients s
      join public.client_paperwork p on p.client_id = s.id
     where p.state = 'Missing'

    union all
    -- The next appointment.
    select s.id, n.at,
           'Appointment - ' || n.title, s.owner_name, 'appointment',
           '/clients/' || s.id || '?tab=dashboard',
           case when n.at < now() + interval '24 hours' then 1 else 3 end,
           s.owner_id
      from scope_clients s
      join public.client_next_up n on n.client_id = s.id and n.kind = 'Appointment'

    union all
    -- A counselor follow-up the practice said it would do.
    select s.id, (g.follow_up::timestamp at time zone 'America/Denver'),
           'Counselor follow-up due: ' || coalesce(nullif(g.topic, ''), 'no topic recorded'),
           coalesce(gs.name, s.owner_name), 'followup',
           '/clients/' || s.id || '?tab=notes', 1, coalesce(g.staff_id, s.owner_id)
      from scope_clients s
      join public.contact_log g on g.client_id = s.id
      left join public.staff gs on gs.id = g.staff_id
     where g.follow_up is not null and not g.follow_up_done
       and g.follow_up <= (select today from day)

    union all
    -- An interview this week.
    select s.id, (m.interview_on::timestamp at time zone 'America/Denver'),
           'Interview - ' || coalesce(e.name, l.title, 'a job'),
           s.search_name, 'interview',
           '/clients/' || s.id || '?tab=jobs', 2, s.search_id
      from scope_clients s
      join public.lead_matches m on m.client_id = s.id
      join public.job_leads l on l.id = m.lead_id
      left join public.employers e on e.id = l.employer_id
     where m.interview_on between (select today from day) and (select today from day) + 7

    union all
    -- Five shifts kept: the placement may be billed, on USOR 92.
    select s.id, null::timestamptz,
           'Fifth shift reached - '
             || coalesce(nullif(pl.employer, ''), 'the placement')
             || ' - USOR 92 and the placement bill are due',
           s.billing_name, 'placement',
           '/billing/report?client=' || s.id, 2, s.billing_id
      from scope_clients s
      join public.placements pl on pl.client_id = s.id
     where pl.fifth_shift_on is not null
       and not exists (
         select 1 from public.forms f
          join public.authorizations a on a.id = f.auth_id
         where f.client_id = s.id and f.template_id = 'usor92'
           and f.status <> 'Draft' and a.service_type like 'Job Placement%')

    union all
    -- Thirty days of stability: the High Quality Indicators may be billed.
    select s.id, null::timestamptz,
           'Thirty days of stability - '
             || coalesce(nullif(pl.employer, ''), 'the placement')
             || coalesce(' - ' || nullif(pl.stability_basis, ''), '')
             || ' - High Quality Indicators may be billed',
           s.billing_name, 'stability',
           '/clients/' || s.id || '?tab=billing', 2, s.billing_id
      from scope_clients s
      join public.placements pl on pl.client_id = s.id
     where pl.stability_on is not null
       and pl.stability_on + 30 <= (select today from day)
       and not exists (
         select 1 from public.authorizations a
         where a.client_id = s.id
           and a.service_type like '%HQ Indicator%'
           and a.status in ('Submitted', 'Paid'))

    union all
    -- A retention check that has come due.
    select s.id, ((pl.start_date + d.days)::timestamp at time zone 'America/Denver'),
           d.label || ' check due - ' || coalesce(nullif(pl.employer, ''), 'a placement'),
           s.search_name, 'retention',
           '/clients/' || s.id || '?tab=jobs', 2, s.search_id
      from scope_clients s
      join public.placements pl on pl.client_id = s.id
      cross join lateral (values
        (pl.check30, 30, '30 day'), (pl.check60, 60, '60 day'), (pl.check90, 90, '90 day')
      ) d(done, days, label)
     where pl.start_date is not null and d.done is null
       and pl.start_date + d.days <= (select today from day)

    union all
    -- Nobody has recorded whether they agreed to be texted.
    select s.id, null::timestamptz,
           'Texting consent not recorded - they cannot be texted until it is',
           s.owner_name, 'consent',
           '/clients/' || s.id || '?tab=profile#texting', 3, s.owner_id
      from scope_clients s
      join threads t on t.client_id = s.id
     where t.consent_missing

    union all
    -- Nobody has reached them in a fortnight, on any channel.
    select s.id, null::timestamptz,
           case when t.quiet_days is null then 'Nothing recorded with them at all'
                else 'Quiet ' || t.quiet_days || ' days' end,
           s.owner_name, 'quiet',
           '/clients/' || s.id || '?tab=dashboard', 3, s.owner_id
      from scope_clients s
      join threads t on t.client_id = s.id
     where t.quiet_days is null or t.quiet_days >= 14
  ) as rows_for_staff
   where public.reader_may_answer();
$function$;

CREATE OR REPLACE FUNCTION public.generate_notifications_on(p_today date)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  n_open      integer;
  v_today     date := coalesce(p_today, public.practice_today());
  last_month  text := to_char((date_trunc('month', v_today) - interval '1 day'), 'YYYY-MM');
  tax_year    integer := extract(year from v_today)::int - 1;
  in_season   boolean := (extract(month from v_today) = 1 and extract(day from v_today) >= 2)
                         or extract(month from v_today) = 2;
  past_target boolean := (extract(month from v_today) = 1 and extract(day from v_today) >= 15)
                         or extract(month from v_today) = 2;
  v_threshold numeric;
  n_due       integer;
begin
  drop table if exists _current;

  create temporary table _current (
    dedupe_key text primary key,
    kind text, level text, text text, roles text[], href text,
    client_id uuid, staff_id uuid
  ) on commit drop;

  /*
   * 1. Everything a client needs, from the one engine (0405).
   *
   * Four categories stood here: an authorization needing attention, an
   * overdue task, a monthly USOR form missing, and a counselor follow-up come
   * due. Each was a rule of its own, and three of the four disagreed with the
   * screen asking the same question - most plainly the task, which the bell
   * raised only once it was overdue, while the board named it whatever its
   * date and the client's own record never mentioned it at all.
   *
   * The engine answers for the whole practice in one call, so a new kind of
   * work reaches the bell without a category being added here.
   *
   * ── the dedupe key ──────────────────────────────────────
   *
   * The sentence is in the key, which is how the old authorization alert
   * carried its urgency: an item whose wording changes raises a new flag and
   * resolves the old one, rather than the first being quietly rewritten and
   * the date it started being lost. Hashed, because a key is an index and not
   * something anybody reads.
   *
   * ── who it reaches ──────────────────────────────────────
   *
   * Unchanged for the two categories addressed by role. An authorization goes
   * to Admin and Billing, and to Job Search as well when it is bad enough to
   * stop the work - the one of these that is about whether to keep serving
   * somebody rather than about billing. A form blocking billing goes to all
   * three, as the monthly-forms alert did.
   *
   * Unchanged for the other two as well, now that the engine carries the id
   * and not only the name. An overdue task and a counselor follow-up go to
   * Admin plus the role of whoever holds it, exactly as before - which is a
   * rule verify_two_assignments has held since it was written, and which the
   * first version of this broke: it addressed them to the roles that work
   * the client instead, because the seven agreed columns had a name in them
   * and a name is not something to join staff on.
   *
   * `whose` is the eighth column. The shape was settled at seven to get an
   * engine working, not to stop it carrying the one field an alert needs to
   * reach a person.
   */
  insert into _current
  select 'step:' || n.kind || ':' || coalesce(n.client_id::text, 'none')
           || ':' || md5(n.what || ' ' || n.action_href),
         n.kind,
         case when n.severity <= 2 then 'bad' else 'warn' end,
         coalesce(c.name || ' - ', '') || n.what,
         case
           when n.kind = 'authorization' and n.severity <= 1
             then array['Admin', 'Billing', 'Job Search']
           when n.kind in ('authorization', 'placement', 'stability')
             then array['Admin', 'Billing']
           when n.kind = 'form' then array['Admin', 'Billing', 'Job Search']
           else array_remove(array['Admin', ws.role], null)
         end,
         n.action_href,
         n.client_id,
         n.whose
    from public.next_steps('owner', null, null) n
    left join public.clients c on c.id = n.client_id
    left join public.staff ws on ws.id = n.whose
  on conflict (dedupe_key) do nothing;

  -- â”€â”€ 7. A foreign contractor with no W-8BEN on file â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  insert into _current
  select 'w8ben_missing:' || s.id, 'w8ben_missing', 'warn',
         s.name || ' is a foreign person with no W-8BEN on file. One is needed before payment.',
         array['Admin'], '/staff', null, s.id
    from public.staff s
    join public.contractor_profiles p on p.staff_id = s.id
   where s.active and p.tax_status = 'Foreign person' and p.w8ben_received_on is null;

  -- â”€â”€ 8. A W-8BEN expiring, or already expired â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  --      Valid through the last day of the third succeeding calendar year;
  --      60 days' notice is enough to get a fresh one signed and returned.
  insert into _current
  select 'w8ben_expiry:' || s.id || ':' || to_char(p.w8ben_expires_on, 'YYYY'),
         case when p.w8ben_expires_on < v_today then 'w8ben_expired' else 'w8ben_expiring' end,
         case when p.w8ben_expires_on < v_today then 'bad' else 'warn' end,
         case when p.w8ben_expires_on < v_today
              then s.name || '''s W-8BEN expired on ' || p.w8ben_expires_on || '. A new one is needed.'
              else s.name || '''s W-8BEN expires ' || p.w8ben_expires_on || ' â€” ask for a new one.'
         end,
         array['Admin'], '/staff', null, s.id
    from public.staff s
    join public.contractor_profiles p on p.staff_id = s.id
   where s.active
     and p.tax_status = 'Foreign person'
     and p.w8ben_expires_on is not null
     and p.w8ben_expires_on <= v_today + 60;

  -- â”€â”€ 9. January: the threshold the CPA confirms â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  if in_season then
    select federal_threshold into v_threshold from public.tax_years where year = tax_year;

    if v_threshold is null then
      insert into _current values (
        'tax_threshold:' || tax_year, 'tax_threshold_unconfirmed', 'warn',
        'Confirm the ' || tax_year || ' federal 1099-NEC threshold with your CPA, and whether Utah requires a state copy. Nothing can be generated until it is entered.',
        array['Admin'], '/staff?tab=tax', null, null);
    else
      -- â”€â”€ 10. January: the run itself â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
      select count(*) into n_due from public.form_1099_candidates(tax_year);

      if n_due > 0 and not exists (
        select 1 from public.form_1099_runs where year = tax_year
      ) then
        insert into _current values (
          'form_1099_run:' || tax_year, 'form_1099_due',
          case when past_target then 'bad' else 'warn' end,
          n_due || ' contractor' || case when n_due = 1 then '' else 's' end ||
          ' need a ' || tax_year || ' 1099-NEC. ' ||
          case when past_target
               then 'Past the 15 January target â€” recipient copies and filing are due by 31 January.'
               else 'Aim to generate by 15 January; delivery and filing are due by 31 January.'
          end,
          array['Admin'], '/staff?tab=tax', null, null);
      end if;
    end if;
  end if;

  -- 11. Certifications and clearances.
  --
  -- Missing and expired are the same colour on purpose: somebody without a
  -- current background check is in the same position whether the card ran out
  -- or was never recorded, and the difference is a matter for the
  -- conversation rather than for the flag.
  --
  -- The state is in the dedupe key, so a card moving from Expiring to Expired
  -- raises a new flag and resolves the old one, rather than quietly rewriting
  -- the first and losing the date it started.
  insert into _current
  select 'credential:' || a.staff_id || ':' || a.type_key || ':' || a.state,
         'credential_' || lower(a.state),
         case when a.state in ('Expired', 'Missing') then 'bad' else 'warn' end,
         case a.state
           when 'Missing' then
             a.staff_name || ' has no ' || a.label || ' on file.'
           when 'Expired' then
             a.staff_name || '''s ' || a.label || ' expired ' || a.expires_on || '.'
           else
             a.staff_name || '''s ' || a.label || ' expires ' || a.expires_on ||
             ' - ' || a.days_left || ' days.'
         end,
         array['Admin'],
         '/admin/staff',
         null,
         -- Named so the person themselves sees it, and nobody else in their
         -- role does. A colleague has no business knowing whose CPR card has
         -- run out.
         a.staff_id
    from public.credential_attention a
   where a.state in ('Expired', 'Missing', 'Expiring');

  -- 11b. A card somebody put forward themselves, waiting for Admin to look.
  --      Admin only: it is a request to check, not news for the person.
  insert into _current
  select 'credential:' || a.staff_id || ':' || a.type_key || ':' || a.state,
         'credential_awaiting_check',
         'warn',
         a.staff_name || ' put forward their ' || a.label || ' - check it against the scan and verify.',
         array['Admin'],
         '/admin/people/' || a.staff_id,
         null,
         null
    from public.credential_attention a
   where a.state = 'Awaiting check';

  -- 12. Continuing education, but only once it matters.
  --
  -- Somebody being short of hours in February is not news; being short in
  -- October is. Raising it in January would train everybody to ignore it for
  -- nine months and then miss it in the tenth.
  if extract(month from v_today) >= 10 then
    insert into _current
    select 'ce_short:' || a.staff_id || ':' || extract(year from v_today),
           'credential_ce',
           case when extract(month from v_today) = 12 then 'bad' else 'warn' end,
           a.staff_name || ' has ' || a.hours_this_year || ' of ' ||
           a.hours_target || ' training hours for the year.',
           array['Admin'],
           '/paperwork',
           null,
           a.staff_id
      from public.credential_attention a
     where a.state = 'Outstanding';
  end if;

  -- 13. Onboarding steps still open (0100). Named to the person, so it is on
  --     their own dashboard, and addressed to Admin, who is waiting on it.
  --     Only for somebody who has signed in: before that the invite is what
  --     is outstanding, and Admin resends it.
  insert into _current
  select 'onboarding_open:' || o.staff_id,
         'onboarding_open',
         'warn',
         s.name || ' has ' || cardinality(public.onboarding_open_steps(o.staff_id)) ||
           ' onboarding step' || case when cardinality(public.onboarding_open_steps(o.staff_id)) = 1 then '' else 's' end ||
           ' still to do.',
         array['Admin'],
         '/onboarding',
         null,
         o.staff_id
    from public.staff_onboarding o
    join public.staff s on s.id = o.staff_id
   where o.completed_at is null and s.active and s.accepted_at is not null
     and cardinality(public.onboarding_open_steps(o.staff_id)) > 0;

  -- 14. Onboarding finished, for a fortnight after, so Admin sees it however
  --     long they were away. Raised the moment it happens by refresh_onboarding;
  --     kept here so the nightly reconcile does not resolve it.
  insert into _current
  select 'onboarding_done:' || o.staff_id,
         'onboarding_done',
         'warn',
         s.name || ' finished onboarding.' ||
           case when exists (select 1 from public.staff_files f
                              where f.staff_id = o.staff_id and f.category = 'I-9' and f.inspected_at is null)
                then ' Their I-9 documents still need inspecting in person.' else '' end,
         array['Admin'],
         '/admin/people/' || o.staff_id,
         null,
         null
    from public.staff_onboarding o
    join public.staff s on s.id = o.staff_id
   where o.completed_at >= v_today - 14;

  -- 12. An account over its budget this month (E2).
  --
  -- Only cost accounts, only where somebody actually set a budget, and only
  -- past a tolerance the owner sets - because an account a penny over budget
  -- on the second of the month is noise, and an alert that is noise is one
  -- people learn to click past.
  insert into _current
  select 'budget_over:' || v.account_id || ':' || to_char(v_today, 'YYYY-MM'),
         'budget_over',
         'warn',
         v.name || ' is ' || to_char(v.actual - v.budget, 'FM999999990.00') || ' over its budget for '
           || to_char(v_today, 'FMMonth') || ' (' || to_char(v.actual, 'FM999999990.00')
           || ' against ' || to_char(v.budget, 'FM999999990.00') || ').',
         array['Admin'],
         '/books/budget',
         null,
         null
    from public.ledger_budget_variance(date_trunc('month', v_today)::date,
                                       (date_trunc('month', v_today) + interval '1 month - 1 day')::date) v
    cross join lateral (
      select coalesce(s.budget_tolerance, 10) as tolerance
        from public.ledger_settings s
        join public.ledger_entities e on e.id = s.entity_id and e.is_default
    ) t
   where v.over
     and v.budget > 0
     and v.actual > v.budget * (1 + t.tolerance / 100.0);

  -- 13. The cash forecast dropping below the floor the owner set (E2).
  --
  -- One alert, naming the first week it happens, rather than one per week:
  -- thirteen alerts saying the same thing is the same thing said thirteen
  -- times. Null floor means the owner has not asked to be warned.
  insert into _current
  select 'cash_floor:' || to_char(f.week, 'YYYY-MM-DD'),
         'cash_floor',
         'bad',
         'The cash forecast drops to ' || to_char(f.closing, 'FM999999990.00') || ' in the week of '
           || to_char(f.week, 'FMDD Month') || ', below the ' || to_char(f.floor_at, 'FM999999990.00')
           || ' floor.',
         array['Admin'],
         '/books/forecast',
         null,
         null
    from (
      select c.week, c.closing, s.cash_floor as floor_at,
             row_number() over (order by c.week) as rank
        from public.ledger_cash_forecast(90) c
        cross join (
          select s.cash_floor
            from public.ledger_settings s
            join public.ledger_entities e on e.id = s.entity_id and e.is_default
        ) s
       where s.cash_floor is not null and c.closing < s.cash_floor
    ) f
   where f.rank = 1;

  -- â”€â”€ whose alert it is â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  -- A client's billing alerts are addressed to whoever bills for them
  -- (0121), and the rest of a client's to whoever works their job search.
  -- The roles above are unchanged: this says who it is for, not who may see
  -- it, so nothing is hidden from Admin or from Billing at large.
  update _current c
     set staff_id = coalesce(
           case when c.kind in ('authorization', 'monthly_forms')
                then cl.billing_staff_id else cl.assigned_staff_id end,
           cl.assigned_staff_id)
    from public.clients cl
   where cl.id = c.client_id and c.staff_id is null;

  -- â”€â”€ reconcile â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  insert into public.notifications
    (dedupe_key, kind, level, text, roles, href, client_id, staff_id)
  select c.dedupe_key, c.kind, c.level, c.text, c.roles, c.href, c.client_id, c.staff_id
    from _current c
  on conflict (dedupe_key) do update set
    kind = excluded.kind, level = excluded.level, text = excluded.text,
    roles = excluded.roles, href = excluded.href, resolved_at = null;

  update public.notifications n
     set resolved_at = now()
   where n.resolved_at is null
     and not exists (select 1 from _current c where c.dedupe_key = n.dedupe_key);

  select count(*) into n_open from public.notifications where resolved_at is null;
  return n_open;
end;
$function$;

comment on function public.next_steps(text, uuid, uuid) is
  'What needs doing, for one client, one person, the board or the practice. '
  'The only answer: every screen reads this one and none computes its own.';

revoke all on function public.next_steps(text, uuid, uuid) from public;
revoke all on function public.next_steps(text, uuid, uuid) from anon;
grant execute on function public.next_steps(text, uuid, uuid) to authenticated;
grant execute on function public.next_steps(text, uuid, uuid) to service_role;

commit;
