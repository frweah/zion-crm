-- Zion Vocational Rehab CRM — contractor profiles, payments and tax years
--
-- These three screens are where the figures a 1099 reports come from, so the
-- rules worth proving are about who may write them and what the run refuses to
-- do with them. In particular: a 1099 run built on a threshold nobody has
-- confirmed would look finished while resting on a number somebody guessed,
-- and a foreign person must not appear on one however the profile is edited.
--
-- Runs inside a transaction that is rolled back. Nothing here is left behind.

begin;

do $$
declare
  v_admin    uuid;
  v_adm_uid  uuid;
  v_rei      uuid;
  v_rei_uid  uuid;
  v_marg     uuid;
  v_year     int := 2031;   -- far from any real data, so the run sees only this
  v_pay      uuid;
  v_count    int;
  v_total    numeric;
  v_status   text;
  failures   text[] := '{}';
begin
  select id, user_id into v_admin, v_adm_uid from public.staff where legacy_id = 's1';
  select id, user_id into v_rei,  v_rei_uid  from public.staff where legacy_id = 's2';
  select id             into v_marg          from public.staff where legacy_id = 's3';

  -- ── a contractor cannot write any of this ──────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_rei_uid, 'role', 'authenticated')::text, true);

  begin
    insert into public.contractor_payments (staff_id, paid_on, amount)
    values (v_rei, make_date(v_year, 3, 1), 100);
    failures := failures || 'FAILED: a contractor recorded a payment to themselves'::text;
  exception when insufficient_privilege then
    raise notice 'ok  a contractor cannot record a payment';
  end;

  begin
    insert into public.tax_years (year, federal_threshold) values (v_year, 1);
    failures := failures || 'FAILED: a contractor set a tax year threshold'::text;
  exception when insufficient_privilege then
    raise notice 'ok  a contractor cannot set a tax year threshold';
  end;

  begin
    update public.contractor_profiles set legal_name = 'ZZ Not Allowed' where staff_id = v_rei;
    get diagnostics v_count = row_count;
    if v_count > 0 then
      failures := failures || 'FAILED: a contractor edited their own 1099 details'::text;
    else
      raise notice 'ok  a contractor cannot edit their own 1099 details';
    end if;
  exception when insufficient_privilege then
    raise notice 'ok  a contractor cannot edit their own 1099 details';
  end;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  -- ── as Admin ───────────────────────────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);

  insert into public.contractor_profiles (staff_id, legal_name, address_line1, city, state,
                                          postal_code, tax_status, w9_received_on)
  values (v_rei, 'ZZ Verify Person', '1 Test Street', 'Salt Lake City', 'UT', '84115',
          'US person', make_date(v_year, 1, 2))
  on conflict (staff_id) do update set
    legal_name = excluded.legal_name, address_line1 = excluded.address_line1,
    city = excluded.city, state = excluded.state, postal_code = excluded.postal_code,
    tax_status = excluded.tax_status, w8ben_received_on = null,
    w9_received_on = excluded.w9_received_on;

  perform public.set_contractor_tin(v_rei, '123456789', 'SSN');

  -- Margaret stays foreign, and is paid more than Rei.
  insert into public.contractor_profiles (staff_id, legal_name, address_line1, city,
                                          tax_status, w8ben_received_on)
  values (v_marg, 'ZZ Foreign Person', '2 Test Street', 'Manila', 'Foreign person',
          make_date(v_year, 1, 2))
  on conflict (staff_id) do update set
    legal_name = excluded.legal_name, address_line1 = excluded.address_line1,
    city = excluded.city, tax_status = excluded.tax_status,
    w9_received_on = null, w8ben_received_on = excluded.w8ben_received_on;

  insert into public.contractor_payments (staff_id, paid_on, amount, method, created_by)
  values (v_rei,  make_date(v_year, 3, 1),  400.00, 'Check', v_admin),
         (v_rei,  make_date(v_year, 9, 15), 350.50, 'ACH',   v_admin),
         (v_marg, make_date(v_year, 4, 1), 5000.00, 'Zelle', v_admin);

  -- ── a payment must be a payment ────────────────────────────
  begin
    insert into public.contractor_payments (staff_id, paid_on, amount, created_by)
    values (v_rei, make_date(v_year, 5, 1), 0, v_admin);
    failures := failures || 'FAILED: a zero payment was recorded'::text;
  exception when check_violation then
    raise notice 'ok  a payment of zero or less is refused';
  end;

  -- ── the year total is what box 1 reports ───────────────────
  select total_paid into v_total
    from public.contractor_year_totals where staff_id = v_rei and year = v_year;
  if v_total is distinct from 750.50 then
    failures := failures || format('FAILED: the year total came to %s, expected 750.50', v_total);
  else
    raise notice 'ok  the calendar-year total adds up to the cent';
  end if;

  -- ── no confirmed threshold, no run ─────────────────────────
  insert into public.tax_years (year) values (v_year)
  on conflict (year) do update set federal_threshold = null, confirmed_on = null;

  if exists (select 1 from public.form_1099_candidates(v_year)) then
    failures := failures || 'FAILED: a 1099 run was built with no threshold set'::text;
  else
    raise notice 'ok  no threshold means no 1099 run, rather than a guessed one';
  end if;

  -- ── with a threshold, only those over it ───────────────────
  update public.tax_years
     set federal_threshold = 600, confirmed_by = v_admin, confirmed_on = current_date
   where year = v_year;

  select count(*) into v_count from public.form_1099_candidates(v_year);
  if v_count <> 1 then
    failures := failures || format('FAILED: the run found %s candidates, expected 1', v_count);
  else
    raise notice 'ok  the run picks up the one contractor over the threshold';
  end if;

  if exists (select 1 from public.form_1099_candidates(v_year) where staff_id = v_marg) then
    failures := failures || 'FAILED: a foreign person appeared in the 1099 run'::text;
  else
    raise notice 'ok  the foreign person is excluded, despite being paid the most';
  end if;

  if not exists (select 1 from public.form_1099_candidates(v_year)
                  where staff_id = v_rei and ready and problem is null) then
    failures := failures || 'FAILED: a complete profile was not marked ready'::text;
  else
    raise notice 'ok  a profile with a TIN, a W-9 and an address is ready to file';
  end if;

  -- ── an incomplete profile says why, rather than filing blank ─
  update public.contractor_profiles set address_line1 = '' where staff_id = v_rei;
  if not exists (select 1 from public.form_1099_candidates(v_year)
                  where staff_id = v_rei and not ready and problem like '%no address%') then
    failures := failures || 'FAILED: a profile with no address was still marked ready'::text;
  else
    raise notice 'ok  a missing address blocks the filing and names itself';
  end if;
  update public.contractor_profiles set address_line1 = '1 Test Street' where staff_id = v_rei;

  -- ── one person cannot be both kinds at once ────────────────
  begin
    update public.contractor_profiles
       set tax_status = 'Foreign person'
     where staff_id = v_rei;   -- w9_received_on is still set
    failures := failures || 'FAILED: a profile holds a W-9 and claims to be a foreign person'::text;
  exception when check_violation then
    raise notice 'ok  a profile cannot claim a W-9 and foreign status at once';
  end;

  -- ── a payment recorded wrongly can be taken out ────────────
  select id into v_pay from public.contractor_payments
   where staff_id = v_rei and paid_on = make_date(v_year, 3, 1);
  delete from public.contractor_payments where id = v_pay;

  select total_paid into v_total
    from public.contractor_year_totals where staff_id = v_rei and year = v_year;
  if v_total is distinct from 350.50 then
    failures := failures || format('FAILED: after removing a payment the total is %s', v_total);
  else
    raise notice 'ok  removing a payment moves the year total with it';
  end if;

  -- Below the threshold now, so no longer on the list.
  if exists (select 1 from public.form_1099_candidates(v_year) where staff_id = v_rei) then
    failures := failures || 'FAILED: someone under the threshold is still in the run'::text;
  else
    raise notice 'ok  falling under the threshold takes them out of the run';
  end if;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  -- ── a contractor sees their own payments and nobody else's ─
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_rei_uid, 'role', 'authenticated')::text, true);

  select count(*) into v_count from public.contractor_payments
   where paid_on between make_date(v_year, 1, 1) and make_date(v_year, 12, 31);
  if v_count <> 1 then
    failures := failures || format('FAILED: a contractor saw %s payments, expected only their own 1', v_count);
  else
    raise notice 'ok  a contractor sees their own payments and no one else''s';
  end if;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  if failures = '{}' then
    raise notice '';
    raise notice '--- CONTRACTOR PROFILES, PAYMENTS AND TAX YEARS VERIFIED ---';
  else
    raise notice '';
    raise notice '%  PROBLEM(S):', array_length(failures, 1);
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
