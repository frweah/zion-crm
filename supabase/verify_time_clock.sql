-- The time clock (0293)
--
-- The six cases the brief asks for, and two the building of it turned up.
--
--   One open session per person. Break inside the session, not instead of it.
--   The fourteen-hour rule closes a forgotten session, flags it, and leaves it
--   to be confirmed. A correction by an employee waits on somebody; a
--   contractor's own same-day correction does not, and theirs after the day
--   closes is refused. Totals equal the sum of the sessions that count.
--   Clocking is not required of a contractor.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_emp_uid uuid := gen_random_uuid();
  v_con_uid uuid := gen_random_uuid();
  v_mgr_uid uuid := gen_random_uuid();
  v_emp uuid; v_con uuid; v_mgr uuid;
  v_id uuid; v_corr uuid; v_closed integer;
  v_hours numeric; v_break integer; v_total numeric;
  r record;
  failures text[] := '{}';
begin
  -- A manager, an employee who answers to them, and a contractor.
  insert into public.staff (name, email, role, active)
  values ('ZZ Clock Manager', 'zz-mgr@example.test', 'Admin', true) returning id into v_mgr;
  insert into public.staff (name, email, role, active, manager_id)
  values ('ZZ Clock Employee', 'zz-emp@example.test', 'Job Search', true, v_mgr) returning id into v_emp;
  insert into public.staff (name, email, role, active)
  values ('ZZ Clock Contractor', 'zz-con@example.test', 'Job Search', true) returning id into v_con;

  insert into public.staff_employment (staff_id, employment_type) values (v_emp, 'Employee');
  insert into public.staff_employment (staff_id, employment_type) values (v_con, 'Contractor');

  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_emp_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-emp@example.test', '{}', '{}', now(), now()),
         (v_con_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-con@example.test', '{}', '{}', now(), now()),
         (v_mgr_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-mgr@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_emp_uid where id = v_emp;
  update public.staff set user_id = v_con_uid where id = v_con;
  update public.staff set user_id = v_mgr_uid where id = v_mgr;

  -- ── one open session per person ───────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_emp_uid, 'role', 'authenticated')::text, true);

  perform public.clock_in('ZQ the morning');
  begin
    perform public.clock_in('ZQ again');
    failures := failures || 'FAILED: a second session opened while one was running'::text;
  exception when unique_violation then
    raise notice 'ok  one session at a time, per person';
  end;

  -- And somebody else is not stopped by it.
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_con_uid, 'role', 'authenticated')::text, true);
  perform public.clock_in('ZQ their own morning');
  -- Counted as postgres: `work_session_timers_own` shows a person their own
  -- row and nobody else's, which is right and would make this count 1.
  perform set_config('role', 'postgres', true);
  if (select count(*) from public.work_session_timers where staff_id in (v_emp, v_con)) <> 2 then
    failures := failures || 'FAILED: one person being clocked in stopped another'::text;
  else
    raise notice 'ok  and one person on the clock does not stop anybody else';
  end if;

  -- ── the break is inside the session ──────────────────────
  update public.work_session_timers set started_at = now() - interval '4 hours' where staff_id = v_con;
  perform set_config('role', 'authenticated', true);

  perform public.start_break();
  if (select break_started_at from public.work_session_timers where staff_id = v_con) is null then
    failures := failures || 'FAILED: starting a break recorded nothing'::text;
  end if;
  if not exists (select 1 from public.work_session_timers where staff_id = v_con) then
    failures := failures || 'FAILED: a break ended the session instead of sitting inside it'::text;
  end if;

  perform set_config('role', 'postgres', true);
  update public.work_session_timers set break_started_at = now() - interval '1 hour' where staff_id = v_con;
  perform set_config('role', 'authenticated', true);
  v_break := public.end_break();

  v_id := public.clock_out('ZQ four hours less an hour off');
  perform set_config('role', 'postgres', true);
  select hours, break_seconds, started_at, ended_at into r
    from public.work_sessions where id = v_id;
  select hours, break_seconds into v_hours, v_break from public.work_sessions where id = v_id;

  if v_hours < 2.9 or v_hours > 3.1 then
    failures := failures || format('FAILED: four hours less an hour of break came to %s', v_hours)::text;
  elsif v_break < 3500 or v_break > 3700 then
    failures := failures || format('FAILED: an hour of break measured %s seconds', v_break)::text;
  elsif (select started_at from public.work_sessions where id = v_id) is null
     or (select ended_at from public.work_sessions where id = v_id) is null then
    failures := failures || 'FAILED: the session was recorded without saying when it was'::text;
  else
    raise notice 'ok  the break sits inside the session, and the hours are the clock less the break';
  end if;

  -- ── the fourteen-hour rule ───────────────────────────────
  perform set_config('role', 'postgres', true);
  insert into public.work_session_timers (staff_id, started_at, note, last_seen_at)
  values (v_emp, now() - interval '20 hours', 'ZQ forgot to clock out', now() - interval '11 hours')
  on conflict (staff_id) do update
    set started_at = now() - interval '20 hours', last_seen_at = now() - interval '11 hours';

  v_closed := public.close_forgotten_sessions();
  if v_closed < 1 then
    failures := failures || 'FAILED: a session open for twenty hours was not closed'::text;
  elsif exists (select 1 from public.work_session_timers where staff_id = v_emp) then
    failures := failures || 'FAILED: the session is still open after being auto-closed'::text;
  else
    select * into r from public.work_sessions
     where staff_id = v_emp and auto_closed order by created_at desc limit 1;
    if r.id is null then
      failures := failures || 'FAILED: the auto-closed session was not recorded'::text;
    elsif r.confirmed_at is not null then
      failures := failures || 'FAILED: an auto-closed session arrived already confirmed'::text;
    elsif r.ended_at > now() - interval '10 hours' then
      failures := failures || format('FAILED: it was closed at %s, not at the last thing they did', r.ended_at)::text;
    else
      raise notice 'ok  a session open past fourteen hours is closed at the last activity, flagged, and unconfirmed';
    end if;
  end if;

  -- And the person confirms it. Nobody else can.
  select id into v_id from public.work_sessions
   where staff_id = v_emp and auto_closed order by created_at desc limit 1;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_con_uid, 'role', 'authenticated')::text, true);
  begin
    perform public.confirm_auto_closed_session(v_id);
    failures := failures || 'FAILED: somebody else confirmed a session they did not work'::text;
  exception when insufficient_privilege then null;
  end;
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_emp_uid, 'role', 'authenticated')::text, true);
  perform public.confirm_auto_closed_session(v_id);
  if (select confirmed_at from public.work_sessions where id = v_id) is null then
    failures := failures || 'FAILED: confirming an auto-closed session recorded nothing'::text;
  else
    raise notice 'ok  and only the person who worked it can confirm it';
  end if;

  -- ── a correction, and who agrees to it ───────────────────
  -- An employee's waits, and the original counts until it is approved.
  v_corr := public.request_hours_correction(v_id, 6.00, '', 'ZQ the clock was left running');
  perform set_config('role', 'postgres', true);

  if (select approval from public.work_sessions where id = v_corr) <> 'Waiting' then
    failures := failures || 'FAILED: an employee''s correction did not wait on anybody'::text;
  elsif (select approver_id from public.work_sessions where id = v_corr) <> v_mgr then
    failures := failures || 'FAILED: the correction did not go to their manager'::text;
  elsif (select voided from public.work_sessions where id = v_id) then
    failures := failures || 'FAILED: the original was voided before anybody agreed to the change'::text;
  elsif public.hours_count((select w from public.work_sessions w where w.id = v_corr)) then
    failures := failures || 'FAILED: a correction nobody has agreed to is counted in the totals'::text;
  else
    raise notice 'ok  an employee''s correction waits on their manager, and the original stands meanwhile';
  end if;

  -- Nobody but the manager or Admin decides it.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_con_uid, 'role', 'authenticated')::text, true);
  begin
    perform public.decide_hours_correction(v_corr, true);
    failures := failures || 'FAILED: somebody with no part in it approved a correction'::text;
  exception when insufficient_privilege then null;
  end;

  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_mgr_uid, 'role', 'authenticated')::text, true);
  begin
    perform public.decide_hours_correction(v_corr, false, '');
    failures := failures || 'FAILED: a correction was declined with no reason'::text;
  exception when check_violation then null;
  end;

  perform public.decide_hours_correction(v_corr, true);
  perform set_config('role', 'postgres', true);
  if (select approval from public.work_sessions where id = v_corr) <> 'Approved' then
    failures := failures || 'FAILED: approving the correction did not record it'::text;
  elsif not (select voided from public.work_sessions where id = v_id) then
    failures := failures || 'FAILED: the original was not superseded once the correction was approved'::text;
  else
    raise notice 'ok  and only the manager or Admin decides it, declining says why, and approval supersedes the original';
  end if;

  -- A contractor's own same-day correction needs nobody.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_con_uid, 'role', 'authenticated')::text, true);
  select id into v_id from public.work_sessions
   where staff_id = v_con and worked_on = public.practice_today() and not voided
   order by created_at desc limit 1;
  v_corr := public.request_hours_correction(v_id, 3.50, '', 'ZQ rounded it up');
  perform set_config('role', 'postgres', true);
  if (select approval from public.work_sessions where id = v_corr) <> 'Not needed' then
    failures := failures || 'FAILED: a contractor''s same-day correction was sent to somebody'::text;
  elsif not (select voided from public.work_sessions where id = v_id) then
    failures := failures || 'FAILED: a contractor''s correction did not supersede the original'::text;
  else
    raise notice 'ok  a contractor correcting their own day needs nobody, as it always has';
  end if;

  -- And after the day closes, it is not theirs to change.
  insert into public.work_sessions (staff_id, worked_on, hours, description, created_by)
  values (v_con, public.practice_today() - 3, 4.00, 'ZQ an older day', v_con)
  returning id into v_id;
  perform set_config('role', 'authenticated', true);
  begin
    perform public.request_hours_correction(v_id, 5.00, '', 'ZQ thought better of it');
    failures := failures || 'FAILED: a contractor changed a day that had closed'::text;
  exception when check_violation then
    raise notice 'ok  and a day that has closed is not theirs to change';
  end;
  perform set_config('role', 'postgres', true);

  -- ── the totals are the sum of what counts ────────────────
  select coalesce(sum(w.hours), 0) into v_total
    from public.work_sessions w where w.staff_id = v_con and public.hours_count(w);
  if (select coalesce(total_hours, 0) from public.work_session_totals
       where staff_id = v_con and period_start = public.period_start(public.practice_today())) is null then
    raise notice 'note  the contractor has no hours in the current period to total';
  end if;
  select coalesce(sum(total_hours), 0) into v_hours from public.work_session_totals where staff_id = v_con;
  if v_hours <> v_total then
    failures := failures || format('FAILED: the totals say %s and the sessions come to %s', v_hours, v_total)::text;
  else
    raise notice 'ok  the totals are the sum of the sessions that count, and nothing else';
  end if;

  -- ── clocking is not required of a contractor ─────────────
  -- Which is to say: hours typed in without a clock are a complete record for
  -- them, and the clock columns being empty is not a fault.
  if (select started_at from public.work_sessions where id = v_id) is not null then
    failures := failures || 'FAILED: hours entered by hand were given a clock they never had'::text;
  elsif not public.hours_count((select w from public.work_sessions w where w.id = v_id)) then
    failures := failures || 'FAILED: hours entered without the clock do not count'::text;
  elsif (select approval from public.work_sessions where id = v_id) <> 'Not needed' then
    failures := failures || 'FAILED: a contractor''s hours were made to wait on somebody'::text;
  else
    raise notice 'ok  a contractor need not clock: hours without one are a complete record';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- TIME CLOCK VERIFIED ---';
end $$;

rollback;
