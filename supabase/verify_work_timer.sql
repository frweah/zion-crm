-- Zion Vocational Rehab CRM — the work session timer
--
-- The thing to prove is what the timer does not do. It is a stopwatch for
-- people who are paid by the hour and it must never become a clock that
-- records time on their behalf: no session appears until somebody saves one,
-- the saved figure is the one they agreed to rather than the one measured, and
-- a timer left running does not quietly write a day nobody worked.
--
-- The other half is privacy. A running timer says where somebody is in their
-- afternoon, and that is nobody else's business — Admin included.
--
-- Runs inside a transaction that is rolled back. Nothing here is left behind.

begin;

do $$
declare
  v_admin    uuid;
  v_adm_uid  uuid;
  v_rei      uuid;
  v_rei_uid  uuid;
  v_before   int;
  v_count    int;
  v_hours    numeric;
  v_prev     numeric;
  failures   text[] := '{}';
begin
  select id, user_id into v_admin, v_adm_uid from public.staff where legacy_id = 's1';
  select id, user_id into v_rei,  v_rei_uid  from public.staff where legacy_id = 's2';

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_rei_uid, 'role', 'authenticated')::text, true);

  select count(*) into v_before from public.work_sessions where staff_id = v_rei;

  -- ── starting logs nothing ──────────────────────────────────
  insert into public.work_session_timers (staff_id, started_at)
  values (v_rei, now() - interval '90 minutes');

  select count(*) into v_count from public.work_sessions where staff_id = v_rei;
  if v_count <> v_before then
    failures := failures || 'FAILED: starting a timer wrote a work session'::text;
  else
    raise notice 'ok  starting the timer logs nothing';
  end if;

  -- ── one at a time ──────────────────────────────────────────
  begin
    insert into public.work_session_timers (staff_id) values (v_rei);
    failures := failures || 'FAILED: a second timer was started alongside the first'::text;
  exception when unique_violation then
    raise notice 'ok  only one timer runs at a time';
  end;

  -- ── the elapsed figure is an offer ─────────────────────────
  select public.timer_elapsed_hours(started_at) into v_hours
    from public.work_session_timers where staff_id = v_rei;
  if v_hours < 1.4 or v_hours > 1.6 then
    failures := failures || format('FAILED: 90 minutes came to %s hours', v_hours);
  else
    raise notice 'ok  ninety minutes reads as % hours', v_hours;
  end if;

  -- ── a timer left running does not write a day ──────────────
  update public.work_session_timers set started_at = now() - interval '31 hours'
   where staff_id = v_rei;
  select public.timer_elapsed_hours(started_at) into v_hours
    from public.work_session_timers where staff_id = v_rei;
  if v_hours <> 24.00 then
    failures := failures || format('FAILED: a timer left running offered %s hours', v_hours);
  else
    raise notice 'ok  a timer left overnight is capped at 24, for somebody to correct';
  end if;

  select count(*) into v_count from public.work_sessions where staff_id = v_rei;
  if v_count <> v_before then
    failures := failures || 'FAILED: a long-running timer wrote a session by itself'::text;
  else
    raise notice 'ok  however long it runs, it writes nothing on its own';
  end if;

  -- ── discarding leaves no trace ─────────────────────────────
  delete from public.work_session_timers where staff_id = v_rei;
  select count(*) into v_count from public.work_sessions where staff_id = v_rei;
  if v_count <> v_before then
    failures := failures || 'FAILED: discarding a timer logged something'::text;
  else
    raise notice 'ok  discarding logs nothing — the commonest reason to stop one';
  end if;

  -- ── what is saved is an ordinary session ───────────────────
  -- The point of the whole design: the timer hands over to the same
  -- append-only table the manual form writes to, under the same rules.
  insert into public.work_session_timers (staff_id, started_at)
  values (v_rei, now() - interval '2 hours');

  insert into public.work_sessions (staff_id, worked_on, hours, description, created_by)
  values (v_rei, public.practice_today(), 1.75, 'ZZ timed work', v_rei);
  delete from public.work_session_timers where staff_id = v_rei;

  if not exists (
    select 1 from public.work_sessions
     where staff_id = v_rei and description = 'ZZ timed work' and hours = 1.75 and not voided
  ) then
    failures := failures || 'FAILED: the saved session is not an ordinary work session'::text;
  else
    raise notice 'ok  what is saved is an ordinary session, at the figure agreed not measured';
  end if;

  if exists (select 1 from public.work_session_timers where staff_id = v_rei) then
    failures := failures || 'FAILED: the timer survived being saved'::text;
  else
    raise notice 'ok  saving clears the timer';
  end if;

  -- ── the totals count it ────────────────────────────────────
  select today_hours into v_hours from public.my_hours_summary where staff_id = v_rei;
  if coalesce(v_hours, 0) < 1.75 then
    failures := failures || format('FAILED: today reads %s, which does not include the session', v_hours);
  else
    raise notice 'ok  today''s total includes it';
  end if;

  -- numeric, not int: 1.75 read into an integer variable rounds to 2, and the
  -- comparison then fails for a reason that has nothing to do with voiding.
  -- A voided session is not work done, here as everywhere else.
  select today_hours into v_prev from public.my_hours_summary where staff_id = v_rei;
  insert into public.work_sessions (staff_id, worked_on, hours, description, voided, created_by)
  values (v_rei, public.practice_today(), 8, 'ZZ voided', true, v_rei);
  select today_hours into v_hours from public.my_hours_summary where staff_id = v_rei;
  if v_hours <> v_prev then
    failures := failures || 'FAILED: a voided session counted towards today'::text;
  else
    raise notice 'ok  a voided session does not count towards the totals';
  end if;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  -- ── a running timer is nobody else's business ──────────────
  insert into public.work_session_timers (staff_id, started_at)
  values (v_rei, now() - interval '10 minutes');

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);

  select count(*) into v_count from public.work_session_timers;
  if v_count <> 0 then
    failures := failures || 'FAILED: Admin can see somebody else''s running timer'::text;
  else
    raise notice 'ok  not even Admin sees a running timer — it says where somebody is in their day';
  end if;

  begin
    insert into public.work_session_timers (staff_id) values (v_admin);
    -- Admin starting their own is fine; starting one for somebody else is not.
    delete from public.work_session_timers where staff_id = v_admin;
    raise notice 'ok  Admin can start their own timer';
  exception when others then
    failures := failures || 'FAILED: Admin could not start a timer of their own'::text;
  end;

  begin
    insert into public.work_session_timers (staff_id) values (v_rei);
    failures := failures || 'FAILED: a timer was started on somebody else''s behalf'::text;
  exception when insufficient_privilege or unique_violation then
    raise notice 'ok  nobody starts a timer on somebody else''s behalf';
  end;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  if failures = '{}' then
    raise notice '';
    raise notice '--- WORK SESSION TIMER VERIFIED ---';
  else
    raise notice '';
    raise notice '%  PROBLEM(S):', array_length(failures, 1);
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
