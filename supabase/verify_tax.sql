-- Zion Vocational Rehab CRM — contractor tax data verification
--
-- A TIN is a social security number in most cases. If this database were ever
-- copied, that is the field that would matter. So: it is never stored in a
-- readable column, the key lives in Vault rather than in the schema, and only
-- Admin can put one in or read one back.
--
-- Runs inside a transaction that is rolled back.

begin;

do $$
declare
  v_admin  uuid;
  v_rei    uuid;
  v_uid    uuid;
  v_tin    text;
  v_last4  text;
  v_cipher bytea;
  failures text[] := '{}';
begin
  select id into v_admin from public.staff where legacy_id = 's1';
  select id into v_rei   from public.staff where legacy_id = 's2';
  select user_id into v_uid from public.staff where legacy_id = 's1';

  -- ── the key is in Vault, not in the schema ─────────────────
  if not exists (select 1 from vault.secrets where name = 'zion_tin_key') then
    failures := failures || 'the TIN encryption key is not in Vault'::text;
  else
    raise notice 'ok  the encryption key is held in Vault';
  end if;

  -- ── nobody unauthenticated can write one ───────────────────
  begin
    perform public.set_contractor_tin(v_rei, '123-45-6789', 'SSN');
    failures := failures || 'FAILED: a TIN was recorded with no signed-in Admin'::text;
  exception when insufficient_privilege then
    raise notice 'ok  recording a TIN requires a signed-in Admin';
  end;

  -- ── as Admin ───────────────────────────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);

  insert into public.contractor_profiles (staff_id, legal_name)
  values (v_rei, 'ZZ Rei Test') on conflict (staff_id) do nothing;

  perform public.set_contractor_tin(v_rei, '123-45-6789', 'SSN');
  v_tin := public.get_contractor_tin(v_rei);

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  if v_tin <> '123456789' then
    failures := failures || format('FAILED: Admin read back "%s", expected 123456789', v_tin);
  else
    raise notice 'ok  Admin can record a TIN and read it back';
  end if;

  -- ── it is not sitting in the table in the clear ────────────
  select tin_encrypted, tin_last4 into v_cipher, v_last4
    from public.contractor_profiles where staff_id = v_rei;

  if v_cipher is null then
    failures := failures || 'FAILED: nothing was stored'::text;
  elsif position('123456789' in encode(v_cipher, 'escape')) > 0 then
    failures := failures || 'FAILED: the TIN is readable inside the stored value'::text;
  else
    raise notice 'ok  the stored value is ciphertext, not the number';
  end if;

  if v_last4 <> '6789' then
    failures := failures || format('last four should be 6789, got "%s"', v_last4);
  else
    raise notice 'ok  only the last four digits are stored in the clear';
  end if;

  -- ── a contractor cannot read anyone's, including their own ─
  select user_id into v_uid from public.staff where legacy_id = 's2';
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);

  begin
    v_tin := public.get_contractor_tin(v_rei);
    perform set_config('role', 'postgres', true);
    failures := failures || 'LEAK: a contractor read a TIN back out'::text;
  exception when insufficient_privilege then
    perform set_config('role', 'postgres', true);
    raise notice 'ok  a contractor cannot read a TIN, not even their own';
  end;
  perform set_config('request.jwt.claims', '', true);

  if array_length(failures, 1) is not null then
    raise exception E'TIN FAILURES:\n  %', array_to_string(failures, E'\n  ');
  end if;
  raise notice '--- TIN HANDLING VERIFIED ---';
end $$;

-- ─────────────────────────────────────────────────────────────
-- Payments, year totals, and who can see them
-- ─────────────────────────────────────────────────────────────
do $$
declare
  v_rei    uuid;
  v_marg   uuid;
  r        record;
  n_own    int;
  n_others int;
  v_total  numeric;
  failures text[] := '{}';
  yr       int := extract(year from current_date)::int;
