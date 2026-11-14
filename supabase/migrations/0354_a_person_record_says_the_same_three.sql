-- Zion Vocational Rehab CRM — a person's record says the same three
--
-- The owner asked for today, this week and this pay period - worked, break
-- and segments - in four places: the top-bar button, My day, the staff record
-- and Admin -> Hours. Three of them read `my_hours_summary`, which answers
-- for whoever is asking.
--
-- The staff record is the one that asks about somebody else, and it reads
-- `staff_hours_summary`, which had this period, this month and all time - a
-- different three. So the same three figures would have been worked out twice
-- from two views with two definitions of a week, which is how a screen and an
-- export come to disagree about what somebody worked.
--
-- One definition each, in the view. The week is the ISO week the practice
-- already uses everywhere else: Monday to today.

begin;

drop view if exists public.staff_hours_summary;

create view public.staff_hours_summary
with (security_invoker = true) as
  select
    s.id as staff_id,
    coalesce((select sum(w.hours) from public.work_sessions w
               where w.staff_id = s.id and public.hours_count(w.*)
                 and public.period_start(w.worked_on) = public.period_start(public.practice_today())), 0::numeric)
      as this_period,
    public.period_start(public.practice_today()) as period_start,
    public.period_end(public.practice_today()) as period_end,
    coalesce((select sum(w.hours) from public.work_sessions w
               where w.staff_id = s.id and public.hours_count(w.*)
                 and w.worked_on >= date_trunc('month', public.practice_today()::timestamptz)::date
                 and w.worked_on < (date_trunc('month', public.practice_today()::timestamptz) + interval '1 month')::date), 0::numeric)
      as this_month,
    coalesce((select sum(w.hours) from public.work_sessions w
               where w.staff_id = s.id and public.hours_count(w.*)), 0::numeric)
      as all_time,
    (select max(w.ended_at) from public.work_sessions w
      where w.staff_id = s.id and public.hours_count(w.*) and w.ended_at is not null)
      as last_clock_out,
    (select max(w.worked_on) from public.work_sessions w
      where w.staff_id = s.id and public.hours_count(w.*))
      as last_worked_on,

    -- ── the same three the rest of the practice shows ────────
    coalesce((select sum(w.hours) from public.work_sessions w
               where w.staff_id = s.id and public.hours_count(w.*)
                 and w.worked_on = public.practice_today()), 0::numeric) as today_hours,
    coalesce((select sum(w.break_seconds) from public.work_sessions w
               where w.staff_id = s.id and public.hours_count(w.*)
                 and w.worked_on = public.practice_today()), 0::bigint) as today_break_seconds,
    (select count(*) from public.work_sessions w
      where w.staff_id = s.id and public.hours_count(w.*)
        and w.worked_on = public.practice_today()) as today_segments,

    coalesce((select sum(w.hours) from public.work_sessions w
               where w.staff_id = s.id and public.hours_count(w.*)
                 and w.worked_on >= (public.practice_today() - (extract(isodow from public.practice_today())::integer - 1))
                 and w.worked_on <= public.practice_today()), 0::numeric) as week_hours,
    coalesce((select sum(w.break_seconds) from public.work_sessions w
               where w.staff_id = s.id and public.hours_count(w.*)
                 and w.worked_on >= (public.practice_today() - (extract(isodow from public.practice_today())::integer - 1))
                 and w.worked_on <= public.practice_today()), 0::bigint) as week_break_seconds,
    (select count(*) from public.work_sessions w
      where w.staff_id = s.id and public.hours_count(w.*)
        and w.worked_on >= (public.practice_today() - (extract(isodow from public.practice_today())::integer - 1))
        and w.worked_on <= public.practice_today()) as week_segments,

    coalesce((select sum(w.break_seconds) from public.work_sessions w
               where w.staff_id = s.id and public.hours_count(w.*)
                 and public.period_start(w.worked_on) = public.period_start(public.practice_today())), 0::bigint)
      as period_break_seconds,
    (select count(*) from public.work_sessions w
      where w.staff_id = s.id and public.hours_count(w.*)
        and public.period_start(w.worked_on) = public.period_start(public.practice_today()))
      as period_segments,

    -- Days of theirs with time on the clock that nobody has accounted for.
    -- The manager's half of the flag: the person sees the days on their My
    -- day, and whoever they answer to sees the count here.
    (select count(*) from public.work_days d
      where d.staff_id = s.id and d.needs_an_account) as days_to_account_for
  from public.staff s;

-- Supabase grants a new view everything to `authenticated`, so a revoke
-- that names only public and anon leaves it writable (verify_view_grants).
revoke all on public.staff_hours_summary from public, anon, authenticated;
grant select on public.staff_hours_summary to authenticated;

commit;
