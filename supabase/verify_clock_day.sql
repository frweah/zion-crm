-- Zion Vocational Rehab CRM — a day is made of segments (0352, 0353)
--
-- What has to hold:
--
--   **The segments sum to the day.** Two clock-ins on one day are two
--   segments and one day, and the day's worked hours and break are the sum
--   of them.
--
--   **A break sits inside a segment.** It comes off that segment's hours and
--   off the day's, and it belongs to the segment it happened in rather than
--   to the day in general.
--
--   **A segment belongs to the day it started**, which matters at midnight
--   and is the reason a clock-out after twelve does not move the work into
--   tomorrow.
--
--   **What is said at clock out lands on that day's End of day**, as a line
--   marked as having come from a clock out, appended when somebody clocks
--   out twice - not a second form and not a second list.
--
--   **A day nobody accounted for is flagged**, from the day the flag started
--   and not before it, and saying what the day was clears it.
--
--   **The fourteen-hour rule closes the open segment** and leaves the
--   finished ones as they are.
--
--   **Twelve worked hours across a day tells the manager**, once.
--
-- Clocking not being required of a contractor is asserted in
-- `verify_time_clock.sql`, where it has been since 0293. It is not repeated
-- here: one assertion in two scripts is two places to update and one of them
-- will be missed.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_mgr_uid uuid := gen_random_uuid();
  v_emp_uid uuid := gen_random_uuid();
  v_mgr uuid; v_emp uuid;
  v_day date := public.practice_today() - 1;
  v_seg1 uuid; v_seg2 uuid; v_seg3 uuid;
  v_day_id uuid;
  v_n integer; v_hours numeric; v_break integer;
  v_text text; v_bool boolean;
  v_before date;
  r record;
  failures text[] := '{}';
