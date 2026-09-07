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
    failures := failures || 'the TIN encryption key is not in Vault';
  else
    raise notice 'ok  the encryption key is held in Vault';
  end if;

  -- ── nobody unauthenticated can write one ───────────────────
  begin
    perform public.set_contractor_tin(v_rei, '123-45-6789', 'SSN');
    failures := failures || 'FAILED: a TIN was recorded with no signed-in Admin';
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
    failures := failures || 'FAILED: nothing was stored';
  elsif position('123456789' in encode(v_cipher, 'escape')) > 0 then
    failures := failures || 'FAILED: the TIN is readable inside the stored value';
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
    failures := failures || 'LEAK: a contractor read a TIN back out';
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

rollback;
