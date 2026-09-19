-- Zion Vocational Rehab CRM — who reviews the inbox, and re-signing the policy (0103)
--
-- What has to hold, each tried from the direction that would break it:
--
--   Admin sees and acts on every inbox document. Billing sees and acts on the
--   authorizations only - read as one or named as one - and cannot touch the
--   rest even by calling the functions directly with a document's id. Job
--   Search and Reports see none of it. Only Admin says whose a folder is.
--
--   A policy version in force that somebody has not signed is due; signing it
--   clears it; what they signed before stays on file. A paper tick counts as
--   version 1 only.
--
-- Uses made-up staff and documents (ZZ). Runs inside a transaction that is
-- rolled back.

begin;

do $$
declare
  v_adm_uid  uuid;
  v_bil      uuid;
  v_bil_uid  uuid := gen_random_uuid();
  v_job      uuid;
  v_job_uid  uuid := gen_random_uuid();
  v_client   uuid;
  v_auth_doc uuid;
  v_named    uuid;
  v_other    uuid;
  v_n        integer;
  v_file     uuid;
  v_task     uuid;
  failures   text[] := '{}';
begin
  select user_id into v_adm_uid from public.staff
   where role = 'Admin' and active and user_id is not null order by created_at, id limit 1;

  insert into public.staff (name, email, role, active) values ('ZZ Inbox Billing', 'zz-inbox-billing@example.test', 'Billing', true) returning id into v_bil;
  insert into public.staff (name, email, role, active) values ('ZZ Inbox JobSearch', 'zz-inbox-job@example.test', 'Job Search', true) returning id into v_job;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_bil_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-inbox-billing@example.test', '{}', '{}', now(), now()),
         (v_job_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-inbox-job@example.test', '{}', '{}', now(), now());

  insert into public.clients (name, stage, status) values ('ZZ Inbox Access Client', 'Intake', 'Active') returning id into v_client;
  insert into public.inbox_documents (sha256, folder_name, relative_path, filename, size_bytes, client_id, kind, storage_path)
  values ('c1' || repeat('0', 62), 'ZZ Folder', 'ZZ Folder\auth.pdf', 'auth.pdf', 10, v_client, 'Authorization', 'inbox/zz/auth.pdf')
  returning id into v_auth_doc;
  insert into public.inbox_documents (sha256, folder_name, relative_path, filename, size_bytes, client_id, kind, storage_path, proposal)
  values ('c2' || repeat('0', 62), 'ZZ Folder', 'ZZ Folder\V123 auth.pdf', 'V123 auth.pdf', 10, v_client, 'Other', 'inbox/zz/named.pdf',
          '{"filename": {"named": "Authorization"}}'::jsonb)
  returning id into v_named;
  insert into public.inbox_documents (sha256, folder_name, relative_path, filename, size_bytes, client_id, kind, storage_path)
  values ('c3' || repeat('0', 62), 'ZZ Folder', 'ZZ Folder\schedule.pdf', 'schedule.pdf', 10, v_client, 'Other', 'inbox/zz/other.pdf')
  returning id into v_other;

  perform set_config('role', 'authenticated', true);

  -- ── Billing ────────────────────────────────────────────────
  perform set_config('request.jwt.claims', json_build_object('sub', v_bil_uid, 'role', 'authenticated')::text, true);
  select count(*) into v_n from public.inbox_documents where id in (v_auth_doc, v_named, v_other);
  if v_n <> 2 or exists (select 1 from public.inbox_pending where id = v_other) then
    failures := failures || format('FAILED: Billing saw %s of the three documents, not the two authorizations', v_n)::text;
  end if;
  update public.inbox_documents set state = 'Ignored' where id = v_other;
  begin
    perform public.file_document_as_note(v_other, 'General', public.practice_today(), 'Read from the document', 'ZZ', 'Other');
    failures := failures || 'FAILED: Billing filed a document that is not an authorization'::text;
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.link_document_to_authorization(v_other, gen_random_uuid(), 'Invoice');
    failures := failures || 'FAILED: Billing put a document that is not an authorization on an authorization'::text;
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.confirm_authorization_document(p_doc => v_other, p_number => 'ZZ-1');
    failures := failures || 'FAILED: Billing confirmed a document that is not an authorization'::text;
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.inbox_folder_map (folder_name, client_id, mapped_by) values ('ZZ Unclaimed', v_client, v_bil);
    failures := failures || 'FAILED: Billing said whose a folder is'::text;
  exception when insufficient_privilege then null;
  end;

  -- ── Job Search ─────────────────────────────────────────────
  perform set_config('request.jwt.claims', json_build_object('sub', v_job_uid, 'role', 'authenticated')::text, true);
  select count(*) into v_n from public.inbox_documents where id in (v_auth_doc, v_named, v_other);
  if v_n <> 0 then
    failures := failures || format('FAILED: Job Search saw %s inbox documents', v_n)::text;
  end if;
  begin
    perform public.file_document_as_note(v_auth_doc, 'General', public.practice_today(), 'Read from the document', 'ZZ', 'Other');
    failures := failures || 'FAILED: Job Search filed an inbox document'::text;
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.inbox_folder_map (folder_name, client_id, mapped_by) values ('ZZ Unclaimed', v_client, v_job);
    failures := failures || 'FAILED: Job Search said whose a folder is'::text;
  exception when insufficient_privilege then null;
  end;

  -- ── Admin ──────────────────────────────────────────────────
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);
  select count(*) into v_n from public.inbox_documents where id in (v_auth_doc, v_named, v_other);
  perform set_config('role', 'postgres', true);
  if v_n <> 3 then
    failures := failures || format('FAILED: Admin saw %s of the three documents', v_n)::text;
  elsif (select state from public.inbox_documents where id = v_other) <> 'Pending' then
    failures := failures || 'FAILED: Billing set aside a document that is not an authorization'::text;
  else
    raise notice 'ok  Admin sees the whole inbox; Billing the authorizations only, even calling the functions directly; Job Search none; folders are Admin''s';
  end if;

  -- ── the policy, signed again ───────────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_bil_uid, 'role', 'authenticated')::text, true);
  if not public.policy_signature_due() then
    failures := failures || 'FAILED: somebody who has signed nothing was not due to sign'::text;
  end if;

  -- An earlier version, signed: still due, because a later one is in force.
  perform set_config('role', 'postgres', true);
  insert into public.staff_files (staff_id, storage_path, filename, mime_type, size_bytes, category, uploaded_by)
  values (v_bil, 'zz/policy-v1.pdf', 'v1.pdf', 'application/pdf', 10, 'Signed policy', v_bil) returning id into v_file;
  insert into public.staff_policy_signatures (staff_id, policy_key, policy_version, text_sha256, signer_name, staff_file_id)
  select v_bil, key, version, text_sha256, 'ZZ Inbox Billing', v_file from public.staff_policies
   where key = 'data-handling' and not is_current order by version limit 1;
  perform set_config('role', 'authenticated', true);
  if not public.policy_signature_due() then
    failures := failures || 'FAILED: a signature on an earlier version counted for the one in force'::text;
  end if;

  insert into public.staff_files (staff_id, storage_path, filename, mime_type, size_bytes, category, uploaded_by)
  values (v_bil, 'zz/policy-now.pdf', 'now.pdf', 'application/pdf', 10, 'Signed policy', v_bil) returning id into v_file;
  perform public.sign_staff_policy('data-handling', (select version from public.staff_policies where key = 'data-handling' and is_current),
                                   'ZZ Inbox Billing', '', v_file, '');
  if public.policy_signature_due() then
    failures := failures || 'FAILED: signing the version in force did not clear it'::text;
  elsif (select count(*) from public.staff_policy_signatures where staff_id = v_bil) <> 2 then
    failures := failures || 'FAILED: the earlier signature did not stay on file beside the new one'::text;
  else
    raise notice 'ok  a version in force and unsigned is due; signing clears it; the earlier signature stays on file';
  end if;

  -- A paper tick is version 1.
  perform set_config('role', 'postgres', true);
  select id into v_task from public.checklist_tasks where auto_key = 'policy_signed';
  alter table public.staff_checklist_items disable trigger staff_checklist_no_manual_tick;
  insert into public.staff_checklist_items (staff_id, task_id, done_on) values (v_job, v_task, public.practice_today());
  alter table public.staff_checklist_items enable trigger staff_checklist_no_manual_tick;
  if (select version from public.staff_policies where key = 'data-handling' and is_current) > 1
     and public.onboarding_step_done(v_job, 'policy_signed') then
    failures := failures || 'FAILED: a paper tick counted for a version after the first'::text;
  else
    raise notice 'ok  a paper tick counts as version 1 only';
  end if;

  perform set_config('request.jwt.claims', '', true);
  if has_function_privilege('anon', 'public.policy_signature_due()', 'execute')
     or has_function_privilege('anon', 'public.inbox_document_open_to_me(uuid)', 'execute') then
    failures := failures || 'FAILED: somebody not signed in can ask'::text;
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- INBOX ACCESS AND POLICY RE-SIGNING VERIFIED ---';
end $$;

rollback;