begin
  insert into public.staff (name, email, role, active)
  values ('ZZ Day Manager', 'zz-day-mgr@example.test', 'Admin', true) returning id into v_mgr;
  insert into public.staff (name, email, role, active, manager_id)
  values ('ZZ Day Worker', 'zz-day-emp@example.test', 'Job Search', true, v_mgr) returning id into v_emp;
  insert into public.staff_employment (staff_id, employment_type) values (v_emp, 'Employee');

  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_emp_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-day-emp@example.test', '{}', '{}', now(), now()),
         (v_mgr_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-day-mgr@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_emp_uid where id = v_emp;
  update public.staff set user_id = v_mgr_uid where id = v_mgr;

  -- The flag starts on or before the day under test, so that what is asserted
  -- here is the rule and not the date the practice happened to switch it on.
  select clock_accounts_from into v_before from public.org_settings limit 1;
  -- Two days back, because the day with nothing said about it is the day
  -- before the one with two segments on it, and a flag that started after it
  -- would answer "no" for the right reason and the wrong one.
  update public.org_settings set clock_accounts_from = v_day - 1;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_emp_uid, 'role', 'authenticated')::text, true);

  -- ── the morning: a segment with a break in it ──────────────
  --
  -- The timer is back-dated rather than waited for. A clock-out takes the
  -- time it happened, which is how the phone sends one that was pressed in a
  -- car park an hour before it found signal.
  perform public.clock_in('ZQ the morning', null);
  update public.work_session_timers
     set started_at = (v_day + time '08:00') at time zone 'America/Denver'
   where staff_id = v_emp;

  perform public.start_break();
  update public.work_session_timers
     set break_started_at = (v_day + time '10:00') at time zone 'America/Denver'
   where staff_id = v_emp;
  perform public.end_break();
  -- 30 minutes of break, recorded on the segment it happened in.
  update public.work_session_timers set break_seconds = 1800 where staff_id = v_emp;

  v_seg1 := public.clock_out('ZQ job site visits', null,
                             (v_day + time '12:30') at time zone 'America/Denver');

  select hours, break_seconds into v_hours, v_break
    from public.work_sessions where id = v_seg1;
  if v_hours <> 4.00 then
    failures := failures || format(
      'FAILED: 8:00 to 12:30 less half an hour of break came to %s hours', v_hours)::text;
  elsif v_break <> 1800 then
    failures := failures || format('FAILED: the break on the segment is %s seconds', v_break)::text;
  else
    raise notice 'ok  a break sits inside its segment and comes off that segment''s hours';
  end if;

  -- ── the afternoon: a second segment, the same day ──────────
  perform public.clock_in('ZQ the afternoon', null);
  update public.work_session_timers
     set started_at = (v_day + time '13:30') at time zone 'America/Denver'
   where staff_id = v_emp;
  v_seg2 := public.clock_out('ZQ the coaching notes', null,
                             (v_day + time '17:00') at time zone 'America/Denver');

  select count(*), sum(hours), sum(break_seconds)
    into v_n, v_hours, v_break
    from public.work_sessions where staff_id = v_emp and worked_on = v_day and not voided;
  if v_n <> 2 then
    failures := failures || format('FAILED: two clock-ins made %s rows', v_n)::text;
  end if;

  select segments, worked_hours, break_seconds into r
    from public.work_days where staff_id = v_emp and day = v_day;
  if r.segments <> 2 then
    failures := failures || format('FAILED: the day says %s segments', r.segments)::text;
  elsif r.worked_hours <> v_hours or r.worked_hours <> 7.50 then
    failures := failures || format(
      'FAILED: the day says %s hours and its segments come to %s', r.worked_hours, v_hours)::text;
  elsif r.break_seconds <> v_break then
    failures := failures || format(
      'FAILED: the day says %s seconds of break and its segments come to %s',
      r.break_seconds, v_break)::text;
  else
    raise notice 'ok  the segments sum to the day: two of them, 7.50 hours, the break with them';
  end if;

  -- ── and what was said landed on that day ───────────────────
  select id into v_day_id from public.staff_days where staff_id = v_emp and day = v_day;
  if v_day_id is null then
    failures := failures || 'FAILED: clocking out with an account opened no End of day'::text;
  else
    select count(*) into v_n from public.staff_day_lines
     where day_id = v_day_id and from_clock_out;
    if v_n <> 2 then
      failures := failures || format(
        'FAILED: two clock-outs with an account made %s lines on the day', v_n)::text;
    elsif not exists (select 1 from public.staff_day_lines
                       where day_id = v_day_id and description = 'ZQ job site visits')
       or not exists (select 1 from public.staff_day_lines
                       where day_id = v_day_id and description = 'ZQ the coaching notes') then
      failures := failures || 'FAILED: what was said at clock out is not what the day says'::text;
    else
      raise notice 'ok  what is said at clock out is appended to that day''s End of day, one line each';
    end if;
  end if;

  -- And on the **right** day: the lines are on yesterday, not on today.
  if exists (select 1 from public.staff_days where staff_id = v_emp and day = public.practice_today()) then
    failures := failures ||
      'FAILED: a clock-out for yesterday wrote on today''s End of day'::text;
  else
    raise notice 'ok  and on the day the segment was worked, not the day it was recorded';
  end if;

  -- ── a day with something said about it is not flagged ──────
  select needs_an_account into v_bool from public.work_days
   where staff_id = v_emp and day = v_day;
  if v_bool then
    failures := failures || 'FAILED: a day with an account on it is still being asked about'::text;
  else
    raise notice 'ok  a day somebody accounted for is not flagged';
  end if;

  -- ── a day with nothing said is flagged ─────────────────────
  --
  -- Its own day, two days back, so that this case and the one above cannot
  -- be confused with each other: a script that stops has said less than it
  -- knew, and a flag that fired for the wrong reason reads the same as one
  -- that worked.
  perform public.clock_in('ZQ the day before', null);
  update public.work_session_timers
     set started_at = (v_day - 1 + time '09:00') at time zone 'America/Denver'
   where staff_id = v_emp;
  v_seg3 := public.clock_out('', null, (v_day - 1 + time '15:00') at time zone 'America/Denver');

  select needs_an_account, accounted_for into r
    from public.work_days where staff_id = v_emp and day = v_day - 1;
  if not r.needs_an_account then
    failures := failures || 'FAILED: a day on the clock with nothing said about it is not flagged'::text;
  elsif r.accounted_for then
    failures := failures || 'FAILED: a day with nothing said counts as accounted for'::text;
  else
    raise notice 'ok  a day nobody said anything about is flagged';
  end if;

  -- And writing it up on the End of day form clears it, because that form is
  -- the place to edit (owner, 14 Nov 2026).
  v_day_id := public.open_staff_day(v_day - 1);
  insert into public.staff_day_lines (day_id, status, description, notes, sort_order)
  values (v_day_id, 'Complete', 'ZQ written up afterwards', '', 1);

  select needs_an_account into v_bool from public.work_days
   where staff_id = v_emp and day = v_day - 1;
  if v_bool then
    failures := failures || 'FAILED: writing the day up on the End of day form did not clear the flag'::text;
  else
    raise notice 'ok  and writing it up afterwards clears it';
  end if;

  -- ── the flag does not reach back before it started ─────────
  update public.org_settings set clock_accounts_from = v_day + 1;
  select needs_an_account into v_bool from public.work_days
   where staff_id = v_emp and day = v_day - 1;
  if v_bool then
    failures := failures ||
      'FAILED: a day before the flag started is being asked about'::text;
  else
    raise notice 'ok  and no day before the flag started is asked about';
  end if;
  update public.org_settings set clock_accounts_from = v_day - 1;

  -- ── a segment belongs to the day it started ────────────────
  perform public.clock_in('ZQ the late shift', null);
  update public.work_session_timers
     set started_at = (v_day + time '22:30') at time zone 'America/Denver'
   where staff_id = v_emp;
  perform public.clock_out('ZQ past midnight', null,
                           (v_day + 1 + time '01:00') at time zone 'America/Denver');

  select count(*) into v_n from public.work_sessions
   where staff_id = v_emp and worked_on = v_day and description = 'ZQ past midnight';
  if v_n <> 1 then
    failures := failures ||
      'FAILED: a segment that crossed midnight did not stay on the day it started'::text;
  else
    raise notice 'ok  a segment that crosses midnight belongs to the day it started';
  end if;

  -- ── twelve hours across the day tells the manager ──────────
  --
  -- The day now holds 4.00 + 3.50 + 2.50 = 10.00 hours. One more segment
  -- takes it past twelve, and the notice is about the day rather than about
  -- any one segment - which is the whole point of asking it across segments.
  perform public.clock_in('ZQ and more', null);
  update public.work_session_timers
     set started_at = (v_day + time '17:30') at time zone 'America/Denver'
   where staff_id = v_emp;
  perform public.clock_out('ZQ the evening', null,
                           (v_day + time '21:00') at time zone 'America/Denver');

  /*
   * Asked as the database rather than as the worker.
   *
   * `notifications` is behind RLS and this notice is the manager's, so the
   * person who worked the day cannot see it - and a count of zero read
   * through their own session would have looked exactly like a notice that
   * was never sent.
   */
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  select count(*) into v_n from public.notifications
   where staff_id = v_mgr and kind = 'clock_long_day';
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_emp_uid, 'role', 'authenticated')::text, true);
  if v_n <> 1 then
    failures := failures || format(
      'FAILED: a day over twelve hours told the manager %s times', v_n)::text;
  else
    raise notice 'ok  a day over twelve worked hours tells the manager, once';
  end if;

  -- ── the fourteen-hour rule closes the open segment only ────
  perform public.clock_in('ZQ left running', null);
  update public.work_session_timers
     set started_at = now() - interval '15 hours'
   where staff_id = v_emp;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  perform public.close_forgotten_sessions();
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_emp_uid, 'role', 'authenticated')::text, true);

  if exists (select 1 from public.work_session_timers where staff_id = v_emp) then
    failures := failures || 'FAILED: a segment open past fourteen hours was left running'::text;
  elsif (select count(*) from public.work_sessions
          where staff_id = v_emp and auto_closed) <> 1 then
    failures := failures || 'FAILED: the fourteen-hour rule did not close exactly the open segment'::text;
  elsif (select count(*) from public.work_sessions
          where id in (v_seg1, v_seg2, v_seg3) and auto_closed) <> 0 then
    failures := failures || 'FAILED: closing the open segment touched the finished ones'::text;
  else
    raise notice 'ok  the fourteen-hour rule closes the segment that is open and leaves the rest';
  end if;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('role', 'postgres', true);
  update public.org_settings set clock_accounts_from = v_before;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, chr(10));
  end if;
  raise notice '--- CLOCK DAY VERIFIED ---';
end $$;

rollback;
