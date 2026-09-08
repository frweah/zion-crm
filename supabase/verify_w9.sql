-- Zion Vocational Rehab CRM — signed W-9 verification
--
-- Signing a W-9 in the app has to do three things that were previously done by
-- hand: certify and freeze the document, encrypt the taxpayer number rather
-- than store it readable, and put that number on the contractor's profile so
-- the 1099 run can find it without anyone keying it a second time.
--
-- The last one is the point of migration 0021. set_contractor_tin() is
-- Admin-only by design, and the person signing their own W-9 is not Admin, so
-- without the trigger a contractor could sign a complete W-9 and still show as
-- having no TIN on file.
--
-- Runs inside a transaction that is rolled back. Nothing here is left behind.

begin;

do $$
declare
  v_admin   uuid;
  v_adm_uid uuid;
  v_rei     uuid;
  v_rei_uid uuid;
  v_form    uuid;
  v_second  uuid;
  v_status  text;
  v_last4   text;
  v_type    text;
  v_cipher  bytea;
  v_tin     text;
  v_when    date;
  failures  text[] := '{}';
begin
  -- Both ids are read here, before any role switch: once the session is
  -- authenticated, RLS on staff would return nothing and the claim would be
  -- null, which reads as "not Admin" rather than as an error.
  select id, user_id into v_admin, v_adm_uid from public.staff where legacy_id = 's1';
  select id, user_id into v_rei, v_rei_uid from public.staff where legacy_id = 's2';

  -- ── sign a W-9 as the contractor, not as Admin ─────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_rei_uid, 'role', 'authenticated')::text, true);

  insert into public.tax_form_submissions (staff_id, form_type, status, data)
  values (v_rei, 'W-9', 'Draft',
          '{"name":"ZZ Verify Person","classification":"Individual/sole proprietor"}'::jsonb)
  returning id into v_form;

  perform public.sign_tax_form(v_form, '{"ssn":"123456789"}'::jsonb, '6789',
                               'ZZ Verify Person', '198.51.100.7');

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  select status into v_status from public.tax_form_submissions where id = v_form;
  if v_status <> 'Signed' then
    failures := failures || format('FAILED: the form is "%s", not Signed', v_status);
  else
    raise notice 'ok  a contractor can sign their own W-9';
  end if;

  -- ── the number reached the profile, encrypted ──────────────
  select tin_type, tin_last4, tin_encrypted, w9_received_on
    into v_type, v_last4, v_cipher, v_when
    from public.contractor_profiles where staff_id = v_rei;

  if v_cipher is null then
    failures := failures || 'FAILED: signing a W-9 left the profile with no TIN'::text;
  elsif encode(v_cipher, 'escape') like '%123456789%' then
    failures := failures || 'FAILED: the TIN is readable in the profile column'::text;
  else
    raise notice 'ok  the TIN reached the profile as ciphertext';
  end if;

  if v_type <> 'SSN' then
    failures := failures || format('FAILED: tin_type is "%s", expected SSN', v_type);
  else
    raise notice 'ok  the profile records which kind of number it is';
  end if;

  if v_last4 <> '6789' then
    failures := failures || format('FAILED: tin_last4 is "%s", expected 6789', v_last4);
  else
    raise notice 'ok  only the last four digits are in the clear';
  end if;

  if v_when is null then
    failures := failures || 'FAILED: w9_received_on was not set by signing'::text;
  else
    raise notice 'ok  the profile shows the W-9 as received';
  end if;

  if (select tax_status from public.contractor_profiles where staff_id = v_rei)
     <> 'US person' then
    failures := failures || 'FAILED: signing a W-9 did not set the tax status to US person'::text;
  else
    raise notice 'ok  signing a W-9 sets the tax status to US person';
  end if;

  if (select w8ben_received_on from public.contractor_profiles where staff_id = v_rei)
     is not null then
    failures := failures || 'FAILED: a stale W-8BEN date survived the W-9'::text;
  else
    raise notice 'ok  the W-8BEN date is cleared, so no form claims to be current twice';
  end if;

  -- ── Admin can read it back through the audited function ────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);
  v_tin := public.get_contractor_tin(v_rei);
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  if v_tin <> '123456789' then
    failures := failures || format('FAILED: Admin read back "%s", expected 123456789', v_tin);
  else
    raise notice 'ok  Admin can read the number back through get_contractor_tin';
  end if;

  -- ── a signed form is frozen ────────────────────────────────
  begin
    update public.tax_form_submissions
       set data = '{"name":"someone else"}'::jsonb
     where id = v_form;
    failures := failures || 'FAILED: a signed W-9 was edited'::text;
  exception when check_violation then
    raise notice 'ok  a signed W-9 cannot be edited';
  end;

  -- ── a new one supersedes the old ───────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_rei_uid, 'role', 'authenticated')::text, true);

  insert into public.tax_form_submissions (staff_id, form_type, status, data)
  values (v_rei, 'W-9', 'Draft', '{"name":"ZZ Verify Person"}'::jsonb)
  returning id into v_second;

  perform public.sign_tax_form(v_second, '{"ein":"987654321"}'::jsonb, '4321',
                               'ZZ Verify Person', '198.51.100.7');

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  select status into v_status from public.tax_form_submissions where id = v_form;
  if v_status <> 'Superseded' then
    failures := failures || format('FAILED: the earlier W-9 is "%s", not Superseded', v_status);
  else
    raise notice 'ok  signing a new W-9 supersedes the earlier one';
  end if;

  select tin_type, tin_last4 into v_type, v_last4
    from public.contractor_profiles where staff_id = v_rei;
  if v_type <> 'EIN' or v_last4 <> '4321' then
    failures := failures || format('FAILED: the profile still shows %s ending %s', v_type, v_last4);
  else
    raise notice 'ok  the profile follows the current form, not the superseded one';
  end if;

  -- ── the payload stays out of reach of everyone else ────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_rei_uid, 'role', 'authenticated')::text, true);
  begin
    perform public.get_contractor_tin(v_rei);
    failures := failures || 'FAILED: a contractor read their own TIN back in the clear'::text;
  exception when insufficient_privilege then
    raise notice 'ok  not even the person who signed can read the number back';
  end;
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  if failures = '{}' then
    raise notice '';
    raise notice '--- W-9 SIGNING VERIFIED ---';
  else
    raise notice '';
    raise notice '%  PROBLEM(S):', array_length(failures, 1);
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
