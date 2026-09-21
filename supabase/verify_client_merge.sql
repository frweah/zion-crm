-- Zion Vocational Rehab CRM — merging two records for one client (0115)
--
-- What has to hold, each tried from the direction that would break it:
--
--   Everything that pointed at the record merged away points at the kept
--   one afterwards - notes, attachments, tasks, authorizations - and its
--   private details fill the kept record's blanks without overwriting them.
--
--   The workbook's client number moves across, so what is keyed on it still
--   finds the client.
--
--   The access log is not rewritten: what it says about the old record stays
--   said about the old record.
--
--   Nobody signed in sees the merged record, and an old link finds where it
--   went. Only Admin merges.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_admin  uuid; v_admin_uid  uuid := gen_random_uuid();
  v_worker uuid; v_worker_uid uuid := gen_random_uuid();
  v_old uuid; v_new uuid;
  v_n integer;
  failures text[] := '{}';
begin
  insert into public.staff (name, email, role, active) values ('ZZ Merge Admin', 'zz-merge-admin@example.test', 'Admin', true) returning id into v_admin;
  insert into public.staff (name, email, role, active) values ('ZZ Merge Worker', 'zz-merge-worker@example.test', 'Job Search', true) returning id into v_worker;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_admin_uid,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-merge-admin@example.test',  '{}', '{}', now(), now()),
         (v_worker_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-merge-worker@example.test', '{}', '{}', now(), now());

  insert into public.clients (name, stage, status, phone, legacy_id, client_no, assigned_staff_id, created_at)
  values ('Sample ZZ', 'Assessment', 'Closed', '801-555-0142', 'czz9', 99991, v_worker, '2025-05-01')
  returning id into v_old;
  insert into public.clients (name, stage, status, phone, assigned_staff_id)
  values ('ZZ Sample', 'Assessment', 'Active', '', v_worker)
  returning id into v_new;
  insert into public.client_private (client_id, dob, address) values (v_old, '1990-01-02', 'ZZ 1 Old Road');
  insert into public.client_private (client_id, dob, address) values (v_new, null, 'ZZ 2 New Road');
  insert into public.notes (client_id, type, text) values (v_old, 'General', 'ZZ old note');
  insert into public.tasks (client_id, title, due) values (v_old, 'ZZ old task', public.practice_today());
  insert into public.authorizations (client_id, number, service_type, rate_type, rate, status)
  values (v_new, 'V0000998', 'Job Development', 'Flat Fee', 560, 'Open');
  insert into public.access_log (client_id, staff_id, subject) values (v_old, v_worker, 'Client intake');

  -- ── somebody who is not Admin ──────────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_worker_uid, 'role', 'authenticated')::text, true);
  begin
    perform public.merge_clients(v_old, v_new);
    failures := failures || 'FAILED: somebody who is not Admin merged two client records'::text;
  exception when insufficient_privilege then null;
  end;

  -- ── Admin merges ───────────────────────────────────────────
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin_uid, 'role', 'authenticated')::text, true);
  perform public.merge_clients(v_old, v_new);

  perform set_config('role', 'postgres', true);
  if exists (select 1 from public.notes where client_id = v_old)
     or exists (select 1 from public.tasks where client_id = v_old)
     or not exists (select 1 from public.notes where client_id = v_new and text = 'ZZ old note') then
    failures := failures || 'FAILED: activity was left on the record merged away'::text;
  end if;
  if (select dob from public.client_private where client_id = v_new) is distinct from '1990-01-02'::date
     or (select address from public.client_private where client_id = v_new) <> 'ZZ 2 New Road'
     or exists (select 1 from public.client_private where client_id = v_old) then
    failures := failures || 'FAILED: private details did not fill the blanks, or overwrote what the kept record had'::text;
  end if;
  if (select phone from public.clients where id = v_new) <> '801-555-0142'
     or (select name from public.clients where id = v_new) <> 'ZZ Sample'
     or (select client_no from public.clients where id = v_new) is distinct from 99991
     or (select legacy_id from public.clients where id = v_new) is distinct from 'czz9'
     or (select created_at::date from public.clients where id = v_new) <> '2025-05-01'::date then
    failures := failures || 'FAILED: the kept record did not take the blanks, the client number and the earlier start - or lost its own name'::text;
  else
    raise notice 'ok  the whole history is on the kept record, its blanks filled and nothing of its own overwritten';
  end if;
  if (select count(*) from public.access_log where client_id = v_old) <> 1 then
    failures := failures || 'FAILED: the access log was rewritten by a merge'::text;
  end if;

  -- ── what staff see afterwards ─────────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_worker_uid, 'role', 'authenticated')::text, true);
  if exists (select 1 from public.clients where id = v_old) then
    failures := failures || 'FAILED: the merged record can still be seen'::text;
  end if;
  if public.client_merged_into(v_old) is distinct from v_new then
    failures := failures || 'FAILED: an old link does not find where the record went'::text;
  else
    raise notice 'ok  the merged record is out of sight, an old link finds the kept one, and the access log still says what it said';
  end if;

  -- Twice is refused.
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin_uid, 'role', 'authenticated')::text, true);
  begin
    perform public.merge_clients(v_old, v_new);
    failures := failures || 'FAILED: a record already merged was merged again'::text;
  exception when others then null;
  end;

  perform set_config('role', 'postgres', true);
  if has_function_privilege('anon', 'public.merge_clients(uuid, uuid)', 'execute')
     or has_function_privilege('anon', 'public.client_merged_into(uuid)', 'execute') then
    failures := failures || 'FAILED: somebody not signed in can reach the merge'::text;
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
