-- ─────────────────────────────────────────────────────────────
-- 0042 — what is next for each client
--
-- The counselor caseload view asks two questions about every client: when did
-- anything last happen, and what happens next. The first has a view already.
-- The second was scattered across appointments, tasks and the job tracker,
-- and answering it meant opening three screens per client — which is why the
-- honest answer to "is anything booked for her?" has always been "let me
-- look".
--
-- One row per client: the soonest thing on the books. Past items are not
-- "next" — a follow-up that was due last week is an inactive client, not a
-- plan, and belongs in the needs list instead.
-- ─────────────────────────────────────────────────────────────
create or replace view public.client_next_up as
select distinct on (x.client_id)
       x.client_id,
       x.at,
       x.kind,
       x.title
  from (
    select e.client_id, e.starts_at as at, e.kind, e.title
      from public.calendar_events e
     where e.client_id is not null
       and e.starts_at >= now()

    union all

    select t.client_id, t.due::timestamptz, 'Task', t.title
      from public.tasks t
     where t.client_id is not null
       and t.status = 'Open'
       and t.due >= public.practice_today()

    union all

    select m.client_id, m.interview_on::timestamptz, 'Interview',
           'Interview — ' || coalesce(e.name, l.title, 'a job')
      from public.lead_matches m
      join public.job_leads l on l.id = m.lead_id
      left join public.employers e on e.id = l.employer_id
     where m.interview_on >= public.practice_today()

    union all

    select m.client_id, m.follow_up_on::timestamptz, 'Follow-up',
           'Follow up — ' || coalesce(e.name, l.title, 'a job')
      from public.lead_matches m
      join public.job_leads l on l.id = m.lead_id
      left join public.employers e on e.id = l.employer_id
     where m.follow_up_on >= public.practice_today()
       and m.status not in ('Hired', 'Not selected')
  ) x
 order by x.client_id, x.at;

alter view public.client_next_up set (security_invoker = true);
grant select on public.client_next_up to authenticated;

comment on view public.client_next_up is
  'The soonest thing on the books for each client — appointment, task, interview or job follow-up. Nothing in the past.';
