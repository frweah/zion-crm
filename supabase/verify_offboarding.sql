-- Zion Vocational Rehab CRM — somebody leaving
--
-- The failure this guards against is a half-finished departure: a caseload
-- belonging to an account nobody can sign into, or an account still open
-- because the reassignment was done on Tuesday and the deactivation never
-- was. So the checks are mostly about the pieces moving together.
--
-- verify_rls already proves the important half — that access ends the moment
-- the account is deactivated. This is about everything hanging off the person
-- when it does.
--
-- Runs inside a transaction that is rolled back. Nothing here is left behind.

begin;

do $$
declare
  v_admin    uuid;
  v_adm_uid  uuid;
  v_leaver   uuid;
  v_leav_uid uuid;
  v_taker    uuid;
  v_client   uuid;
  v_closed   uuid;
  v_task     uuid;
  r          record;
  v_count    int;
  failures   text[] := '{}';
begin
  select id, user_id into v_admin, v_adm_uid from public.staff
   where role = 'Admin' and active order by created_at limit 1;

  -- Two throwaway accounts, so nothing real is offboarded by a test.
  insert into public.staff (name, email, role, active)
  values ('ZZ Leaver', 'zz-leaver@example.com', 'Job Search', true)
  returning id into v_leaver;

  insert into public.staff (name, email, role, active)
  values ('ZZ Taker', 'zz-taker@example.com', 'Job Search', true)
  returning id into v_taker;

  insert into public.clients (name, stage, status, assigned_staff_id)
  values ('ZZ Offboard Active', 'Job Development', 'Active', v_leaver)
  returning id into v_client;

  insert into public.clients (name, stage, status, assigned_staff_id)
  values ('ZZ Offboard Closed', 'Closed', 'Closed', v_leaver)
  returning id into v_closed;

  insert into public.tasks (client_id, assigned_staff_id, title, status, created_by)
  values (v_client, v_leaver, 'ZZ open task', 'Open', v_admin)
  returning id into v_task;

  insert into public.work_session_timers (staff_id, started_at)
  values (v_leaver, now() - interval '3 hours');

  -- ── what is still attached, before anything happens ────────
  select * into r from public.offboarding_readiness where staff_id = v_leaver;
  if r.active_clients <> 1 or r.open_tasks <> 1 or r.running_timers <> 1 then
    failures := failures || format(
      'FAILED: readiness reads %s clients, %s tasks, %s timers',
      r.active_clients, r.open_tasks, r.running_timers);
  else
    raise notice 'ok  what is still attached to them is on the screen before the button is';
  end if;

  -- ── who may do it ──────────────────────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);

  begin
    perform public.offboard_staff(v_admin, public.practice_today(), 'ZZ', null, '');
    failures := failures || 'FAILED: somebody offboarded themselves'::text;
  exception when check_violation then
    raise notice 'ok  nobody offboards themselves — somebody else has to do it';
  end;

  begin
    perform public.offboard_staff(v_leaver, public.practice_today(), 'ZZ', v_leaver, '');
    failures := failures || 'FAILED: somebody took over from themselves'::text;
  exception when check_violation then
    raise notice 'ok  and nobody takes over from themselves';
  end;

  begin
    perform public.offboard_staff(v_leaver, null, 'ZZ', v_taker, '');
    failures := failures || 'FAILED: an offboarding was recorded with no last day'::text;
  exception when check_violation then
    raise notice 'ok  a last day is required — it is the date everything else is measured from';
  end;

  -- ── the whole thing, at once ───────────────────────────────
  select * into r from public.offboard_staff(
    v_leaver, public.practice_today(), 'ZZ resigned', v_taker, 'ZZ note');

  if r.clients_moved <> 1 then
    failures := failures || format('FAILED: %s clients moved, expected 1', r.clients_moved);
  elsif r.tasks_moved <> 1 then
    failures := failures || format('FAILED: %s tasks moved, expected 1', r.tasks_moved);
  elsif not r.timer_discarded then
    failures := failures || 'FAILED: a timer left running was not discarded'::text;
  else
    raise notice 'ok  the caseload, the open tasks and a forgotten timer are dealt with in one act';
  end if;

  if (select assigned_staff_id from public.clients where id = v_client) is distinct from v_taker then
    failures := failures || 'FAILED: the active client did not move to the person taking over'::text;
  else
    raise notice 'ok  the active client is with whoever took over';
  end if;

  -- A closed client stays where they were: who worked with them is part of
  -- the record, and moving it would rewrite history to tidy a list.
  if (select assigned_staff_id from public.clients where id = v_closed) is distinct from v_leaver then
    failures := failures || 'FAILED: a closed client was reassigned as well'::text;
  else
    raise notice 'ok  a closed client stays with whoever actually worked with them';
  end if;

  if (select assigned_staff_id from public.tasks where id = v_task) is distinct from v_taker then
    failures := failures || 'FAILED: the open task did not move'::text;
  else
    raise notice 'ok  the open task went with the caseload';
  end if;

  if exists (select 1 from public.work_session_timers where staff_id = v_leaver) then
    failures := failures || 'FAILED: the timer is still running for somebody who has left'::text;
  else
    raise notice 'ok  a timer nobody stopped is discarded, not turned into hours nobody worked';
  end if;

  -- ── the account is shut, in the same breath ────────────────
  if (select active from public.staff where id = v_leaver) then
    failures := failures || 'FAILED: the account is still active after offboarding'::text;
  elsif (select deactivated_at from public.staff where id = v_leaver) is null then
    failures := failures || 'FAILED: nothing recorded when the account was closed'::text;
  else
    raise notice 'ok  and the account is shut in the same breath, not on a different day';
  end if;

  -- ── the record of it ───────────────────────────────────────
  select * into r from public.staff_offboarding where staff_id = v_leaver;
  if r.last_day is distinct from public.practice_today() then
    failures := failures || 'FAILED: the last day was not recorded'::text;
  elsif r.successor_id is distinct from v_taker then
    failures := failures || 'FAILED: the record does not say who took over'::text;
  elsif r.clients_moved <> 1 or r.reason <> 'ZZ resigned' then
    failures := failures || 'FAILED: the record does not say what was done, or why they left'::text;
  else
    raise notice 'ok  and there is a record of when, why, and where the caseload went';
  end if;

  -- ── leaving nobody in charge is a real choice ──────────────
  insert into public.staff (name, email, role, active)
  values ('ZZ Leaver Two', 'zz-leaver-2@example.com', 'Job Search', true)
  returning id into v_leaver;

  insert into public.clients (name, stage, status, assigned_staff_id)
  values ('ZZ Unassigned After', 'Referral', 'Active', v_leaver)
  returning id into v_client;

  perform public.offboard_staff(v_leaver, public.practice_today(), 'ZZ ended', null, '');

  if (select assigned_staff_id from public.clients where id = v_client) is not null then
    failures := failures || 'FAILED: a client was left pointing at somebody who has gone'::text;
  else
    raise notice 'ok  with nobody named, the clients are unassigned rather than left with a ghost';
  end if;

  -- Unassigned is visible rather than quiet: the capacity screen counts them.
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  select count(*) into v_count from public.clients
   where status = 'Active' and assigned_staff_id is null;
  if v_count < 1 then
    failures := failures || 'FAILED: an unassigned client is not visible anywhere'::text;
  else
    raise notice 'ok  and they surface as unassigned rather than disappearing';
  end if;

  -- ── the checklist answers for itself ───────────────────────
  if not (select auto_done from public.staff_checklist
           where staff_id = v_leaver and auto_key = 'account_closed') then
    failures := failures || 'FAILED: the offboarding checklist does not know the account is closed'::text;
  elsif not (select auto_done from public.staff_checklist
              where staff_id = v_leaver and auto_key = 'clients_reassigned') then
    failures := failures || 'FAILED: the checklist does not know the caseload has moved'::text;
  else
    raise notice 'ok  the offboarding checklist answers both for itself — no tick required';
  end if;

  if failures = '{}' then
    raise notice '';
    raise notice '--- OFFBOARDING VERIFIED ---';
  else
    raise notice '';
    raise notice '%  PROBLEM(S):', array_length(failures, 1);
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
