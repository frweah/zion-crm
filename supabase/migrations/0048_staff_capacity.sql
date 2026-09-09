-- ─────────────────────────────────────────────────────────────
-- 0048 — who has room
--
-- With people waiting at the front of the pipeline, the question stops being
-- "how busy is everyone" and becomes "who should the next referral go to".
-- Those are different questions and only the second one can be acted on.
--
-- One row per active staff member: what they are carrying, what is owed on
-- it, and what they have actually been delivering. Deliberately not a score —
-- a single number would hide which of the three is the problem.
-- ─────────────────────────────────────────────────────────────
create or replace view public.staff_capacity as
select s.id                                        as staff_id,
       s.name,
       s.role,

       -- ── what they are carrying ──────────────────────────
       c.active_clients,
       c.quiet_clients,
       c.front_clients,

       -- ── what is owed on it ──────────────────────────────
       -- Hours are hourly authorizations only; a flat fee has no hours to
       -- deliver, which is why the value is carried separately rather than
       -- folded in at some assumed rate.
       a.open_authorizations,
       a.committed_hours,
       a.committed_value,

       -- ── what they have been delivering ──────────────────
       h.hours_30,
       h.hours_90,
       h.client_hours_90,
       h.uncategorised_hours_90

  from public.staff s

  left join lateral (
    select count(*) filter (where cl.status = 'Active')                      as active_clients,
           count(*) filter (
             where cl.status = 'Active'
               and coalesce(la.last_activity_at, '-infinity'::timestamptz)
                     < now() - interval '30 days')                           as quiet_clients,
           count(*) filter (
             where cl.status = 'Active'
               and cl.stage in ('Referral', 'Intake', 'Assessment'))         as front_clients
      from public.clients cl
      left join public.client_last_activity la on la.client_id = cl.id
     where cl.assigned_staff_id = s.id
  ) c on true

  left join lateral (
    select count(*)                                  as open_authorizations,
           coalesce(sum(e.hours_left), 0)            as committed_hours,
           coalesce(sum(e.committed), 0)             as committed_value
      from public.authorization_economics e
      join public.clients cl on cl.id = e.client_id
     where cl.assigned_staff_id = s.id
       and e.status = 'Open'
  ) a on true

  left join lateral (
    select coalesce(sum(v.hours) filter (
             where v.worked_on >= public.practice_today() - 30), 0)          as hours_30,
           coalesce(sum(v.hours) filter (
             where v.worked_on >= public.practice_today() - 90), 0)          as hours_90,
           coalesce(sum(v.hours) filter (
             where v.worked_on >= public.practice_today() - 90
               and v.category_billable), 0)                                  as client_hours_90,
           coalesce(sum(v.hours) filter (
             where v.worked_on >= public.practice_today() - 90
               and v.category is null), 0)                                   as uncategorised_hours_90
      from public.work_session_values v
     where v.staff_id = s.id
  ) h on true

 where s.active;

alter view public.staff_capacity set (security_invoker = true);
grant select on public.staff_capacity to authenticated;

comment on view public.staff_capacity is
  'One row per active staff member: caseload carried, work owed on it, and hours actually delivered. Hours owed cover hourly authorizations only; flat fees carry value but no hours.';
