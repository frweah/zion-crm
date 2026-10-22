-- Zion Vocational Rehab CRM — portal document requests and uploads (0228)
--
-- What has to hold, each tried from the direction that would break it:
--
--   Only Admin, Reports or the assigned staff member asks a client for a
--   document, and an "Other" request has to say what it is.
--
--   A client sees their own requests once they have agreed to the terms,
--   and nobody else's. They get a place to upload only for their own open
--   request, and a request is answered only with a file that is really in
--   storage at the place that was handed out.
--
--   An answered request is filed in the client's documents under the right
--   category, waiting for review, with a task for the assigned staff member.
--   Sending it back needs a reason the client can read, reopens the request
--   and closes the task; accepting marks both the request and the document.
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
  v_req uuid; v_req2 uuid; v_convs uuid[]; v_path text; v_att uuid;
  failures text[] := '{}';
begin
  select id, user_id into v_admin, v_adm_uid from public.staff where role = 'Admin' and active and user_id is not null order by created_at limit 1;
  select id, user_id into v_js, v_js_uid from public.staff where role = 'Job Search' and active and user_id is not null order by created_at limit 1;

  insert into public.clients (name, stage, status, assigned_staff_id, phone, email)
  values ('ZZ Req A', 'Job Coaching', 'Active', v_admin, '(801) 555-0121', 'zz-req-a@example.test') returning id into v_client_a;
  insert into public.clients (name, stage, status, assigned_staff_id, phone, email)
  values ('ZZ Req B', 'Job Coaching', 'Active', v_admin, '(801) 555-0122', 'zz-req-b@example.test') returning id into v_client_b;
  insert into public.portal_accounts (client_id, kind, name, phone, email)
  values (v_client_a, 'Client', 'ZZ Req A', '+18015550121', 'zz-req-a@example.test') returning id into v_acct_a;
  insert into public.portal_accounts (client_id, kind, name, phone, email)
  values (v_client_b, 'Client', 'ZZ Req B', '+18015550122', 'zz-req-b@example.test') returning id into v_acct_b;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_user_a, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'p-' || v_acct_a || '@portal.zionvocrehab.com', '{}', '{}', now(), now()),
         (v_user_b, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'p-' || v_acct_b || '@portal.zionvocrehab.com', '{}', '{}', now(), now());
  insert into public.portal_sessions (id, account_id, auth_user_id) values (v_sess_a, v_acct_a, v_user_a), (v_sess_b, v_acct_b, v_user_b);

  -- ── who may ask ────────────────────────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_js_uid, 'role', 'authenticated')::text, true);
  begin
    perform public.portal_request_document(v_client_a, 'Resume');
    failures := failures || 'FAILED: staff who do not manage the client asked for a document'::text;
  exception when insufficient_privilege then null;
  end;

  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);
  begin
    perform public.portal_request_document(v_client_a, 'Other', '  ');
    failures := failures || 'FAILED: an Other request with no name was taken'::text;
  exception when check_violation then null;
  end;
  select r.request_id, r.conversation_ids into v_req, v_convs from public.portal_request_document(v_client_a, 'Resume', '', 'Your most recent one', null) r;
  if array_length(v_convs, 1) <> 1 then failures := failures || 'FAILED: the request was not posted to the client''s thread'::text; end if;
  select r.request_id into v_req2 from public.portal_request_document(v_client_a, 'Photo ID') r;

  -- ── who sees ───────────────────────────────────────────────
  perform set_config('request.jwt.claims', json_build_object('sub', v_user_a, 'role', 'authenticated', 'session_id', v_sess_a)::text, true);
  if exists (select 1 from public.portal_my_requests()) then failures := failures || 'FAILED: requests showed before consent'::text; end if;
  perform public.portal_record_consent('Electronic communication', true, '203.0.113.1', 'zz-agent');
  if (select count(*) from public.portal_my_requests()) <> 2 or public.portal_open_requests() <> 2 then
    failures := failures || 'FAILED: the client does not see their two open requests'::text;
  end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_user_b, 'role', 'authenticated', 'session_id', v_sess_b)::text, true);
  perform public.portal_record_consent('Electronic communication', true, '203.0.113.2', 'zz-agent');
  if exists (select 1 from public.portal_my_requests()) then failures := failures || 'FAILED: one client saw another client''s requests'::text; end if;
  begin
    perform public.portal_upload_path(v_req, 'resume.pdf');
    failures := failures || 'FAILED: a client got an upload place for another client''s request'::text;
  exception when check_violation then null;
  end;
  if exists (select 1 from public.portal_requests) or exists (select 1 from public.attachments) then
    failures := failures || 'FAILED: a portal client read requests or documents directly'::text;
  end if;

  -- ── answering ──────────────────────────────────────────────
  perform set_config('request.jwt.claims', json_build_object('sub', v_user_a, 'role', 'authenticated', 'session_id', v_sess_a)::text, true);
  v_path := public.portal_upload_path(v_req, 'My Résumé (2026).pdf');
  if v_path not like 'portal/' || v_client_a || '/' || v_req || '/%-My-R-sum-2026-.pdf' then
    failures := failures || ('FAILED: the upload place was not where expected: ' || v_path)::text;
  end if;
  begin
    perform public.portal_answer_request(v_req, v_path, 'resume.pdf', 'application/pdf', 1000, 'zzhash');
    failures := failures || 'FAILED: a request was answered with no file in storage'::text;
  exception when check_violation then null;
  end;
  begin
    perform public.portal_answer_request(v_req, 'clients/' || v_client_a || '/x.pdf', 'resume.pdf', 'application/pdf', 1000, 'zzhash');
    failures := failures || 'FAILED: a request was answered with a path it did not hand out'::text;
  exception when check_violation then null;
  end;

  perform set_config('role', 'postgres', true);
  insert into storage.objects (bucket_id, name, metadata) values ('client-files', v_path, '{"size":1000}');
  perform set_config('role', 'authenticated', true);
  v_att := public.portal_answer_request(v_req, v_path, 'My Résumé (2026).pdf', 'application/pdf', 1000, 'zzhash-' || v_req);
  begin
    perform public.portal_upload_path(v_req, 'again.pdf');
    failures := failures || 'FAILED: an answered request took a second upload'::text;
  exception when check_violation then null;
  end;

  perform set_config('role', 'postgres', true);
  if (select category from public.attachments where id = v_att) <> 'Resume'
     or (select review_status from public.attachments where id = v_att) <> 'Waiting'
     or (select source from public.attachments where id = v_att) <> 'Portal' then
    failures := failures || 'FAILED: the upload was not filed as a Resume waiting for review'::text;
  end if;
  if not exists (select 1 from public.tasks where source_kind = 'portal_upload' and source_ref = v_req and status = 'Open' and assigned_staff_id = v_admin) then
    failures := failures || 'FAILED: no review task for the assigned staff member'::text;
  end if;

  -- ── review ─────────────────────────────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);
  begin
    perform public.portal_review_request(v_req, false, '');
    failures := failures || 'FAILED: an upload was sent back with no reason'::text;
  exception when check_violation then null;
  end;
  v_convs := public.portal_review_request(v_req, false, 'It is cut off at the bottom');
  perform set_config('role', 'postgres', true);
  if (select status from public.portal_requests where id = v_req) <> 'Returned'
     or exists (select 1 from public.tasks where source_ref = v_req and status = 'Open') then
    failures := failures || 'FAILED: sending back did not reopen the request and close the task'::text;
  end if;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_user_a, 'role', 'authenticated', 'session_id', v_sess_a)::text, true);
  if (select return_reason from public.portal_my_requests() where id = v_req) <> 'It is cut off at the bottom' then
    failures := failures || 'FAILED: the client cannot read why it was sent back'::text;
  end if;
  v_path := public.portal_upload_path(v_req, 'resume2.pdf');
  perform set_config('role', 'postgres', true);
  insert into storage.objects (bucket_id, name, metadata) values ('client-files', v_path, '{"size":1200}');
  perform set_config('role', 'authenticated', true);
  v_att := public.portal_answer_request(v_req, v_path, 'resume2.pdf', 'application/pdf', 1200, 'zzhash2-' || v_req);
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);
  perform public.portal_review_request(v_req, true);
  perform set_config('role', 'postgres', true);
  if (select status from public.portal_requests where id = v_req) <> 'Accepted'
     or (select review_status from public.attachments where id = v_att) <> 'Accepted' then
    failures := failures || 'FAILED: accepting did not mark the request and the document accepted'::text;
  end if;

  -- ── withdrawing ────────────────────────────────────────────
  perform set_config('role', 'authenticated', true);
  perform public.portal_cancel_request(v_req2);
  perform set_config('request.jwt.claims', json_build_object('sub', v_user_a, 'role', 'authenticated', 'session_id', v_sess_a)::text, true);
  if public.portal_open_requests() <> 0 then failures := failures || 'FAILED: a withdrawn request still shows as open'::text; end if;
  perform set_config('role', 'postgres', true);

  if has_function_privilege('authenticated', 'public.portal_post_system_line(uuid, text)', 'execute')
     or has_function_privilege('anon', 'public.portal_answer_request(uuid, text, text, text, bigint, text)', 'execute') then
    failures := failures || 'FAILED: a request function can be called by somebody it is not for'::text;
  end if;

  if array_length(failures, 1) > 0 then
    raise exception E'\n%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- PORTAL REQUESTS VERIFIED ---';
end;
$$;

rollback;
