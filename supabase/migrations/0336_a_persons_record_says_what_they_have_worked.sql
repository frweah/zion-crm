-- Zion Vocational Rehab CRM — a person's record says what they have worked
--
-- "Staff record: total hours worked (this period, this month, all time) and
-- the last clock-out on each person's record. Admin → Hours stays the roster
-- view."
--
-- The hours have always been there and always on the roster: Admin → Hours is
-- everybody, a period at a time, one line per person. That is the right screen
-- for running a payroll and the wrong one for the question somebody asks when
-- they open one person's record — how much has this person worked, and when
-- did they last finish.
--
-- Three totals and a time, from the same rows the roster counts, so the record
-- and the roster cannot disagree about a person's hours. `hours_count` is the
-- predicate that decides which sessions count at all - a voided one does not,
-- nor does a correction that has not been decided - and it is asked here
-- rather than restated, for the same reason.

begin;

create or replace view public.staff_hours_summary as
  select s.id as staff_id,
         coalesce((select sum(w.hours) from public.work_sessions w
                    where w.staff_id = s.id
                      and public.hours_count(w.*)
                      and public.period_start(w.worked_on) = public.period_start(public.practice_today())),
                  0) as this_period,
         public.period_start(public.practice_today()) as period_start,
         public.period_end(public.practice_today()) as period_end,
         coalesce((select sum(w.hours) from public.work_sessions w
                    where w.staff_id = s.id
                      and public.hours_count(w.*)
                      and w.worked_on >= date_trunc('month', public.practice_today())::date
                      and w.worked_on < (date_trunc('month', public.practice_today()) + interval '1 month')::date),
                  0) as this_month,
         coalesce((select sum(w.hours) from public.work_sessions w
                    where w.staff_id = s.id and public.hours_count(w.*)),
                  0) as all_time,
         /*
          * The last clock-out, which is a time rather than a day.
          *
          * From `ended_at` and not from `worked_on`: a session that ran past
          * midnight belongs to the day it started and ended on the next, and
          * "when did this person last finish" is answered by the clock.
          *
          * A session still running has no ended_at, so it is not an answer to
          * this question - it is the answer to a different one, which the
          * clock screen already shows.
          */
         (select max(w.ended_at) from public.work_sessions w
           where w.staff_id = s.id and public.hours_count(w.*) and w.ended_at is not null)
           as last_clock_out,
         (select max(w.worked_on) from public.work_sessions w
           where w.staff_id = s.id and public.hours_count(w.*)) as last_worked_on
    from public.staff s;

alter view public.staff_hours_summary set (security_invoker = on);

comment on view public.staff_hours_summary is
  'What one person has worked - this pay period, this month, all time - and '
  'when they last clocked out. The same rows Admin > Hours counts, so the '
  'record and the roster cannot disagree.';

revoke all on public.staff_hours_summary from public, anon, authenticated;
grant select on public.staff_hours_summary to authenticated;
grant select on public.staff_hours_summary to service_role;

commit;