begin
  select id into v_rei  from public.staff where legacy_id = 's2';
  select id into v_marg from public.staff where legacy_id = 's3';

  insert into public.contractor_payments (staff_id, paid_on, amount, method, reference)
  values (v_rei,  make_date(yr, 3, 15), 1200.00, 'ACH',   'ZZ-1'),
         (v_rei,  make_date(yr, 4, 15),  850.50, 'Check', 'ZZ-2'),
         (v_marg, make_date(yr, 3, 15),  400.00, 'Check', 'ZZ-3');

  select total_paid into v_total from public.contractor_year_totals
   where staff_id = v_rei and year = yr;
  if v_total <> 2050.50 then
    failures := failures || format('year total is %s, expected 2050.50', v_total);
  else
    raise notice 'ok  calendar-year total is the sum of payments, not of hours';
  end if;

  for r in
    select s.id, s.name, s.role, u.id as uid
      from public.staff s join auth.users u on u.id = s.user_id
     where s.active order by s.legacy_id
  loop
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims',
                       json_build_object('sub', r.uid, 'role', 'authenticated')::text, true);

    select count(*) into n_own    from public.contractor_payments where staff_id = r.id;
    select count(*) into n_others from public.contractor_payments where staff_id <> r.id;

    perform set_config('role', 'postgres', true);
    perform set_config('request.jwt.claims', '', true);

    raise notice '  % (%): own payments=% others=%', r.name, r.role, n_own, n_others;

    if r.role <> 'Admin' and n_others <> 0 then
      failures := failures || format('LEAK: %s can see another contractor''s payments', r.name);
    end if;
  end loop;

  if array_length(failures, 1) is not null then
    raise exception E'PAYMENT FAILURES:\n  %', array_to_string(failures, E'\n  ');
  end if;
  raise notice '--- PAYMENTS VERIFIED ---';
end $$;

-- ─────────────────────────────────────────────────────────────
-- Foreign persons and the 1099
--
-- Payments to a foreign person for services performed outside the United
-- States are not US-source income and are not reported on a 1099-NEC. Putting
-- one on a run is a mistake the IRS finds rather than we do, so the database
-- refuses it rather than trusting whichever query builds the list.
-- ─────────────────────────────────────────────────────────────
do $$
declare
  v_rei    uuid;
  v_us     uuid;
  v_run    uuid;
  yr       int := extract(year from current_date)::int;
  n_cand   int;
  v_expiry date;
  failures text[] := '{}';
