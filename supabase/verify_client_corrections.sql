-- The client correction log is added to and never changed (0267)
--
-- What has to hold:
--
--   Anybody on the staff can read it, because a log nobody can read is not a
--   log. Only Admin writes to it.
--
--   Nothing can change or delete a row, and nothing can empty the table.
--   TRUNCATE is the one that needs saying out loud: Supabase grants it on
--   every new table in `public` to `authenticated`, it is not subject to
--   row-level security, and it goes straight past a row trigger as well. Both
--   of the table's other defences miss it.
--
--   A row survives the client it describes being merged away, and still says
--   who it was about.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_admin  uuid; v_admin_uid  uuid := gen_random_uuid();
  v_worker uuid; v_worker_uid uuid := gen_random_uuid();
  v_old uuid; v_new uuid; v_row uuid;
  failures text[] := '{}';
begin
  insert into public.staff (name, email, role, active)
  values ('ZZ Correction Admin', 'zz-corr-admin@example.test', 'Admin', true) returning id into v_admin;
  insert into public.staff (name, email, role, active)
  values ('ZZ Correction Worker', 'zz-corr-worker@example.test', 'Job Search', true) returning id into v_worker;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_admin_uid,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-corr-admin@example.test',  '{}', '{}', now(), now()),
         (v_worker_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-corr-worker@example.test', '{}', '{}', now(), now());

  insert into public.clients (name, stage, status) values ('ZZ Correction Old', 'Intake', 'Active') returning id into v_old;
  insert into public.clients (name, stage, status) values ('ZZ Correction New', 'Intake', 'Active') returning id into v_new;

  -- ── only Admin writes ──────────────────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_worker_uid, 'role', 'authenticated')::text, true);
  begin
    insert into public.client_corrections (client_id, client_name, field, reason, staff_name)
    values (v_old, 'ZZ Correction Old', 'phone', 'ZQ because', 'ZZ Correction Worker');
    failures := failures || 'FAILED: somebody who is not Admin wrote to the correction log'::text;
  exception when insufficient_privilege then null;
  end;

  perform set_config('request.jwt.claims', json_build_object('sub', v_admin_uid, 'role', 'authenticated')::text, true);
  insert into public.client_corrections (client_id, client_name, field, was_value, new_value, reason, staff_id, staff_name)
  values (v_old, 'ZZ Correction Old', 'phone', '801-555-0000', '801-555-0142',
          'ZQ the number was typed from the wrong line of the referral', v_admin, 'ZZ Correction Admin')
  returning id into v_row;
  raise notice 'ok  Admin writes a correction and nobody else does';

  -- ── everybody on the staff reads it ────────────────────────
  perform set_config('request.jwt.claims', json_build_object('sub', v_worker_uid, 'role', 'authenticated')::text, true);
  if not exists (select 1 from public.client_corrections where id = v_row) then
    failures := failures || 'FAILED: a member of staff cannot read the correction log'::text;
  else
    raise notice 'ok  anybody on the staff can read what was corrected';
  end if;

  -- ── added to, never changed ────────────────────────────────
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin_uid, 'role', 'authenticated')::text, true);
  begin
    update public.client_corrections set reason = 'ZQ something else' where id = v_row;
    failures := failures || 'FAILED: a correction was edited after the fact'::text;
  exception when insufficient_privilege then null;
  end;
  begin
    delete from public.client_corrections where id = v_row;
    failures := failures || 'FAILED: a correction was deleted'::text;
  exception when insufficient_privilege then null;
  end;
  if not exists (select 1 from public.client_corrections where id = v_row
                  and reason like 'ZQ the number was typed%') then
    failures := failures || 'FAILED: the correction does not say what it said when it was written'::text;
  else
    raise notice 'ok  a correction cannot be edited or deleted, by Admin or anybody else';
  end if;

  -- And the trigger refuses it as well, not only the grant.
  --
  -- Asserted separately because the two defences are not interchangeable and
  -- the first version of this script could not tell them apart: `authenticated`
  -- has no UPDATE on the table, so the update above is stopped by the grant and
  -- never reaches the trigger. Dropping the trigger changed nothing and the
  -- script still passed. What the trigger is for is the caller the grant does
  -- not stop - a SECURITY DEFINER function, a migration, a script run with the
  -- service key - which is most of what writes to this database.
  perform set_config('role', 'postgres', true);
  begin
    update public.client_corrections set reason = 'ZQ rewritten by something privileged' where id = v_row;
    failures := failures || 'FAILED: a privileged caller edited a correction; only the grant stands in the way'::text;
  exception when insufficient_privilege then null;
  end;
  begin
    delete from public.client_corrections where id = v_row;
    failures := failures || 'FAILED: a privileged caller deleted a correction'::text;
  exception when insufficient_privilege then null;
  end;
  if (select reason from public.client_corrections where id = v_row) like 'ZQ rewritten%' then
    failures := failures || 'FAILED: the correction was rewritten'::text;
  else
    raise notice 'ok  the append-only trigger refuses a caller the grants would have let through';
  end if;

  -- ── and the table cannot be emptied ────────────────────────
  -- Not caught by the policies, which are per row, and not caught by the
  -- append-only trigger, which is per row as well. Only the revoke stops it.
  perform set_config('role', 'postgres', true);
  if has_table_privilege('authenticated', 'public.client_corrections', 'TRUNCATE') then
    failures := failures || 'FAILED: anybody signed in can empty the correction log in one statement'::text;
  elsif has_table_privilege('authenticated', 'public.client_corrections', 'DELETE')
     or has_table_privilege('authenticated', 'public.client_corrections', 'UPDATE') then
    failures := failures || 'FAILED: the correction log is granted DELETE or UPDATE, so only a trigger stands in the way'::text;
  elsif has_table_privilege('anon', 'public.client_corrections', 'SELECT') then
    failures := failures || 'FAILED: somebody not signed in can read the correction log'::text;
  else
    raise notice 'ok  the log cannot be emptied, and the grants do not rely on the trigger to say so';
  end if;

  -- ── it outlives the record it is about ─────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin_uid, 'role', 'authenticated')::text, true);
  perform public.merge_clients(v_old, v_new);
  perform set_config('role', 'postgres', true);

  if not exists (select 1 from public.client_corrections where id = v_row) then
    failures := failures || 'FAILED: the correction went with the record it described'::text;
  elsif (select client_name from public.client_corrections where id = v_row) <> 'ZZ Correction Old' then
    failures := failures || 'FAILED: the correction no longer says which record it was about'::text;
  else
    raise notice 'ok  a correction survives the record being merged away and still names it';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- CLIENT CORRECTION LOG VERIFIED ---';
end $$;

rollback;
