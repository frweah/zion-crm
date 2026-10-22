-- Zion Vocational Rehab CRM — the portal resume builder (0229)
--
-- What has to hold, each tried from the direction that would break it:
--
--   A client saves their own resume and nobody else's, only once they have
--   agreed to the terms, and cannot change it while Zion is reviewing it.
--
--   Finishing files a PDF and a Word copy as Resume documents waiting for
--   review, with a task for the assigned staff member - and only with files
--   that are really in storage in this resume's own folder.
--
--   Only Admin, Reports or the assigned staff member approves or sends back.
--   Sending back needs a note, which the client reads, and lets them edit
--   again. Approving accepts both files and answers an open Resume request.
--
-- Runs inside a transaction that is rolled back. Nothing here is left behind.

begin;

do $$
declare
  v_admin uuid; v_adm_uid uuid; v_js uuid; v_js_uid uuid;
  v_client_a uuid; v_client_b uuid;
  v_user_a uuid := gen_random_uuid(); v_user_b uuid := gen_random_uuid();
  v_acct_a uuid; v_acct_b uuid;
  v_sess_a uuid := gen_random_uuid(); v_sess_b uuid := gen_random_uuid();
  v_res uuid; v_folder text; v_req uuid; v_pdf uuid;
  failures text[] := '{}';
