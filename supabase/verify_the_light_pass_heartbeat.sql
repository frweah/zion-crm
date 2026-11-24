-- Zion Vocational Rehab CRM — the light pass says it ran (0383)
--
-- The quarter-hourly pass reads phone photos and writes no run, so the row it
-- stamps is the only thing that can tell the owner that half of the agent has
-- stopped. What has to hold:
--
--   any active staff member reads it, because it is on a card they open and
--   says nothing about a client;
--
--   nobody signed in writes it - not Admin, not the system account. The agent
--   stamps it as the service role, and a row a staff member could stamp could
--   not answer the question it is there for;
--
--   there is one row per kind, so a pass every fifteen minutes updates in
--   place instead of filling a table nothing trims;
--
--   and a stranger reads nothing.
--
-- Everything is rolled back.

begin;

do $$
declare
  failures text[] := array[]::text[];
  v_mark   integer;
  v_admin  uuid; v_admin_uid uuid := gen_random_uuid();
  v_coach  uuid; v_coach_uid uuid := gen_random_uuid();
  v_sys    uuid; v_sys_uid   uuid := gen_random_uuid();
  v_n      integer;
  v_at     timestamptz;
begin
  insert into public.staff (name, email, role, active)
  values ('ZZ Beat Admin', 'zz-beat-admin@example.test', 'Admin', true) returning id into v_admin;
  insert into public.staff (name, email, role, active)
  values ('ZZ Beat Coach', 'zz-beat-coach@example.test', 'Job Coach', true) returning id into v_coach;
  insert into public.staff (name, email, role, active, is_system)
  values ('ZZ Beat Machine', 'zz-beat-machine@example.test', 'Job Search', true, true) returning id into v_sys;

  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_admin_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-beat-admin@example.test', '{}', '{}', now(), now()),
         (v_coach_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-beat-coach@example.test', '{}', '{}', now(), now()),
         (v_sys_uid,   '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-beat-machine@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_admin_uid where id = v_admin;
  update public.staff set user_id = v_coach_uid where id = v_coach;
  update public.staff set user_id = v_sys_uid   where id = v_sys;

  -- ── 1. one row per kind, updated in place ────────────────────
  --
  -- Asked of the constraint first, and only then of the behaviour. Without a
  -- unique key on `kind` the route's `on conflict (kind)` does not write a
  -- second row - it raises, every fifteen minutes, and the pass that is
  -- supposed to be saying it is alive says nothing at all. So the stamp tests
  -- below are not reached if the key is gone: they would report the error
  -- rather than the rule.
  v_mark := coalesce(array_length(failures, 1), 0);
  select count(*) into v_n
    from pg_index i
    join pg_class c on c.oid = i.indrelid
   where c.relname = 'agent_heartbeat'
     and c.relnamespace = 'public'::regnamespace
     and i.indisunique
     and i.indnkeyatts = 1
     and (select a.attname from pg_attribute a
           where a.attrelid = c.oid and a.attnum = i.indkey[0]) = 'kind';
  if v_n = 0 then
    failures := failures || 'FAILED: nothing makes the kind unique, so a pass every fifteen minutes leaves a row'::text;
    raise exception E'\n%', array_to_string(failures, E'\n');
  end if;

  -- The agent's own stamp, written the way the route writes it.
  insert into public.agent_heartbeat (kind, at, detail)
  values ('ZZ light pass', now() - interval '3 minutes', '2 phone photos read')
  on conflict (kind) do update set at = excluded.at, detail = excluded.detail;

  insert into public.agent_heartbeat (kind, at, detail)
  values ('ZZ light pass', now(), '0 phone photos read')
  on conflict (kind) do update set at = excluded.at, detail = excluded.detail;

  select count(*) into v_n from public.agent_heartbeat where kind = 'ZZ light pass';
  if v_n <> 1 then
    failures := failures || format('FAILED: %s rows for one kind, so the table grows a row a pass', v_n)::text;
  end if;
  select at into v_at from public.agent_heartbeat where kind = 'ZZ light pass';
  if v_at < now() - interval '1 minute' then
    failures := failures || 'FAILED: the second stamp did not move the time'::text;
  end if;

  -- And a second kind is a second row, not a fight over this one.
  insert into public.agent_heartbeat (kind, at) values ('ZZ other pass', now());
  select count(*) into v_n from public.agent_heartbeat where kind like 'ZZ %';
  if v_n <> 2 then
    failures := failures || 'FAILED: two kinds do not keep two rows'::text;
  end if;
  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  one row per kind, stamped in place';
  end if;

  -- ── 2. active staff read it ──────────────────────────────────
  v_mark := coalesce(array_length(failures, 1), 0);
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_coach_uid, 'role', 'authenticated')::text, true);
  select count(*) into v_n from public.agent_heartbeat where kind = 'ZZ light pass';
  if v_n <> 1 then
    failures := failures || 'FAILED: a Job Coach cannot see whether the agent is alive'::text;
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin_uid, 'role', 'authenticated')::text, true);
  select count(*) into v_n from public.agent_heartbeat where kind = 'ZZ light pass';
  if v_n <> 1 then
    failures := failures || 'FAILED: an Admin cannot see whether the agent is alive'::text;
  end if;
  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  anybody who opens the card reads the stamp';
  end if;

  -- ── 3. and nobody signed in writes it ────────────────────────
  v_mark := coalesce(array_length(failures, 1), 0);
  -- As Admin, which is the strongest seat anybody has.
  begin
    insert into public.agent_heartbeat (kind, at) values ('ZZ forged by an Admin', now());
    failures := failures || 'FAILED: an Admin stamped a heartbeat'::text;
  exception when insufficient_privilege then null;
  end;

  /**
   * Refused outright, or allowed and changing nothing - either answer is the
   * rule holding, so the assertion is on the row rather than on the error.
   * A missing grant raises; a policy that merely matches no row does not.
   */
  begin
    update public.agent_heartbeat set at = now() + interval '1 hour' where kind = 'ZZ light pass';
  exception when insufficient_privilege then null;
  end;
  select at into v_at from public.agent_heartbeat where kind = 'ZZ light pass';
  if v_at is null or v_at > now() + interval '1 minute' then
    failures := failures || 'FAILED: an Admin moved the time a stopped task would be judged by'::text;
  end if;

  begin
    delete from public.agent_heartbeat where kind = 'ZZ light pass';
  exception when insufficient_privilege then null;
  end;
  select count(*) into v_n from public.agent_heartbeat where kind = 'ZZ light pass';
  if v_n <> 1 then
    failures := failures || 'FAILED: an Admin deleted the heartbeat'::text;
  end if;

  -- And the system account, which is what an automated run signs in as.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_sys_uid, 'role', 'authenticated')::text, true);
  begin
    insert into public.agent_heartbeat (kind, at) values ('ZZ forged by the machine', now());
    failures := failures || 'FAILED: the system account stamped a heartbeat'::text;
  exception when insufficient_privilege then null;
  end;
  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  the agent stamps it and nobody signed in can say it for them';
  end if;

  -- ── 4. a stranger reads nothing ──────────────────────────────
  v_mark := coalesce(array_length(failures, 1), 0);
  perform set_config('request.jwt.claims', '', true);
  perform set_config('role', 'anon', true);
  begin
    select count(*) into v_n from public.agent_heartbeat;
    if v_n <> 0 then
      failures := failures || 'FAILED: a stranger read the agent heartbeat'::text;
    end if;
  exception when insufficient_privilege then null;
  end;
  perform set_config('role', 'postgres', true);
  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  nobody signed out reads it';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception E'\n%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- THE LIGHT PASS HEARTBEAT VERIFIED ---';
end $$;

rollback;
