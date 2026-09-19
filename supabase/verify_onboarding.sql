-- Zion Vocational Rehab CRM — the staff onboarding walkthrough (0100)
--
-- What has to hold, each tried from the direction that would break it:
--
--   Each of the six steps is done when the thing itself is done, and the
--   checklist says the same as the walkthrough.
--   Personal details, payment, identity documents, certifications and the
--   signed policy are the person's and Admin's - no colleague reads them, and
--   nobody signed out reads anything. Admin opening someone's personal details
--   is logged.
--   An I-9 document reads "inspection required" until Admin records it, and
--   only Admin can. A card the person puts forward reads "Awaiting check"
--   until Admin verifies it, and only Admin can.
--   Where they are paid is a listed method and at most the last four digits;
--   eight digits in a row are refused anywhere on it. A policy signature records the hash
--   of the text signed, must be in the legal name, and is never changed.
--   Finishing tells Admin once; open steps are on the nightly list.
--
-- Uses made-up staff (ZZ). Runs inside a transaction that is rolled back.

begin;

do $$
declare
  v_admin     uuid;
  v_adm_uid   uuid;
  v_new       uuid;
  v_new_uid   uuid := gen_random_uuid();
  v_col       uuid;
  v_col_uid   uuid := gen_random_uuid();
  v_i9        uuid;
  v_card      uuid;
  v_col_file  uuid;
  v_pol_file  uuid;
  v_cred      uuid;
  v_n         bigint;
  v_b         boolean;
  v_ver       integer;
  failures    text[] := '{}';
