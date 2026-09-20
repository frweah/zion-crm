-- Zion Vocational Rehab CRM — the two dates the billing pathway turns on
--
-- From the CRP billing pathway (owner, 20 Sept 2026). Two moments decide when
-- the practice may bill, and the CRM held neither, so both were being tracked
-- in somebody's head:
--
--   The fifth shift. Job Placement may not be billed until the client has
--   kept the job for five shifts - a split shift counts as one - and USOR 92
--   is filled in and sent at that moment. Until then a placement is a
--   placement, not a claim.
--
--   Stability. High Quality Indicators are billed at thirty days of
--   stability, and the stability date is the date that goes on that invoice.
--   For SJBT that is thirty days of competitive integrated employment meeting
--   the stability criteria; for Supported Employment it is 80/20 or twenty
--   four months with extended services in place. Which of those applies is a
--   judgement about a person, so it is recorded rather than computed.
--
-- Deliberately not computed from anything. A shift is a shift somebody
-- worked, not a row in this system, and stability is a counselor's decision.
-- What the CRM can do is carry the dates once somebody knows them, and stop
-- the claim being forgotten - which is the part that was being lost.

alter table public.placements
  add column if not exists shifts_worked integer not null default 0
    check (shifts_worked >= 0 and shifts_worked <= 500),
  -- The date the fifth shift was worked: what USOR 92 is dated and what the
  -- placement invoice is dated. Null until it happens.
  add column if not exists fifth_shift_on date,
  -- The date the client became stable, which is the High Quality Indicator
  -- invoice date.
  add column if not exists stability_on date,
  -- Which rule was met, because the two have different tests and a reader a
  -- year later should not have to guess which one somebody applied.
  add column if not exists stability_basis text not null default ''
    check (stability_basis in ('', 'SJBT', 'SE'));

comment on column public.placements.shifts_worked is
  'Shifts worked since starting. A split shift counts as one (CRP billing pathway).';
comment on column public.placements.fifth_shift_on is
  'The date the fifth shift was worked: Job Placement may be billed from here, on USOR 92.';
comment on column public.placements.stability_on is
  'The stability date: what a High Quality Indicator invoice is dated.';

-- A placement cannot be stable before it started, and the fifth shift cannot
-- have happened before the first.
alter table public.placements drop constraint if exists placements_dates_in_order;
alter table public.placements add constraint placements_dates_in_order check (
  (fifth_shift_on is null or start_date is null or fifth_shift_on >= start_date)
  and (stability_on is null or start_date is null or stability_on >= start_date)
);

-- ── what these two unlock ───────────────────────────────────
-- Added to client_next_actions (0109) rather than to a screen, so the record,
-- the caseload list and anything else asking "what is due" keep one answer.
create or replace function public.client_next_actions(p_client uuid)
returns table (kind text, title text, detail text, href text, urgency integer)
language sql stable security definer set search_path = public as $$
  with c as (select * from public.clients where id = p_client)
  -- The next appointment, from client_next_up rather than from the events
  -- table: that view already knows an appointment being withdrawn from
  -- Outlook is not one, and a second definition here would forget.
  (select 'appointment',
         'Appointment ' || to_char(n.at at time zone 'America/Denver', 'Dy DD Mon, FMHH12:MIam'),
         n.title,
         '/clients/' || p_client || '?tab=activity',
         case when n.at < now() + interval '24 hours' then 1 else 4 end
    from public.client_next_up n
   where n.client_id = p_client and n.kind = 'Appointment'
   order by n.at limit 1)

  union all
  -- A form that is blocking billing: hours logged against an authorization
  -- with no form for them.
  select 'form', p.usor || ' needed',
         p.form_name || coalesce(' · ' || p.month, '') || ' · ' || trim(to_char(p.hours_logged, 'FM999990.9')) || ' hours logged',
         '/billing/report?client=' || p_client,
         2
    from public.client_paperwork p
   where p.client_id = p_client and p.state = 'Missing'

  union all
  -- An authorization running out, with hours on it nobody has billed for.
  select 'authorization', 'Authorization ' || a.number || ' ends ' || to_char(a.end_date, 'FMDD Mon'),
         trim(to_char(coalesce(u.hours, 0), 'FM999990.9')) || ' hours logged on it',
         '/clients/' || p_client || '?tab=billing',
         case when a.end_date <= public.practice_today() + 14 then 1 else 3 end
    from public.authorizations a
    left join lateral (
      select sum(se.hours) hours from public.service_entries se
       where se.auth_id = a.id and not se.non_billable) u on true
   where a.client_id = p_client and a.status = 'Open'
     and a.end_date is not null and a.end_date <= public.practice_today() + 30
     and coalesce(u.hours, 0) > 0

  union all
  -- Five shifts kept: the placement may be billed, on USOR 92.
  select 'placement', 'Fifth shift reached',
         coalesce(nullif(pl.employer, ''), 'the placement') || ' · USOR 92 and the placement bill are due',
         '/billing/report?client=' || p_client, 2
    from public.placements pl
   where pl.client_id = p_client
     and pl.fifth_shift_on is not null
     and not exists (
       select 1 from public.forms f
        join public.authorizations a on a.id = f.auth_id
       where f.client_id = p_client and f.template_id = 'usor92'
         and f.status <> 'Draft' and a.service_type like 'Job Placement%')

  union all
  -- Thirty days of stability: the High Quality Indicators may be billed.
  select 'stability', 'Thirty days of stability',
         coalesce(nullif(pl.employer, ''), 'the placement')
           || coalesce(' · ' || nullif(pl.stability_basis, ''), '')
           || ' · High Quality Indicators may be billed',
         '/clients/' || p_client || '?tab=billing', 2
    from public.placements pl
   where pl.client_id = p_client
     and pl.stability_on is not null
     and pl.stability_on + 30 <= public.practice_today()
     and not exists (
       select 1 from public.authorizations a
        join public.invoices i on i.auth_id = a.id
       where a.client_id = p_client and a.service_type like '%HQ Indicator%')

  union all
  -- A text from them that nobody has answered.
  select 'text', 'Unanswered text', left(m.body, 80),
         '/clients/' || p_client || '?tab=messages', 1
    from public.conversations v
    join lateral (
      select body, sender_kind from public.messages
       where conversation_id = v.id order by seq desc limit 1) m on true
   where v.client_id = p_client and v.kind = 'sms' and m.sender_kind = 'client'

  union all
  -- Nobody has recorded whether they agreed to be texted.
  select 'consent', 'Texting consent not recorded',
         'They cannot be texted until it is', '/clients/' || p_client || '?tab=profile#texting', 3
    from c
   where not exists (select 1 from public.sms_consent_events e where e.client_id = p_client)

  union all
  -- A retention check that has come due on a placement.
  select 'retention', d.label || ' check due',
         coalesce(nullif(pl.employer, ''), 'a placement'),
         '/clients/' || p_client || '?tab=jobs', 2
    from public.placements pl
    cross join lateral (values
      (pl.check30, 30, '30 day'), (pl.check60, 60, '60 day'), (pl.check90, 90, '90 day')
    ) d(done, days, label)
   where pl.client_id = p_client and pl.start_date is not null
     and d.done is null and pl.start_date + d.days <= public.practice_today()

  order by 5, 1;
$$;

revoke execute on function public.client_next_actions(uuid) from public, anon;
grant execute on function public.client_next_actions(uuid) to authenticated;
