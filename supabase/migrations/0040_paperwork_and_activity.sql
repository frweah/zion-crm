-- ─────────────────────────────────────────────────────────────
-- 0040 — what paperwork is outstanding, and when a client went quiet.
--
-- Two views behind the "needs attention" dashboard.
--
-- The first answers, per client, which USOR forms their open authorizations
-- require and where each has got to. The rules were already in the data and
-- nowhere else: form_templates says which services a form belongs to and
-- whether it gates billing, authorizations say which service was authorized.
-- Nobody had ever joined the two, so "which forms am I missing" was a question
-- answered by remembering.
--
-- The second replaces a definition of "activity" written before half the
-- things that count as activity existed.
-- ─────────────────────────────────────────────────────────────

-- ─────────────────────────────────────────────────────────────
-- Paperwork
--
-- Four states, and the distinction that matters is between the middle two.
--
--   Not started  — required, but no hours logged yet either. Nothing is late.
--   In progress  — a draft exists.
--   Complete     — completed or sent.
--   Missing      — hours have been logged against the authorization and the
--                  form that gates the invoice is not done. This is the only
--                  one that is a problem today, and the only one the dashboard
--                  counts.
--
-- A monthly form needs one per month that has hours in it, which is why the
-- monthly ones fan out over the months rather than appearing once — plus the
-- current month always, whether or not anything is logged in it yet. Without
-- that, an open Job Coaching authorization with no hours this month showed no
-- paperwork at all, which reads as "nothing needed" rather than "not started".
-- ─────────────────────────────────────────────────────────────
create or replace view public.client_paperwork as
with required as (
  select a.client_id,
         a.id            as auth_id,
         a.number        as auth_number,
         a.service_type,
         t.id            as template_id,
         t.usor,
         t.name          as form_name,
         t.monthly
    from public.authorizations a
    join public.form_templates t
      on t.required_for_billing
     and a.service_type = any(t.services)
   where a.status = 'Open'
),
expected as (
  -- One row per month that has hours on the authorization.
  select r.client_id, r.auth_id, r.auth_number, r.service_type, r.template_id,
         r.usor, r.form_name, r.monthly,
         to_char(se.date, 'YYYY-MM')   as month,
         sum(se.hours)                 as hours_logged
    from required r
    join public.service_entries se on se.auth_id = r.auth_id
   where r.monthly
   group by r.client_id, r.auth_id, r.auth_number, r.service_type, r.template_id,
            r.usor, r.form_name, r.monthly, to_char(se.date, 'YYYY-MM')

  union

  -- The month in hand, always, so an open authorization says what it still
  -- needs before anybody has logged against it.
  select r.client_id, r.auth_id, r.auth_number, r.service_type, r.template_id,
         r.usor, r.form_name, r.monthly,
         to_char(public.practice_today(), 'YYYY-MM'),
         0::numeric
    from required r
   where r.monthly

  union all

  -- One row for the authorization as a whole.
  select r.client_id, r.auth_id, r.auth_number, r.service_type, r.template_id,
         r.usor, r.form_name, r.monthly,
         null::text,
         coalesce((select sum(se.hours) from public.service_entries se
                    where se.auth_id = r.auth_id), 0)
    from required r
   where not r.monthly
)
select e.client_id,
       e.auth_id,
       e.auth_number,
       e.service_type,
       e.template_id,
       e.usor,
       e.form_name,
       e.monthly,
       e.month,
       e.hours_logged,
       f.id            as form_id,
       f.status        as form_status,
       case
         when f.status in ('Completed', 'Sent') then 'Complete'
         when f.status = 'Draft'                then 'In progress'
         when coalesce(e.hours_logged, 0) > 0   then 'Missing'
         else 'Not started'
       end             as state
  from expected e
  left join public.forms f
    on f.client_id = e.client_id
   and f.template_id = e.template_id
   and f.auth_id = e.auth_id
   and (e.month is null or f.month = e.month);

alter view public.client_paperwork set (security_invoker = true);
grant select on public.client_paperwork to authenticated;

comment on view public.client_paperwork is
  'Which USOR forms each open authorization needs and where each has got to. Missing means hours are logged and the form that gates the invoice is not done.';

-- ─────────────────────────────────────────────────────────────
-- Activity
--
-- client_last_activity was written in Phase 6 and reads six tables. It
-- predates logged mail, appointments, job applications and stage changes — so
-- a client with a counselor email last week and an interview tomorrow counted
-- as untouched for a month. It drives the clients list, and it is about to
-- drive an "inactive clients" counter, which is worse: a wrong definition of
-- quiet is a list of people to chase who do not need chasing.
--
-- client_activity is now the one definition of what has happened, so this
-- becomes the maximum of it. The left join keeps a row for every client,
-- including those nothing has ever happened to — they are the ones most worth
-- seeing.
-- ─────────────────────────────────────────────────────────────
create or replace view public.client_last_activity as
select c.id                 as client_id,
       max(a.at)            as last_activity_at
  from public.clients c
  left join public.client_activity a on a.client_id = c.id
 group by c.id;

alter view public.client_last_activity set (security_invoker = true);
grant select on public.client_last_activity to authenticated;