begin
  select id, user_id into v_admin, v_adm_uid from public.staff
   where role = 'Admin' and active and user_id is not null order by created_at, id limit 1;
  select version into v_ver from public.staff_policies where key = 'data-handling' and is_current;

  insert into public.staff (name, email, role, active)
  values ('ZZ Onboard New', 'zz-onboard-new@example.test', 'Job Search', true) returning id into v_new;
  insert into public.staff (name, email, role, active)
  values ('ZZ Onboard Colleague', 'zz-onboard-col@example.test', 'Job Search', true) returning id into v_col;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_new_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-onboard-new@example.test', '{}', '{}', now(), now()),
         (v_col_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-onboard-col@example.test', '{}', '{}', now(), now());
  update public.staff set accepted_at = now() where id in (v_new, v_col);
  insert into public.staff_employment (staff_id, employment_type) values (v_new, 'Employee');
  insert into public.staff_onboarding (staff_id) values (v_new);

  -- The colleague has a document of their own, to try to borrow.
  insert into public.staff_files (staff_id, storage_path, filename, mime_type, size_bytes, category, uploaded_by)
  values (v_col, 'zz/col.pdf', 'col.pdf', 'application/pdf', 10, 'Certificate', v_col) returning id into v_col_file;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_new_uid, 'role', 'authenticated')::text, true);

  if cardinality((select array_agg(auto_key) from public.staff_checklist
                   where staff_id = v_new and auto_key in ('personal_details','identity_documents','certifications_submitted',
                                                           'tax_form_signed','policy_signed','payment_setup')
                     and auto_done is not true)) <> 6 then
    failures := failures || 'FAILED: a new starter did not open with all six steps to do'::text;
  end if;

  -- ── 1. personal details ────────────────────────────────────
  insert into public.staff_personal (staff_id, legal_name, address_line1, city, state, postal_code, phone, date_of_birth,
                                     emergency_name, emergency_relationship, emergency_phone)
  values (v_new, 'ZZ Onboard Newperson', '1 ZZ Street', 'Salt Lake City', 'UT', '84115', '801-555-0100', date '1990-01-01',
          'ZZ Contact', 'Sister', '801-555-0101');
  if not public.onboarding_step_done(v_new, 'personal_details') then
    failures := failures || 'FAILED: complete personal details did not finish the step'::text;
  end if;

  -- ── 2. identity documents ──────────────────────────────────
  insert into public.staff_files (staff_id, storage_path, filename, mime_type, size_bytes, category, uploaded_by)
  values (v_new, 'zz/i9.pdf', 'passport.pdf', 'application/pdf', 10, 'I-9', v_new) returning id into v_i9;
  if not public.onboarding_step_done(v_new, 'identity_documents')
     or not (select inspection_required from public.staff_documents where id = v_i9) then
    failures := failures || 'FAILED: an I-9 upload did not finish the step, or was not marked inspection required'::text;
  end if;
  begin
    perform public.record_identity_inspection(v_i9);
    failures := failures || 'FAILED: somebody recorded the in-person inspection of their own I-9'::text;
  exception when insufficient_privilege then null;
  end;
  if public.onboarding_step_done(v_new, 'identity_inspected') then
    failures := failures || 'FAILED: an uninspected I-9 counted as inspected'::text;
  else
    raise notice 'ok  details and identity documents finish their steps; an I-9 reads inspection required, and the person cannot clear it';
  end if;

  -- ── 3. certifications ──────────────────────────────────────
  insert into public.staff_files (staff_id, storage_path, filename, mime_type, size_bytes, category, uploaded_by)
  values (v_new, 'zz/cpr.pdf', 'cpr.pdf', 'application/pdf', 10, 'Certificate', v_new) returning id into v_card;
  begin
    perform public.submit_own_credential('cpr', '', null, null, v_card, '');
    failures := failures || 'FAILED: a CPR card was put forward with no expiry date'::text;
  exception when check_violation then null;
  end;
  begin
    perform public.submit_own_credential('cpr', '', null, public.practice_today() + 400, v_col_file, '');
    failures := failures || 'FAILED: somebody put forward a card backed by a colleague''s document'::text;
  exception when insufficient_privilege then null;
  end;
  v_cred := public.submit_own_credential('cpr', 'ZZ-1', public.practice_today() - 30, public.practice_today() + 400, v_card, '');
  if (select state from public.staff_credential_status where staff_id = v_new and type_key = 'cpr') <> 'Awaiting check' then
    failures := failures || 'FAILED: a card the person put forward did not read Awaiting check'::text;
  end if;
  begin
    perform public.verify_credential(v_cred);
    failures := failures || 'FAILED: somebody verified their own credential through the Admin action'::text;
  exception when insufficient_privilege then null;
  end;
  update public.staff_credentials set verified_at = now(), verified_by = v_new where id = v_cred;
  if (select verified_at from public.staff_credentials where id = v_cred) is not null then
    failures := failures || 'FAILED: somebody verified their own credential'::text;
  end if;
  perform public.confirm_onboarding_certifications();
  if not public.onboarding_step_done(v_new, 'certifications_submitted') then
    failures := failures || 'FAILED: confirming what they hold did not finish the certifications step'::text;
  else
    raise notice 'ok  a card put forward needs an expiry and its own scan, reads Awaiting check, and only Admin verifies it';
  end if;

  -- ── 6. where they are paid ─────────────────────────────────
  begin
    insert into public.staff_payment_setup (staff_id, method, method_other, payer_of_record)
    values (v_new, 'Other', 'bank 12345678', 'ZZ Payer');
    failures := failures || 'FAILED: eight digits in a row were stored'::text;
  exception when check_violation then null;
  end;
  begin
    insert into public.staff_payment_setup (staff_id, method, last_four, payer_of_record)
    values (v_new, 'Wise', '123456', 'ZZ Payer');
    failures := failures || 'FAILED: more than the last four digits were stored'::text;
  exception when check_violation then null;
  end;
  begin
    insert into public.staff_payment_setup (staff_id, method, payer_of_record)
    values (v_new, 'Venmo', 'ZZ Payer');
    failures := failures || 'FAILED: a method off the list was stored'::text;
  exception when check_violation then null;
  end;
  begin
    insert into public.staff_payment_setup (staff_id, method, method_other, payer_of_record)
    values (v_new, 'PayPal', 'ZZ words', 'ZZ Payer');
    failures := failures || 'FAILED: free text was stored against a listed method'::text;
  exception when check_violation then null;
  end;
  insert into public.staff_payment_setup (staff_id, method, last_four, payer_of_record, payroll_service)
  values (v_new, 'Direct deposit via payroll', '4321', 'ZZ Payer', 'ZZ Payroll');
  if not public.onboarding_step_done(v_new, 'payment_setup') then
    failures := failures || 'FAILED: saving where they are paid did not finish the step'::text;
  else
    raise notice 'ok  where they are paid is a listed method and at most four digits; eight in a row are refused anywhere';
  end if;

  -- ── 5. the policy ──────────────────────────────────────────
  insert into public.staff_files (staff_id, storage_path, filename, mime_type, size_bytes, category, uploaded_by)
  values (v_new, 'zz/policy.pdf', 'policy.pdf', 'application/pdf', 10, 'Signed policy', v_new) returning id into v_pol_file;
  begin
    perform public.sign_staff_policy('data-handling', v_ver, 'ZZ Somebody Else', '', v_pol_file, '');
    failures := failures || 'FAILED: the policy was signed in a name other than the legal name on file'::text;
  exception when check_violation then null;
  end;
  begin
    perform public.sign_staff_policy('data-handling', v_ver, 'ZZ Onboard Newperson', '', v_col_file, '');
    failures := failures || 'FAILED: the signed copy was put on a colleague''s file'::text;
  exception when insufficient_privilege then null;
  end;
  perform public.sign_staff_policy('data-handling', v_ver, 'zz onboard newperson', '203.0.113.9', v_pol_file, 'abc');
  if not public.onboarding_step_done(v_new, 'policy_signed')
     or (select text_sha256 from public.staff_policy_signatures where staff_id = v_new)
        <> (select text_sha256 from public.staff_policies where key = 'data-handling' and is_current) then
    failures := failures || 'FAILED: signing did not finish the step, or did not record the hash of the text signed'::text;
  end if;
  begin
    update public.staff_policy_signatures set signer_name = 'ZZ rewritten' where staff_id = v_new;
    failures := failures || 'FAILED: a policy signature was changed'::text;
  exception when insufficient_privilege then
    raise notice 'ok  the policy is signed in the legal name, with the hash of the text, onto their own file, and never changed';
  end;

  -- Not yet: the tax form is still open.
  if public.refresh_onboarding(v_new) then
    failures := failures || 'FAILED: onboarding finished with the tax form still to sign'::text;
  end if;

  -- ── what a colleague sees ──────────────────────────────────
  perform set_config('request.jwt.claims', json_build_object('sub', v_col_uid, 'role', 'authenticated')::text, true);
  select (select count(*) from public.staff_personal where staff_id = v_new)
       + (select count(*) from public.staff_payment_setup where staff_id = v_new)
       + (select count(*) from public.staff_policy_signatures where staff_id = v_new)
       + (select count(*) from public.staff_onboarding where staff_id = v_new)
       + (select count(*) from public.staff_documents where staff_id = v_new)
       + (select count(*) from public.staff_checklist where staff_id = v_new)
    into v_n;
  if v_n <> 0 or public.onboarding_step_done(v_new, 'personal_details') is not null then
    failures := failures || format('FAILED: a colleague saw %s of somebody''s onboarding records', v_n)::text;
  end if;
  begin
    perform public.refresh_onboarding(v_new);
    failures := failures || 'FAILED: a colleague ran somebody else''s onboarding'::text;
  exception when insufficient_privilege then null;
  end;
  update public.staff_personal set phone = 'ZZ' where staff_id = v_new;
  begin
    perform public.onboarding_open_steps(v_new);
    failures := failures || 'FAILED: a signed-in user could list somebody''s open steps directly'::text;
  exception when insufficient_privilege then null;
  end;

  -- ── Admin ──────────────────────────────────────────────────
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);
  if (select phone from public.staff_personal where staff_id = v_new) = 'ZZ' then
    failures := failures || 'FAILED: a colleague changed somebody''s personal details'::text;
  else
    raise notice 'ok  a colleague sees and changes none of it, and cannot ask after it';
  end if;

  select count(*) into v_n from public.access_log where about_staff = v_new and subject = 'Staff personal details';
  perform public.note_staff_personal_access(v_new);
  if (select count(*) from public.access_log where about_staff = v_new and subject = 'Staff personal details') <> v_n + 1 then
    failures := failures || 'FAILED: Admin opening somebody''s personal details was not logged'::text;
  end if;

  perform public.record_identity_inspection(v_i9);
  perform public.verify_credential(v_cred);
  if not public.onboarding_step_done(v_new, 'identity_inspected')
     or (select state from public.staff_credential_status where staff_id = v_new and type_key = 'cpr') <> 'Valid' then
    failures := failures || 'FAILED: Admin recording the inspection or verifying the card did not take'::text;
  else
    raise notice 'ok  Admin records the inspection and verifies the card, and opening personal details is logged';
  end if;

  -- ── the tax form, then finished ────────────────────────────
  perform set_config('role', 'postgres', true);
  insert into public.tax_form_submissions (staff_id, form_type, status, data, signed_at, signer_name)
  values (v_new, 'W-4', 'Signed', '{}'::jsonb, now(), 'ZZ Onboard Newperson');

  perform public.generate_notifications_on(public.practice_today());
  if exists (select 1 from public.notifications where dedupe_key = 'onboarding_open:' || v_new and resolved_at is null) then
    failures := failures || 'FAILED: somebody with every step done was still on the nightly list'::text;
  end if;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_new_uid, 'role', 'authenticated')::text, true);
  v_b := public.refresh_onboarding(v_new);
  if not v_b or public.refresh_onboarding(v_new) then
    failures := failures || 'FAILED: finishing did not report once, and only once'::text;
  end if;
  perform set_config('role', 'postgres', true);
  if not exists (select 1 from public.notifications
                  where dedupe_key = 'onboarding_done:' || v_new and resolved_at is null and 'Admin' = any(roles)) then
    failures := failures || 'FAILED: Admin was not told onboarding finished'::text;
  end if;
  perform public.generate_notifications_on(public.practice_today());
  if not exists (select 1 from public.notifications where dedupe_key = 'onboarding_done:' || v_new and resolved_at is null) then
    failures := failures || 'FAILED: the nightly run cleared the notice that onboarding finished'::text;
  else
    raise notice 'ok  the six done, Admin is told once, and the notice outlasts the nightly run';
  end if;

  -- Open steps are on the nightly list.
  delete from public.staff_payment_setup where staff_id = v_new;
  update public.staff_onboarding set completed_at = null where staff_id = v_new;
  perform public.generate_notifications_on(public.practice_today());
  if not exists (select 1 from public.notifications
                  where dedupe_key = 'onboarding_open:' || v_new and resolved_at is null and staff_id = v_new) then
    failures := failures || 'FAILED: an open step was not on the nightly list, addressed to the person'::text;
  else
    raise notice 'ok  an open step is on the nightly list, addressed to the person and to Admin';
  end if;

  perform set_config('request.jwt.claims', '', true);
  if has_table_privilege('anon', 'public.staff_personal', 'select')
     or has_table_privilege('anon', 'public.staff_payment_setup', 'select')
     or has_table_privilege('anon', 'public.staff_policy_signatures', 'select')
     or has_table_privilege('anon', 'public.staff_onboarding', 'select')
     or has_function_privilege('anon', 'public.onboarding_step_done(uuid, text)', 'execute')
     or has_function_privilege('authenticated', 'public.onboarding_open_steps(uuid)', 'execute') then
    failures := failures || 'FAILED: somebody not signed in can reach onboarding records'::text;
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- ONBOARDING VERIFIED ---';
end $$;

rollback;
