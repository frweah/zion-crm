-- Zion Vocational Rehab CRM — the capacity view
--
-- This one decides where the next referral goes, so the ways it can be wrong
-- are ways somebody gets given work they cannot do: counting a closed client
-- as a caseload, counting a flat fee as hours nobody has to deliver, or
-- counting a superseded time record as delivery.
--
-- It also has to stay honest about who may see what. The view is security
-- invoker over work_session_values, which shows a person their own hours and
-- Admin everybody's — so a non-admin reading it sees colleagues at zero. That
-- is why the screen is Admin only, and this checks the reason still holds.
--
-- Runs inside a transaction that is rolled back. Nothing here is left behind.

begin;

do $$
declare
  v_admin   uuid;
  v_adm_uid uuid;
  v_other   uuid;
  v_oth_uid uuid;
  v_client  uuid;
  v_auth    uuid;
  v_id      uuid;
  r         record;
  v_before  numeric;
  failures  text[] := '{}';
begin
  select id, user_id into v_admin, v_adm_uid from public.staff
   where role = 'Admin' and active order by created_at limit 1;
  select id, user_id into v_other, v_oth_uid from public.staff
   where active and id <> v_admin order by created_at limit 1;

  -- ── a caseload is active clients, not every client ─────────
  insert into public.clients (name, stage, status, assigned_staff_id)
  values ('ZZ Capacity Active', 'Job Development', 'Active', v_admin)
  returning id into v_client;

  insert into public.clients (name, stage, status, assigned_staff_id)
  values ('ZZ Capacity Closed', 'Closed', 'Closed', v_admin);

  select * into r from public.staff_capacity where staff_id = v_admin;
  if r.active_clients <> 1 then
    failures := failures || format('FAILED: one active and one closed client reads as %s',
                                   r.active_clients);
  else
    raise notice 'ok  a caseload counts active clients, and a closed one is not a caseload';
  end if;

  -- Adding a client sets their stage, and setting a stage is activity, so a
  -- client created a second ago is correctly not quiet.
  if r.quiet_clients <> 0 then
    failures := failures || format('FAILED: a client created seconds ago reads as %s quiet',
                                   r.quiet_clients);
  else
    raise notice 'ok  a client added today is not quiet — setting their stage was activity';
  end if;

  -- With nothing recorded at all, they are the loudest kind of quiet. They
  -- must count, or the people most in need of chasing are the ones who
  -- disappear from the screen meant to find them.
  delete from public.client_stage_history where client_id = v_client;

  select * into r from public.staff_capacity where staff_id = v_admin;
  if r.quiet_clients <> 1 then
    failures := failures || format('FAILED: a client nothing has ever happened to reads as %s quiet',
                                   r.quiet_clients);
  else
    raise notice 'ok  a client nothing has ever happened to counts as quiet';
  end if;

  -- ── owed: hours for hourly, value for both ─────────────────
  insert into public.authorizations (client_id, number, service_type, total_hours, rate,
                                     rate_type, status)
  values (v_client, 'ZZ-CAP-H', 'Job Coaching', 20, 45, 'Hourly', 'Open')
  returning id into v_auth;

  insert into public.authorizations (client_id, number, service_type, rate, rate_type, status)
  values (v_client, 'ZZ-CAP-F', 'Job Placement', 1000, 'Flat Fee', 'Open');

  select * into r from public.staff_capacity where staff_id = v_admin;
  if r.committed_hours <> 20 then
    failures := failures || format('FAILED: 20 hourly hours plus a flat fee reads as %s hours owed',
                                   r.committed_hours);
  else
    raise notice 'ok  a flat fee adds no hours to deliver — it has none';
  end if;

  if r.committed_value <> 1900 then
    failures := failures || format('FAILED: $900 of hours plus a $1000 fee reads as %s owed',
                                   r.committed_value);
  else
    raise notice 'ok  but it does add its money, so the value counts both kinds';
  end if;

  if r.open_authorizations <> 2 then
    failures := failures || format('FAILED: two open authorizations read as %s', r.open_authorizations);
  else
    raise notice 'ok  both authorizations are counted as open work';
  end if;

  -- A closed authorization is not owed to anybody.
  update public.authorizations set status = 'Paid' where id = v_auth;
  select * into r from public.staff_capacity where staff_id = v_admin;
  if r.committed_hours <> 0 then
    failures := failures || format('FAILED: a closed authorization still owes %s hours',
                                   r.committed_hours);
  else
    raise notice 'ok  closing an authorization stops it being owed';
  end if;

  -- ── delivered: what was logged, not what was superseded ────
  select hours_30 into v_before from public.staff_capacity where staff_id = v_admin;

  insert into public.work_sessions (staff_id, worked_on, hours, description, category, created_by)
  values (v_admin, public.practice_today(), 4, 'ZZ delivered', 'direct', v_admin)
  returning id into v_id;

  select * into r from public.staff_capacity where staff_id = v_admin;
  if r.hours_30 <> v_before + 4 then
    failures := failures || format('FAILED: four hours logged moved the total to %s from %s',
                                   r.hours_30, v_before);
  else
    raise notice 'ok  logged hours count as delivered';
  end if;

  insert into public.work_sessions (staff_id, worked_on, hours, description, category,
                                    corrects_id, correction_reason, created_by)
  values (v_admin, public.practice_today(), 1, 'ZZ delivered', 'direct',
          v_id, 'ZZ it was one hour, not four', v_admin);

  select * into r from public.staff_capacity where staff_id = v_admin;
  if r.hours_30 <> v_before + 1 then
    failures := failures || format('FAILED: after correcting 4 to 1, delivery reads %s from %s',
                                   r.hours_30, v_before);
  else
    raise notice 'ok  a corrected session delivers what it was corrected to, not both';
  end if;

  -- ── time that does not reach a client ──────────────────────
  insert into public.work_sessions (staff_id, worked_on, hours, description, category, created_by)
  values (v_admin, public.practice_today(), 3, 'ZZ driving', 'travel', v_admin);

  select * into r from public.staff_capacity where staff_id = v_admin;
  if r.client_hours_90 >= r.hours_90 then
    failures := failures || 'FAILED: travel is being counted as time that reaches a client'::text;
  else
    raise notice 'ok  travel is delivered time that does not reach a client, and is separated';
  end if;

  insert into public.work_sessions (staff_id, worked_on, hours, description, created_by)
  values (v_admin, public.practice_today(), 2, 'ZZ nothing said', v_admin);

  select * into r from public.staff_capacity where staff_id = v_admin;
  if r.uncategorised_hours_90 < 2 then
    failures := failures || 'FAILED: hours that say nothing are not reported as unsaid'::text;
  else
    raise notice 'ok  hours that say nothing are counted apart, not assumed either way';
  end if;

  -- ── only active staff have a capacity ──────────────────────
  if exists (
    select 1 from public.staff_capacity c
      join public.staff s on s.id = c.staff_id
     where not s.active
  ) then
    failures := failures || 'FAILED: somebody who has left still has a capacity row'::text;
  else
    raise notice 'ok  somebody who has left is not somebody to give work to';
  end if;

  -- ── and the reason the screen is Admin only ────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_oth_uid, 'role', 'authenticated')::text, true);

  select * into r from public.staff_capacity where staff_id = v_admin;
  if r.hours_30 <> 0 then
    failures := failures || 'FAILED: a colleague can read somebody else''s hours through this view'::text;
  else
    raise notice 'ok  a colleague sees zero hours for somebody else — which is why this screen is Admin only';
  end if;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  if failures = '{}' then
    raise notice '';
    raise notice '--- CAPACITY VERIFIED ---';
  else
    raise notice '';
    raise notice '%  PROBLEM(S):', array_length(failures, 1);
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
