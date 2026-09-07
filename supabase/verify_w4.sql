-- Zion Vocational Rehab CRM — W-4 and employer details verification
--
-- A W-4 differs from the other two forms in who owns it. The top is the
-- employee's and the bottom is the employer's, and the employer half is filled
-- from settings the employee is not allowed to read. So the rules worth
-- proving are about the boundary: the employee signs and freezes their half,
-- the employer's EIN stays out of reach of everyone but Admin, and a signed
-- W-4 does not quietly reclassify anyone as a contractor.
--
-- Runs inside a transaction that is rolled back. Nothing here is left behind.

begin;

do $$
declare
  v_admin    uuid;
  v_adm_uid  uuid;
  v_rei      uuid;
  v_rei_uid  uuid;
  v_form     uuid;
  v_status   text;
  v_last4    text;
  v_ein      text;
  v_name     text;
  v_before   text;
  failures   text[] := '{}';
begin
  -- Read before any role switch: once the session is authenticated, RLS would
  -- return nothing and a null claim reads as "not Admin" rather than as an error.
  select id, user_id into v_admin, v_adm_uid from public.staff where legacy_id = 's1';
  select id, user_id into v_rei, v_rei_uid   from public.staff where legacy_id = 's2';

  select tax_status into v_before from public.contractor_profiles where staff_id = v_rei;

  -- ── the employer block is Admin's alone ────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_rei_uid, 'role', 'authenticated')::text, true);
  begin
    perform public.set_employer_details('ZZ Not Allowed', 'nowhere', '111111111');
    failures := failures || 'FAILED: a contractor set the employer details';
  exception when insufficient_privilege then
    raise notice 'ok  only Admin can set the employer details';
  end;
  begin
    perform public.get_employer_details();
    failures := failures || 'FAILED: a contractor read the employer details';
  exception when insufficient_privilege then
    raise notice 'ok  only Admin can read the employer details';
  end;
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  -- ── as Admin ───────────────────────────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);

  begin
    perform public.set_employer_details('ZZ Test Practice', '1 Test Way', '12345');
    failures := failures || 'FAILED: a five-digit EIN was accepted';
  exception when check_violation then
    raise notice 'ok  a wrong-length EIN is refused before it reaches a form';
  end;

  perform public.set_employer_details('ZZ Test Practice', '1 Test Way', '98-7654321');
  select ein, legal_name into v_ein, v_name from public.get_employer_details();

  if v_ein <> '987654321' then
    failures := failures || format('FAILED: the EIN stored as "%s"', v_ein);
  else
    raise notice 'ok  Admin can set an EIN, punctuation and all';
  end if;

  -- Editing the address must not wipe the number the screen never shows back.
  perform public.set_employer_details('ZZ Test Practice', '2 Other Way', '');
  select ein into v_ein from public.get_employer_details();
  if v_ein <> '987654321' then
    failures := failures || 'FAILED: saving with a blank EIN wiped the stored one';
  else
    raise notice 'ok  a blank EIN leaves the stored one alone';
  end if;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  -- ── the employee signs their own half ──────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_rei_uid, 'role', 'authenticated')::text, true);

  insert into public.tax_form_submissions (staff_id, form_type, status, data)
  values (v_rei, 'W-4', 'Draft',
          '{"firstName":"ZZ","lastName":"Verify","filingStatus":"Head of household","exempt":false}'::jsonb)
  returning id into v_form;

  perform public.sign_tax_form(v_form, '{"ssn":"123456789"}'::jsonb, '6789',
                               'ZZ Verify', '198.51.100.7');

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  select status, tin_last4 into v_status, v_last4
    from public.tax_form_submissions where id = v_form;

  if v_status <> 'Signed' then
    failures := failures || format('FAILED: the W-4 is "%s", not Signed', v_status);
  else
    raise notice 'ok  an employee can sign their own W-4';
  end if;

  if v_last4 <> '6789' then
    failures := failures || format('FAILED: tin_last4 is "%s", expected 6789', v_last4);
  else
    raise notice 'ok  only the last four digits of the SSN are in the clear';
  end if;

  if exists (
    select 1 from public.tax_form_submissions
     where id = v_form and encode(sensitive_encrypted, 'escape') like '%123456789%'
  ) then
    failures := failures || 'FAILED: the SSN is readable in the stored payload';
  else
    raise notice 'ok  the SSN is held as ciphertext';
  end if;

  -- ── a W-4 says nothing about contractor status ─────────────
  -- The profile trigger handles W-8BEN and W-9. An employee is neither, and a
  -- W-4 that flipped someone to "US person" on a contractor profile would put
  -- them into the 1099 run they have no business being in.
  if coalesce((select tax_status from public.contractor_profiles where staff_id = v_rei), '')
     is distinct from coalesce(v_before, '') then
    failures := failures || 'FAILED: signing a W-4 changed the contractor tax status';
  else
    raise notice 'ok  signing a W-4 leaves contractor tax status untouched';
  end if;

  if exists (select 1 from public.form_1099_candidates(extract(year from current_date)::int)
              where staff_id = v_rei) then
    failures := failures || 'FAILED: signing a W-4 put the person into the 1099 run';
  else
    raise notice 'ok  a W-4 does not put anyone into a 1099 run';
  end if;

  -- ── frozen once signed ─────────────────────────────────────
  begin
    update public.tax_form_submissions
       set data = '{"firstName":"someone else"}'::jsonb
     where id = v_form;
    failures := failures || 'FAILED: a signed W-4 was edited';
  exception when check_violation then
    raise notice 'ok  a signed W-4 cannot be edited';
  end;

  -- ── the payload is Admin's to read, nobody else's ──────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_rei_uid, 'role', 'authenticated')::text, true);
  begin
    perform public.get_tax_form_sensitive(v_form);
    failures := failures || 'FAILED: the signer read their own SSN back in the clear';
  exception when insufficient_privilege then
    raise notice 'ok  not even the person who signed can read the SSN back';
  end;
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  if failures = '{}' then
    raise notice '';
    raise notice '--- W-4 SIGNING VERIFIED ---';
  else
    raise notice '';
    raise notice '%  PROBLEM(S):', array_length(failures, 1);
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
