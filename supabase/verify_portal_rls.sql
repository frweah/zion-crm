-- Zion Vocational Rehab CRM — a portal client sees only their own record
--
-- What has to hold, each tried from the direction that would break it:
--
--   A sign-in user exists only for a staff member or a live portal account
--   waiting for one; the staff rule is otherwise unchanged.
--
--   A sign-in code works once, for ten minutes, and five wrong tries lock it.
--   Nobody signed in can issue or check codes. What was typed is answered the
--   same way whether or not anybody has access at it.
--
--   Signed in to the portal, a client reads nothing from any staff table or
--   view - no other client, no staff rate, no note, no form, no file - and of
--   the portal's own tables only their own account, sessions, consents and
--   activity. Another client's portal rows stay invisible.
--
--   The moment the session is idle for 30 minutes, signed out, ended by staff,
--   or the account is disabled, even their own rows are gone; an ended session
--   is never started again.
--
--   Nothing past the consent screen opens until consent to electronic
--   communication is given on the current terms; withdrawing it closes it
--   again, and a new terms version asks again. Consent to texts lands where
--   texting looks, as method 'Portal'.
--
--   Only Admin, Intake & Client Reports and the assigned staff member give or
--   remove access; a guardian needs a guardianship document on that client's
--   file. Consent and activity cannot be edited, nor the text of a terms
--   version once stored.
--
--   No function that runs with elevated rights, and that a signed-in user may
--   call, is missing a check of who is calling.
--
-- Runs inside a transaction that is rolled back. Nothing here is left behind.

begin;

do $$
declare
  v_admin     uuid;
  v_adm_uid   uuid;
  v_js        uuid;
  v_js_uid    uuid;
  v_client_a  uuid;
  v_client_b  uuid;
  v_user_a    uuid := gen_random_uuid();
  v_user_b    uuid := gen_random_uuid();
  v_acct_a    uuid;
  v_acct_b    uuid;
  v_sess_a    uuid := gen_random_uuid();
  v_sess_b    uuid := gen_random_uuid();
  v_sess_new  uuid := gen_random_uuid();
  v_doc_a     uuid;
  v_doc_b     uuid;
  v_n         bigint;
  v_leaks     text[] := '{}';
  v_open      text;
  v_attempt   uuid;
  v_acct      uuid;
  v_code      text;
  v_result    text;
  v_email     text;
  v_me        record;
  r           record;
  failures    text[] := '{}';