begin
  select id into v_rei from public.staff where legacy_id = 's2';

  -- A US-person contractor to prove the list is not simply empty.
  insert into public.staff (name, email, role, active)
  values ('ZZ US Contractor', 'zz-us@example.test', 'Job Search', true)
  returning id into v_us;

  insert into public.contractor_profiles
    (staff_id, tax_status, legal_name, address_line1, city, state, postal_code,
     tin_type, tin_last4, w9_received_on)
  values (v_us, 'US person', 'ZZ US Contractor', '1 Test St', 'Provo', 'UT', '84601',
          'SSN', '1234', current_date);

  update public.tax_years set federal_threshold = 600 where year = yr;

  insert into public.contractor_payments (staff_id, paid_on, amount)
  values (v_us,  make_date(yr, 5, 1), 900.00),
         (v_rei, make_date(yr, 5, 1), 5000.00);

  -- The candidate list includes the US person and not the foreign one.
  select count(*) into n_cand from public.form_1099_candidates(yr) where staff_id = v_us;
  if n_cand <> 1 then
    failures := failures || 'the US contractor is missing from the 1099 candidates'::text;
  else
    raise notice 'ok  a US contractor over the threshold is on the list';
  end if;

  select count(*) into n_cand from public.form_1099_candidates(yr) where staff_id = v_rei;
  if n_cand <> 0 then
    failures := failures || 'LEAK: a foreign person appears in the 1099 candidates'::text;
  else
    raise notice 'ok  a foreign person paid $5,000 is not on the list';
  end if;

  -- And cannot be forced onto a run by hand.
  insert into public.form_1099_runs (year, threshold, state_copy)
  values (yr, 600, false) returning id into v_run;

  begin
    insert into public.form_1099_recipients
      (run_id, staff_id, legal_name, nonemployee_comp)
    values (v_run, v_rei, 'Rei Ruzzel', 5000.00);
    failures := failures || 'FAILED: a foreign person was added to a 1099 run'::text;
  exception when check_violation then
    raise notice 'ok  a foreign person cannot be added to a run by hand';
  end;

  insert into public.form_1099_recipients (run_id, staff_id, legal_name, nonemployee_comp)
  values (v_run, v_us, 'ZZ US Contractor', 900.00);
  raise notice 'ok  a US contractor can be';

  -- W-8BEN validity: through the last day of the third succeeding year.
  update public.contractor_profiles set w8ben_received_on = date '2026-03-15'
   where staff_id = v_rei;
  select w8ben_expires_on into v_expiry from public.contractor_profiles where staff_id = v_rei;
  if v_expiry <> date '2029-12-31' then
    failures := failures || format('W-8BEN signed 2026-03-15 should run to 2029-12-31, got %s', v_expiry);
  else
    raise notice 'ok  a W-8BEN signed 2026-03-15 runs to 2029-12-31, not 2029-03-15';
  end if;

  -- A US person must not carry W-8BEN dates, and vice versa.
  begin
    update public.contractor_profiles set w8ben_received_on = current_date where staff_id = v_us;
    failures := failures || 'FAILED: a US person was given a W-8BEN date'::text;
  exception when check_violation then
    raise notice 'ok  a US person cannot carry a W-8BEN date';
  end;

  if array_length(failures, 1) is not null then
    raise exception E'FOREIGN CONTRACTOR FAILURES:\n  %', array_to_string(failures, E'\n  ');
  end if;
  raise notice '--- FOREIGN CONTRACTOR HANDLING VERIFIED ---';
end $$;

-- ─────────────────────────────────────────────────────────────
-- The paperwork bucket is Admin-only at the object level
-- ─────────────────────────────────────────────────────────────
do $$
declare
  v_rei    uuid;
  r        record;
  n_bytes  int;
  n_meta   int;
  failures text[] := '{}';
begin
  select id into v_rei from public.staff where legacy_id = 's2';

  insert into public.staff_files (staff_id, storage_path, filename, category, uploaded_by)
  values (v_rei, 'staff/' || v_rei || '/zz-w8ben.pdf', 'zz-w8ben.pdf', 'W-8BEN', v_rei);
  insert into storage.objects (bucket_id, name)
  values ('staff-files', 'staff/' || v_rei || '/zz-w8ben.pdf');

  for r in
    select s.id, s.name, s.role, u.id as uid
      from public.staff s join auth.users u on u.id = s.user_id
     where s.active order by s.legacy_id
  loop
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims',
                       json_build_object('sub', r.uid, 'role', 'authenticated')::text, true);

    select count(*) into n_bytes from storage.objects
     where bucket_id = 'staff-files' and name like '%zz-w8ben.pdf';
    select count(*) into n_meta from public.staff_files where filename = 'zz-w8ben.pdf';

    perform set_config('role', 'postgres', true);
    perform set_config('request.jwt.claims', '', true);

    raise notice '  % (%): file bytes=% metadata row=%', r.name, r.role, n_bytes, n_meta;

    if r.role = 'Admin' then
      if n_bytes <> 1 then failures := failures || 'Admin cannot open staff paperwork'::text; end if;
    else
      if n_bytes <> 0 then
        failures := failures || format('LEAK: %s can fetch staff paperwork bytes', r.name);
      end if;
    end if;
  end loop;

  if array_length(failures, 1) is not null then
    raise exception E'STAFF FILE FAILURES:\n  %', array_to_string(failures, E'\n  ');
  end if;
  raise notice '--- STAFF PAPERWORK IS ADMIN-ONLY ---';
end $$;

rollback;
