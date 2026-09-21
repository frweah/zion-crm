-- Zion Vocational Rehab CRM — the system account reads and never writes (0120)
--
-- What has to hold, each tried from the direction that would break it:
--
--   A system account reads what Job Search reads.
--
--   It cannot insert, update or delete anything - a client, a note, a task,
--   a preference - while a person with the same role still can.
--
--   It is Job Search and nothing more: it cannot be made Admin, and no area
--   can be given to it.
--
--   Every table with row-level security carries the rule, including any a
--   later migration adds.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_bot uuid; v_bot_uid uuid := gen_random_uuid();
  v_person uuid; v_person_uid uuid := gen_random_uuid();
  v_client uuid;
  v_n integer;
  v_missing text;
  failures text[] := '{}';
begin
  -- Staff first: an account can only be made for somebody already on staff,
  -- and making it links the two.
  insert into public.staff (name, email, role, active, is_system) values ('ZZ Automated check', 'zz-bot@example.test', 'Job Search', true, true) returning id into v_bot;
  insert into public.staff (name, email, role, active) values ('ZZ Person', 'zz-person@example.test', 'Job Search', true) returning id into v_person;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_bot_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-bot@example.test', '{}', '{}', now(), now()),
         (v_person_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-person@example.test', '{}', '{}', now(), now());
  insert into public.clients (name, stage, status) values ('ZZ System Client', 'Intake', 'Active') returning id into v_client;

  -- ── the system account ────────────────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_bot_uid, 'role', 'authenticated')::text, true);

  if not exists (select 1 from public.clients where id = v_client) then
    failures := failures || 'FAILED: the system account cannot read what Job Search reads'::text;
  end if;

  begin
    insert into public.clients (name, stage, status) values ('ZZ Bot Client', 'Intake', 'Active');
    failures := failures || 'FAILED: the system account added a client'::text;
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.notes (client_id, type, text) values (v_client, 'General', 'ZZ bot note');
    failures := failures || 'FAILED: the system account wrote a note'::text;
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.staff_prefs (staff_id, key, value) values (v_bot, 'zz', 'true'::jsonb);
    failures := failures || 'FAILED: the system account saved a preference'::text;
  exception when insufficient_privilege then null;
  end;
  update public.clients set name = 'ZZ renamed by the bot' where id = v_client;
  get diagnostics v_n = row_count;
  if v_n <> 0 then
    failures := failures || 'FAILED: the system account changed a client'::text;
  end if;
  delete from public.clients where id = v_client;
  get diagnostics v_n = row_count;
  if v_n <> 0 then
    failures := failures || 'FAILED: the system account removed a client'::text;
  end if;

  -- ── a person with the same role still writes ─────────────
  perform set_config('request.jwt.claims', json_build_object('sub', v_person_uid, 'role', 'authenticated')::text, true);
  update public.clients set name = 'ZZ System Client, renamed' where id = v_client;
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    failures := failures || 'FAILED: a Job Search person can no longer change a client'::text;
  else
    raise notice 'ok  the system account reads and cannot write; a person with the same role still can';
  end if;

  -- ── Job Search and nothing more ───────────────────────────
  perform set_config('role', 'postgres', true);
  begin
    update public.staff set role = 'Admin' where id = v_bot;
    failures := failures || 'FAILED: a system account was made Admin'::text;
  exception when check_violation then null;
  end;
  begin
    insert into public.staff_access_grants (staff_id, area, level) values (v_bot, 'billing', 'view');
    failures := failures || 'FAILED: a system account was given an area beyond its role'::text;
  exception when check_violation then null;
  end;

  -- ── every table carries the rule ──────────────────────────
  select string_agg(c.relname, ', ' order by c.relname) into v_missing
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity
     and (select count(*) from pg_policies p
           where p.schemaname = 'public' and p.tablename = c.relname
             and p.policyname in ('system_read_only_insert', 'system_read_only_update', 'system_read_only_delete')) <> 3;
  if v_missing is not null then
    failures := failures || format('FAILED: these tables do not refuse the system account''s writes - call apply_system_read_only on them: %s', v_missing);
  else
    raise notice 'ok  it is Job Search and nothing more, and every table refuses its writes';
  end if;

  if has_function_privilege('anon', 'public.current_staff_is_system()', 'execute') then
    failures := failures || 'FAILED: somebody not signed in can ask whether they are a system account'::text;
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
