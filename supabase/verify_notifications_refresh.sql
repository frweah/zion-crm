-- Zion Vocational Rehab CRM — the alerts' last run is recorded
--
-- What has to hold, each tried from the direction that would break it:
--
--   Working the alerts out writes down when, so the dashboard can tell an
--   hour-old set from a fresh one without recalculating to find out.
--
--   Staff can read when it ran; nobody can write it by hand; nobody signed out
--   can read it; a signed-in user who is not staff still cannot run it.
--
-- Runs inside a transaction that is rolled back. Nothing here is left behind.

begin;

do $$
declare
  v_uid     uuid;
  v_before  timestamptz;
  v_after   timestamptz;
  failures  text[] := '{}';
begin
  select user_id into v_uid from public.staff
   where active and user_id is not null order by created_at, id limit 1;

  update public.job_runs set last_run_at = now() - interval '3 hours' where job = 'notifications';
  select last_run_at into v_before from public.job_runs where job = 'notifications';

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);

  perform public.generate_notifications();
  select last_run_at into v_after from public.job_runs where job = 'notifications';
  if v_after is null or v_after <= coalesce(v_before, '-infinity'::timestamptz) then
    failures := failures || 'FAILED: working the alerts out did not record when'::text;
  else
    raise notice 'ok  working the alerts out records when, for the dashboard to read';
  end if;

  begin
    update public.job_runs set last_run_at = now() - interval '1 day' where job = 'notifications';
    if (select last_run_at from public.job_runs where job = 'notifications') < now() - interval '1 hour' then
      failures := failures || 'FAILED: a member of staff rewrote when the alerts last ran'::text;
    end if;
  exception when insufficient_privilege then null;
  end;
  raise notice 'ok  nobody writes the run record by hand';

  perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
  begin
    perform public.generate_notifications();
    failures := failures || 'FAILED: a signed-in user who is not staff worked the alerts out'::text;
  exception when insufficient_privilege then null;
  end;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('role', 'postgres', true);

  if has_table_privilege('anon', 'public.job_runs', 'select') then
    failures := failures || 'FAILED: somebody not signed in can read the run record'::text;
  else
    raise notice 'ok  staff read it; nobody signed out does; non-staff still cannot run it';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- NOTIFICATIONS REFRESH VERIFIED ---';
end $$;

rollback;