begin
  select id, user_id into v_admin, v_adm_uid from public.staff
   where role = 'Admin' and active and user_id is not null order by created_at limit 1;
  select id, user_id into v_js, v_js_uid from public.staff
   where role = 'Job Search' and active and user_id is not null order by created_at limit 1;

  -- ── two clients, each with a portal account ────────────────
  insert into public.clients (name, stage, status, assigned_staff_id, phone, email)
  values ('ZZ Portal Client A', 'Job Coaching', 'Active', v_admin, '(801) 555-0101', 'zz-portal-a@example.test') returning id into v_client_a;
  insert into public.clients (name, stage, status, assigned_staff_id, phone, email)
  values ('ZZ Portal Client B', 'Job Coaching', 'Active', v_admin, '(801) 555-0102', 'zz-portal-b@example.test') returning id into v_client_b;

  insert into public.portal_accounts (client_id, kind, name, phone, email)
  values (v_client_a, 'Client', 'ZZ Portal Client A', '+18015550101', 'zz-portal-a@example.test') returning id into v_acct_a;
  insert into public.portal_accounts (client_id, kind, name, phone, email)
  values (v_client_b, 'Client', 'ZZ Portal Client B', '+18015550102', 'zz-portal-b@example.test') returning id into v_acct_b;

  -- ── sign-in users ──────────────────────────────────────────
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_user_a, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'p-' || v_acct_a || '@portal.zionvocrehab.com', '{}', '{}', now(), now()),
         (v_user_b, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'p-' || v_acct_b || '@portal.zionvocrehab.com', '{}', '{}', now(), now());
  if (select auth_user_id from public.portal_accounts where id = v_acct_a) is distinct from v_user_a then
    failures := failures || 'FAILED: a portal sign-in user was not linked to its account'::text;
  end if;

  begin
    insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'p-' || gen_random_uuid() || '@portal.zionvocrehab.com', '{}', '{}', now(), now());
    failures := failures || 'FAILED: a sign-in user was created for a portal account that does not exist'::text;
  exception when insufficient_privilege then null;
  end;
  begin
    insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'p-' || v_acct_a || '@portal.zionvocrehab.com', '{}', '{}', now(), now());
    failures := failures || 'FAILED: a second sign-in user was created for a portal account that has one'::text;
  exception when insufficient_privilege or unique_violation then null;
  end;
  begin
    insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'zz-nobody@example.test', '{}', '{}', now(), now());
    failures := failures || 'FAILED: a sign-in user was created with no staff row and no portal account'::text;
  exception when insufficient_privilege then
    raise notice 'ok  a sign-in user exists only for staff or a portal account waiting for one';
  end;

  -- ── sign-in codes ──────────────────────────────────────────
  perform set_config('role', 'service_role', true);
  select i.attempt_id, i.account_id, i.code into v_attempt, v_acct, v_code
    from public.portal_issue_code('(801) 555-0101', '203.0.113.9') i;
  if v_acct is distinct from v_acct_a or v_code !~ '^\d{6}$' then
    failures := failures || 'FAILED: a code was not issued for a live portal account''s phone'::text;
  end if;
  if exists (select 1 from public.portal_login_codes where id = v_attempt and (code_hash is null or position(v_code in code_hash) > 0)) then
    failures := failures || 'FAILED: a sign-in code is stored readable'::text;
  end if;
  if (select i.code from public.portal_issue_code('801-555-0101', '203.0.113.9') i) is not null then
    failures := failures || 'FAILED: a second code was sent within a minute'::text;
  end if;

  for i in 1..4 loop
    select c.result into v_result from public.portal_check_code(v_attempt, case when v_code = '000000' then '111111' else '000000' end, '203.0.113.9') c;
    if v_result <> 'wrong' then
      failures := failures || format('FAILED: wrong code %s answered %s', i, v_result)::text;
    end if;
  end loop;
  select c.result into v_result from public.portal_check_code(v_attempt, case when v_code = '000000' then '111111' else '000000' end, '203.0.113.9') c;
  if v_result <> 'locked' then
    failures := failures || 'FAILED: a fifth wrong code did not lock the code'::text;
  end if;
  select c.result into v_result from public.portal_check_code(v_attempt, v_code, '203.0.113.9') c;
  if v_result <> 'locked' then
    failures := failures || 'FAILED: the right code worked after five wrong ones'::text;
  else
    raise notice 'ok  five wrong codes lock a code, and the right one no longer works';
  end if;

  perform set_config('role', 'postgres', true);
  update public.portal_login_codes set created_at = created_at - interval '2 minutes' where account_id = v_acct_a;
  perform set_config('role', 'service_role', true);
  select i.attempt_id, i.code into v_attempt, v_code from public.portal_issue_code('ZZ-Portal-A@example.test', '203.0.113.9') i;
  select c.result, c.sign_in_email into v_result, v_email from public.portal_check_code(v_attempt, ' ' || v_code || ' ', '203.0.113.9') c;
  if v_result <> 'ok' or v_email <> 'p-' || v_acct_a || '@portal.zionvocrehab.com' then
    failures := failures || format('FAILED: the right code by email answered %s', v_result)::text;
  end if;
  select c.result into v_result from public.portal_check_code(v_attempt, v_code, '203.0.113.9') c;
  if v_result <> 'expired' then
    failures := failures || 'FAILED: a sign-in code worked twice'::text;
  else
    raise notice 'ok  a sign-in code works once';
  end if;

  perform set_config('role', 'postgres', true);
  update public.portal_login_codes set created_at = created_at - interval '2 minutes' where account_id = v_acct_a;
  perform set_config('role', 'service_role', true);
  select i.attempt_id, i.code into v_attempt, v_code from public.portal_issue_code('+1 801 555 0101', '203.0.113.9') i;
  perform set_config('role', 'postgres', true);
  update public.portal_login_codes set expires_at = now() - interval '1 second' where id = v_attempt;
  perform set_config('role', 'service_role', true);
  select c.result into v_result from public.portal_check_code(v_attempt, v_code, '203.0.113.9') c;
  if v_result <> 'expired' then
    failures := failures || 'FAILED: a code worked after ten minutes'::text;
  else
    raise notice 'ok  a sign-in code stops working after ten minutes';
  end if;

  select i.attempt_id, i.account_id, i.code into v_attempt, v_acct, v_code
    from public.portal_issue_code('(801) 555-0177', '203.0.113.9') i;
  select c.result into v_result from public.portal_check_code(v_attempt, '123456', '203.0.113.9') c;
  if v_attempt is null or v_acct is not null or v_code is not null or v_result <> 'wrong' then
    failures := failures || 'FAILED: a number with no portal access was answered differently'::text;
  else
    raise notice 'ok  a number with no portal access gets the same answer, and no code';
  end if;
  perform set_config('role', 'postgres', true);

  if has_function_privilege('authenticated', 'public.portal_issue_code(text, text)', 'execute')
     or has_function_privilege('authenticated', 'public.portal_check_code(uuid, text, text)', 'execute')
     or has_table_privilege('authenticated', 'public.portal_login_codes', 'select') then
    failures := failures || 'FAILED: somebody signed in can issue, check or read sign-in codes'::text;
  else
    raise notice 'ok  only the server issues and checks sign-in codes';
  end if;

  -- ── sessions and terms ─────────────────────────────────────
  insert into public.portal_sessions (id, account_id, auth_user_id) values (v_sess_a, v_acct_a, v_user_a), (v_sess_b, v_acct_b, v_user_b);

  update public.portal_terms set is_current = false where is_current;
  insert into public.portal_terms (version, title, source_file, body, text_sha256, published_at, is_current)
  values ('zz-verify-1', 'ZZ terms', 'zz.docx', '[{"type":"p","text":"ZZ"}]', repeat('a', 64), now(), true);

  insert into public.portal_consents (account_id, client_id, terms_version, kind, given, ip, acting_as, actor_name)
  values (v_acct_b, v_client_b, 'zz-verify-1', 'Electronic communication', true, '203.0.113.2', 'Client', 'ZZ Portal Client B');

  -- ── as client A ────────────────────────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user_a, 'role', 'authenticated', 'session_id', v_sess_a)::text, true);

  if public.portal_session_account_id() is distinct from v_acct_a then
    failures := failures || 'FAILED: a live portal session was not recognised as client A''s account'::text;
  end if;
  if public.is_active_staff() or public.current_staff_role() is not null then
    failures := failures || 'FAILED: a portal client is treated as staff'::text;
  end if;

  -- Every table and view outside the portal's own reads empty.
  for r in
    select c.relname
      from pg_class c
     where c.relnamespace = 'public'::regnamespace
       and c.relkind in ('r', 'v', 'm', 'p')
       and c.relname not in ('portal_accounts', 'portal_sessions', 'portal_terms', 'portal_consents', 'portal_activity')
     order by 1
  loop
    begin
      execute format('select count(*) from public.%I', r.relname) into v_n;
      if v_n > 0 then v_leaks := v_leaks || format('%s (%s)', r.relname, v_n); end if;
    exception when insufficient_privilege then
      null; -- refused outright is as good as empty
    end;
  end loop;
  if array_length(v_leaks, 1) > 0 then
    failures := failures || format('FAILED: a portal client can read rows from: %s', array_to_string(v_leaks, ', '))::text;
  else
    raise notice 'ok  a portal client reads nothing from any staff table or view - no client, rate, note, form or file';
  end if;

  select count(*) into v_n from storage.objects;
  if v_n > 0 then
    failures := failures || format('FAILED: a portal client can list %s stored files', v_n)::text;
  else
    raise notice 'ok  no stored file is visible to a portal client';
  end if;

  if (select count(*) from public.portal_accounts) <> 1
     or (select count(*) from public.portal_sessions) <> 1
     or exists (select 1 from public.portal_accounts where id = v_acct_b)
     or exists (select 1 from public.portal_consents where account_id = v_acct_b) then
    failures := failures || 'FAILED: a portal client sees another client''s portal account, session or consent'::text;
  else
    raise notice 'ok  a portal client sees their own account and session, and not another client''s';
  end if;
  if not exists (select 1 from public.portal_terms where version = 'zz-verify-1') then
    failures := failures || 'FAILED: a signed-in portal client cannot read the terms they are asked to agree to'::text;
  end if;

  begin
    perform public.portal_invite(v_client_a, 'Client');
    failures := failures || 'FAILED: a portal client gave portal access'::text;
  exception when insufficient_privilege then
    raise notice 'ok  a portal client cannot give or remove portal access';
  end;
  begin
    perform public.generate_notifications();
    failures := failures || 'FAILED: a portal client recalculated staff alerts'::text;
  exception when insufficient_privilege then null;
  end;
  begin
    select count(*) into v_n from public.read_client_private(v_client_a, 'verify') where allowed;
    if v_n > 0 then
      failures := failures || 'FAILED: a portal client read restricted details through read_client_private'::text;
    end if;
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.portal_consents (account_id, client_id, terms_version, kind, given, ip, acting_as, actor_name)
    values (v_acct_a, v_client_a, 'zz-verify-1', 'Electronic communication', true, '', 'Client', 'forged');
    failures := failures || 'FAILED: a portal client wrote a consent row directly'::text;
  exception when insufficient_privilege then null;
  end;

  -- ── the consent gate ───────────────────────────────────────
  select * into v_me from public.portal_me();
  if v_me.account_id is distinct from v_acct_a or v_me.staff_first_name is not null or v_me.electronic then
    failures := failures || 'FAILED: before consent, the portal showed more than the person''s own account'::text;
  end if;
  if public.portal_client_id() is not null then
    failures := failures || 'FAILED: portal features opened before consent to electronic communication'::text;
  end if;
  perform public.portal_record_consent('Electronic communication', true, '203.0.113.1', 'zz-agent');
  if public.portal_client_id() is distinct from v_client_a then
    failures := failures || 'FAILED: consent to electronic communication did not open the portal'::text;
  else
    raise notice 'ok  nothing past the consent screen opens until consent to electronic communication is given';
  end if;

  perform public.portal_record_consent('Electronic communication', false, '203.0.113.1', 'zz-agent');
  if public.portal_client_id() is not null then
    failures := failures || 'FAILED: withdrawing consent did not close the portal'::text;
  else
    raise notice 'ok  withdrawing consent closes the portal again';
  end if;

  perform public.portal_record_consent('Electronic communication', true, '203.0.113.1', 'zz-agent');
  perform set_config('role', 'postgres', true);
  update public.portal_terms set is_current = false where version = 'zz-verify-1';
  insert into public.portal_terms (version, title, source_file, body, text_sha256, published_at, is_current)
  values ('zz-verify-2', 'ZZ terms', 'zz2.docx', '[{"type":"p","text":"ZZ 2"}]', repeat('b', 64), now(), true);
  perform set_config('role', 'authenticated', true);
  if public.portal_client_id() is not null then
    failures := failures || 'FAILED: a new terms version did not ask for consent again'::text;
  else
    raise notice 'ok  a new terms version asks for consent again';
  end if;

  perform public.portal_record_consent('Electronic communication', true, '203.0.113.1', 'zz-agent');
  perform public.portal_record_consent('Text messages', true, '203.0.113.1', 'zz-agent');
  perform set_config('role', 'postgres', true);
  select state || '|' || method || '|' || phone into v_result from public.sms_consent_events
   where client_id = v_client_a order by at desc, seq desc limit 1;
  if v_result is distinct from 'Granted|Portal|+18015550101' then
    failures := failures || format('FAILED: consent to texts in the portal was not recorded for texting (%s)', coalesce(v_result, 'nothing'))::text;
  else
    raise notice 'ok  consent to texts given in the portal is what texting reads, for the number on the record';
  end if;
  if (select count(*) from public.portal_consents where account_id = v_acct_a and ip = '203.0.113.1' and acting_as = 'Client') <> 5 then
    failures := failures || 'FAILED: a consent choice was not recorded with its address and who gave it'::text;
  end if;
  perform set_config('role', 'authenticated', true);

  -- ── starting a session ─────────────────────────────────────
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user_a, 'role', 'authenticated', 'session_id', v_sess_new)::text, true);
  -- Two statements: a check in the same statement as the insert would read the
  -- sessions table as it was before the insert, and say no session started.
  v_acct := public.portal_begin_session('203.0.113.1', 'zz-agent');
  if v_acct is distinct from v_acct_a
     or public.portal_session_account_id() is distinct from v_acct_a then
    failures := failures || 'FAILED: a new portal session did not start'::text;
  end if;
  perform public.portal_end_my_session();
  perform public.portal_begin_session('203.0.113.1', 'zz-agent');
  if public.portal_session_account_id() is not null then
    failures := failures || 'FAILED: a signed-out session was started again'::text;
  else
    raise notice 'ok  signing out ends the session, and it cannot be started again';
  end if;
  perform set_config('request.jwt.claims',
    json_build_object('sub', gen_random_uuid(), 'role', 'authenticated', 'session_id', gen_random_uuid())::text, true);
  begin
    perform public.portal_begin_session('203.0.113.1', 'zz-agent');
    failures := failures || 'FAILED: a sign-in with no portal account started a portal session'::text;
  exception when insufficient_privilege then null;
  end;

  -- ── a session that is over shows nothing ───────────────────
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user_a, 'role', 'authenticated', 'session_id', v_sess_a)::text, true);
  perform set_config('role', 'postgres', true);
  update public.portal_sessions set last_seen_at = now() - interval '31 minutes' where id = v_sess_a;
  perform set_config('role', 'authenticated', true);
  if (select count(*) from public.portal_accounts) <> 0 or public.portal_session_account_id() is not null then
    failures := failures || 'FAILED: a session idle for 31 minutes still reads the client''s rows'::text;
  end if;
  if public.portal_touch_session() <> 'expired' then
    failures := failures || 'FAILED: an idle session was not ended when next used'::text;
  else
    raise notice 'ok  after 30 minutes idle the session ends and reads nothing';
  end if;

  perform set_config('role', 'postgres', true);
  update public.portal_sessions set last_seen_at = now(), ended_at = null, ended_reason = null where id = v_sess_a;
  update public.portal_accounts set disabled_at = now(), disabled_reason = 'ZZ' where id = v_acct_a;
  perform set_config('role', 'authenticated', true);
  if (select count(*) from public.portal_accounts) <> 0 then
    failures := failures || 'FAILED: a disabled account still reads its rows'::text;
  else
    raise notice 'ok  a disabled account reads nothing';
  end if;
  perform set_config('role', 'postgres', true);
  update public.portal_accounts set disabled_at = null, disabled_reason = '' where id = v_acct_a;

  -- ── staff give and remove access ───────────────────────────
  perform set_config('role', 'authenticated', true);
  if v_js is not null then
    perform set_config('request.jwt.claims', json_build_object('sub', v_js_uid, 'role', 'authenticated')::text, true);
    begin
      perform public.portal_invite(v_client_b, 'Guardian', 'ZZ Guardian', 'Mother', '(801) 555-0199', null, null);
      failures := failures || 'FAILED: a staff member not assigned to the client gave portal access'::text;
    exception when insufficient_privilege then
      raise notice 'ok  only Admin, Intake & Client Reports or the assigned staff member give portal access';
    end;
  end if;

  perform set_config('role', 'postgres', true);
  insert into public.attachments (client_id, storage_path, filename, mime_type, size_bytes, category)
  values (v_client_a, 'zz/verify/guardianship-a.pdf', 'guardianship-a.pdf', 'application/pdf', 10, 'Guardianship document') returning id into v_doc_a;
  insert into public.attachments (client_id, storage_path, filename, mime_type, size_bytes, category)
  values (v_client_b, 'zz/verify/guardianship-b.pdf', 'guardianship-b.pdf', 'application/pdf', 10, 'Guardianship document') returning id into v_doc_b;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);

  begin
    perform public.portal_invite(v_client_a, 'Guardian', 'ZZ Guardian', 'Mother', '(801) 555-0199', null, null);
    failures := failures || 'FAILED: a guardian was given access with no guardianship document'::text;
  exception when check_violation then null;
  end;
  begin
    perform public.portal_invite(v_client_a, 'Guardian', 'ZZ Guardian', 'Mother', '(801) 555-0199', null, v_doc_b);
    failures := failures || 'FAILED: a guardian was given access on another client''s guardianship document'::text;
  exception when check_violation then null;
  end;
  begin
    perform public.portal_invite(v_client_a, 'Guardian', 'ZZ Guardian', 'Mother', '(801) 555-0199', null, v_doc_a);
    raise notice 'ok  a guardian is given access only with a guardianship document on that client''s file';
  exception when others then
    failures := failures || format('FAILED: a guardian with a guardianship document could not be given access: %s', sqlerrm)::text;
  end;
  begin
    perform public.portal_invite(v_client_b, 'Guardian', 'ZZ Other', 'Aunt', '(801) 555-0101', null, v_doc_b);
    failures := failures || 'FAILED: two live portal accounts share a phone number'::text;
  exception when unique_violation then
    raise notice 'ok  one phone number opens one live portal account';
  end;

  select public.portal_sign_out_everywhere(v_client_a) into v_n;
  perform set_config('role', 'postgres', true);
  if exists (select 1 from public.portal_sessions where account_id = v_acct_a and ended_at is null) then
    failures := failures || 'FAILED: signing out everywhere left a portal session open'::text;
  else
    raise notice 'ok  signing a client out everywhere ends every session';
  end if;

  -- ── what is recorded stays as recorded ─────────────────────
  begin
    update public.portal_consents set given = false where account_id = v_acct_b;
    failures := failures || 'FAILED: a recorded consent was changed'::text;
  exception when insufficient_privilege then
    raise notice 'ok  consents and portal activity are append-only';
  end;
  begin
    update public.portal_terms set body = '[]' where version = 'zz-verify-2';
    failures := failures || 'FAILED: the text of a stored terms version was changed'::text;
  exception when insufficient_privilege then
    raise notice 'ok  the text of a terms version cannot change once stored';
  end;

  -- ── no elevated function lacks a caller check ──────────────
  select string_agg(p.proname, ', ' order by p.proname) into v_open
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.prokind = 'f'
     and p.prosecdef
     and has_function_privilege('authenticated', p.oid, 'execute')
     and pg_get_function_result(p.oid) not in ('trigger', 'event_trigger')
     and pg_get_functiondef(p.oid) !~ '(is_active_staff|current_staff_role|is_admin|current_staff_id|filing_caller_role|can_see_restricted|can_manage_portal|portal_session_account_id|auth\.uid\(\)|auth\.jwt\(\))';
  if v_open is not null then
    failures := failures || format('FAILED: elevated functions a signed-in user can call with no check of who is calling: %s', v_open)::text;
  else
    raise notice 'ok  every elevated function a signed-in user can call checks who is calling';
  end if;

  perform set_config('request.jwt.claims', '', true);

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- PORTAL RLS VERIFIED ---';
end $$;

rollback;