begin
  select id, user_id into v_admin, v_adm_uid from public.staff where role = 'Admin' and active and user_id is not null order by created_at limit 1;
  select id, user_id into v_js, v_js_uid from public.staff where role = 'Job Search' and active and user_id is not null order by created_at limit 1;

  insert into public.clients (name, stage, status, assigned_staff_id, phone, email)
  values ('ZZ Resume A', 'Job Coaching', 'Active', v_admin, '(801) 555-0131', 'zz-res-a@example.test') returning id into v_client_a;
  insert into public.clients (name, stage, status, assigned_staff_id, phone, email)
  values ('ZZ Resume B', 'Job Coaching', 'Active', v_admin, '(801) 555-0132', 'zz-res-b@example.test') returning id into v_client_b;
  insert into public.portal_accounts (client_id, kind, name, phone, email)
  values (v_client_a, 'Client', 'ZZ Resume A', '+18015550131', 'zz-res-a@example.test') returning id into v_acct_a;
  insert into public.portal_accounts (client_id, kind, name, phone, email)
  values (v_client_b, 'Client', 'ZZ Resume B', '+18015550132', 'zz-res-b@example.test') returning id into v_acct_b;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_user_a, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'p-' || v_acct_a || '@portal.zionvocrehab.com', '{}', '{}', now(), now()),
         (v_user_b, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'p-' || v_acct_b || '@portal.zionvocrehab.com', '{}', '{}', now(), now());
  insert into public.portal_sessions (id, account_id, auth_user_id) values (v_sess_a, v_acct_a, v_user_a), (v_sess_b, v_acct_b, v_user_b);

  perform set_config('role', 'authenticated', true);

  -- A Resume request already waiting, which approval should answer.
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);
  select r.request_id into v_req from public.portal_request_document(v_client_a, 'Resume') r;

  -- ── saving ─────────────────────────────────────────────────
  perform set_config('request.jwt.claims', json_build_object('sub', v_user_a, 'role', 'authenticated', 'session_id', v_sess_a)::text, true);
  begin
    perform public.portal_save_resume('{"contact":{"name":"ZZ"}}', 1);
    failures := failures || 'FAILED: a resume was saved before consent'::text;
  exception when insufficient_privilege then null;
  end;
  perform public.portal_record_consent('Electronic communication', true, '203.0.113.1', 'zz-agent');
  if (select status from public.portal_my_resume()) <> 'None'
     or (select record_name from public.portal_my_resume()) <> 'ZZ Resume A' then
    failures := failures || 'FAILED: a new resume did not start from the record'::text;
  end if;
  v_res := public.portal_save_resume('{"contact":{"name":"ZZ Resume A"},"jobs":[{"employer":"ZZ Co"}]}', 2);
  if public.portal_save_resume('{"contact":{"name":"ZZ Resume A"},"jobs":[{"employer":"ZZ Co","title":"Clerk"}]}', 3) <> v_res then
    failures := failures || 'FAILED: saving again started a second resume'::text;
  end if;
  if (select step from public.portal_my_resume()) <> 3 then
    failures := failures || 'FAILED: the step was not kept, so coming back would start over'::text;
  end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_user_b, 'role', 'authenticated', 'session_id', v_sess_b)::text, true);
  perform public.portal_record_consent('Electronic communication', true, '203.0.113.2', 'zz-agent');
  if (select id from public.portal_my_resume()) is not null then
    failures := failures || 'FAILED: one client saw another client''s resume'::text;
  end if;
  if exists (select 1 from public.portal_resumes) then
    failures := failures || 'FAILED: a portal client read the resumes table'::text;
  end if;

  -- ── finishing ──────────────────────────────────────────────
  perform set_config('request.jwt.claims', json_build_object('sub', v_user_a, 'role', 'authenticated', 'session_id', v_sess_a)::text, true);
  v_folder := public.portal_resume_folder();
  begin
    perform public.portal_submit_resume(v_folder || 'a.pdf', 10, 'zz1', v_folder || 'a.docx', 10, 'zz2');
    failures := failures || 'FAILED: a resume was finished with no files in storage'::text;
  exception when check_violation then null;
  end;
  perform set_config('role', 'postgres', true);
  insert into storage.objects (bucket_id, name, metadata) values
    ('client-files', v_folder || 'a.pdf', '{}'), ('client-files', v_folder || 'a.docx', '{}'),
    ('client-files', 'portal/' || v_client_b || '/resume/x/b.pdf', '{}');
  perform set_config('role', 'authenticated', true);
  begin
    perform public.portal_submit_resume('portal/' || v_client_b || '/resume/x/b.pdf', 10, 'zz1', v_folder || 'a.docx', 10, 'zz2');
    failures := failures || 'FAILED: a resume was finished with a file from outside its own folder'::text;
  exception when check_violation then null;
  end;
  perform public.portal_submit_resume(v_folder || 'a.pdf', 10, 'zz1-' || v_res, v_folder || 'a.docx', 10, 'zz2-' || v_res);
  begin
    perform public.portal_save_resume('{"contact":{"name":"changed"}}', 1);
    failures := failures || 'FAILED: a resume was changed while Zion was reviewing it'::text;
  exception when check_violation then null;
  end;

  perform set_config('role', 'postgres', true);
  select pdf_id into v_pdf from public.portal_resumes where id = v_res;
  if (select count(*) from public.attachments where client_id = v_client_a and category = 'Resume' and review_status = 'Waiting' and source = 'Portal') <> 2 then
    failures := failures || 'FAILED: finishing did not file a PDF and a Word copy waiting for review'::text;
  end if;
  if not exists (select 1 from public.tasks where source_kind = 'portal_resume' and source_ref = v_res and status = 'Open'
                  and assigned_staff_id = v_admin and title = 'Review resume for ZZ Resume A') then
    failures := failures || 'FAILED: no "Review resume for" task for the assigned staff member'::text;
  end if;

  -- ── review ─────────────────────────────────────────────────
  perform set_config('role', 'authenticated', true);
  if v_js_uid is not null then
    perform set_config('request.jwt.claims', json_build_object('sub', v_js_uid, 'role', 'authenticated')::text, true);
    begin
      perform public.portal_review_resume(v_res, true);
      failures := failures || 'FAILED: staff who do not manage the client approved the resume'::text;
    exception when insufficient_privilege then null;
    end;
  end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);
  begin
    perform public.portal_review_resume(v_res, false, ' ');
    failures := failures || 'FAILED: a resume was sent back with no note'::text;
  exception when check_violation then null;
  end;
  perform public.portal_review_resume(v_res, false, 'Add the dates for your last job.');

  perform set_config('request.jwt.claims', json_build_object('sub', v_user_a, 'role', 'authenticated', 'session_id', v_sess_a)::text, true);
  if (select status from public.portal_my_resume()) <> 'Returned'
     or (select return_note from public.portal_my_resume()) <> 'Add the dates for your last job.' then
    failures := failures || 'FAILED: the client cannot see that it came back, or why'::text;
  end if;
  perform public.portal_save_resume('{"contact":{"name":"ZZ Resume A"},"jobs":[{"employer":"ZZ Co","title":"Clerk","start":"2025-01"}]}', 8);
  v_folder := public.portal_resume_folder();
  perform set_config('role', 'postgres', true);
  insert into storage.objects (bucket_id, name, metadata) values ('client-files', v_folder || 'b.pdf', '{}'), ('client-files', v_folder || 'b.docx', '{}');
  perform set_config('role', 'authenticated', true);
  perform public.portal_submit_resume(v_folder || 'b.pdf', 10, 'zz3-' || v_res, v_folder || 'b.docx', 10, 'zz4-' || v_res);

  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);
  perform public.portal_review_resume(v_res, true);
  perform set_config('role', 'postgres', true);
  select pdf_id into v_pdf from public.portal_resumes where id = v_res;
  if (select status from public.portal_resumes where id = v_res) <> 'Approved'
     or (select review_status from public.attachments where id = v_pdf) <> 'Accepted' then
    failures := failures || 'FAILED: approving did not approve the resume and accept its files'::text;
  end if;
  if (select status from public.portal_requests where id = v_req) <> 'Accepted'
     or (select attachment_id from public.portal_requests where id = v_req) is distinct from v_pdf then
    failures := failures || 'FAILED: approving did not answer the open Resume request'::text;
  end if;
  if exists (select 1 from public.tasks where source_kind = 'portal_resume' and source_ref = v_res and status = 'Open') then
    failures := failures || 'FAILED: a review task stayed open after the review'::text;
  end if;

  if has_function_privilege('anon', 'public.portal_submit_resume(text, bigint, text, text, bigint, text)', 'execute')
     or has_function_privilege('anon', 'public.portal_review_resume(uuid, boolean, text)', 'execute') then
    failures := failures || 'FAILED: a resume function can be called by somebody signed out'::text;
  end if;

  if array_length(failures, 1) > 0 then
    raise exception E'\n%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- PORTAL RESUME VERIFIED ---';
end;
$$;

rollback;
