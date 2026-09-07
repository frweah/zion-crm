-- Zion Vocational Rehab CRM — 1099 run, delivery and consent verification
--
-- A run is the point where everything else becomes a filing. So the rules here
-- are the ones that stop a wrong filing existing at all: no run on an
-- unconfirmed figure, no run while anybody over the threshold is incomplete,
-- no foreign person on it, no silent edit of what was filed, and no electronic
-- delivery to somebody who never agreed to it.
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
  v_year     int := 2032;
  v_run      uuid;
  v_count    int;
  v_amount   numeric;
  v_rec      uuid;
  v_name     text;
  failures   text[] := '{}';
begin
  select id, user_id into v_admin, v_adm_uid from public.staff where legacy_id = 's1';
  select id, user_id into v_rei,  v_rei_uid  from public.staff where legacy_id = 's2';
  select id             into v_marg          from public.staff where legacy_id = 's3';
  select name           into v_name          from public.staff where id = v_rei;

  -- ── fixtures ───────────────────────────────────────────────
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
    w9_received_on = excluded.w9_received_on, e_delivery_consent_on = null;

  perform public.set_contractor_tin(v_rei, '123456789', 'SSN');

  insert into public.contractor_profiles (staff_id, legal_name, address_line1, city,
                                          tax_status, w8ben_received_on)
  values (v_marg, 'ZZ Foreign Person', '2 Test Street', 'Manila', 'Foreign person',
          make_date(v_year, 1, 2))
  on conflict (staff_id) do update set
    legal_name = excluded.legal_name, address_line1 = excluded.address_line1,
    city = excluded.city, tax_status = excluded.tax_status,
    w9_received_on = null, w8ben_received_on = excluded.w8ben_received_on;

  insert into public.contractor_payments (staff_id, paid_on, amount, created_by)
  values (v_rei,  make_date(v_year, 6, 1), 1200.00, v_admin),
         (v_marg, make_date(v_year, 6, 1), 9000.00, v_admin);

  insert into public.tax_years (year, federal_threshold) values (v_year, 600)
  on conflict (year) do update set federal_threshold = 600, confirmed_on = null, confirmed_by = null;

  -- ── an unconfirmed figure stops everything ─────────────────
  begin
    perform public.generate_1099_run(v_year);
    failures := failures || 'FAILED: a run was built on an unconfirmed threshold';
  exception when check_violation then
    raise notice 'ok  no run is built on a threshold nobody has confirmed';
  end;

  update public.tax_years
     set confirmed_by = v_admin, confirmed_on = current_date where year = v_year;

  -- ── an incomplete recipient stops everything, by name ──────
  update public.contractor_profiles set address_line1 = '' where staff_id = v_rei;
  begin
    perform public.generate_1099_run(v_year);
    failures := failures || 'FAILED: a run was built with an incomplete recipient';
  exception when check_violation then
    -- The refusal names the person on the roster, not the legal name typed on
    -- the profile: it is Admin who has to act on it, and Admin knows them by
    -- the name in the staff list.
    if position(v_name in sqlerrm) = 0 or sqlerrm not like '%no address%' then
      failures := failures || format('FAILED: the refusal did not name the problem: %s', sqlerrm);
    else
      raise notice 'ok  an incomplete recipient stops the run, and is named';
    end if;
  end;
  update public.contractor_profiles set address_line1 = '1 Test Street' where staff_id = v_rei;

  -- ── the run itself ─────────────────────────────────────────
  v_run := public.generate_1099_run(v_year);

  select count(*) into v_count from public.form_1099_recipients where run_id = v_run;
  if v_count <> 1 then
    failures := failures || format('FAILED: the run holds %s recipients, expected 1', v_count);
  else
    raise notice 'ok  the run holds only the contractor over the threshold';
  end if;

  if exists (select 1 from public.form_1099_recipients where run_id = v_run and staff_id = v_marg) then
    failures := failures || 'FAILED: the foreign person is on the run';
  else
    raise notice 'ok  the foreign person is not on the run, despite the larger payment';
  end if;

  select nonemployee_comp into v_amount
    from public.form_1099_recipients where run_id = v_run;
  if v_amount is distinct from 1200.00 then
    failures := failures || format('FAILED: box 1 says %s, expected 1200.00', v_amount);
  else
    raise notice 'ok  box 1 carries the calendar-year total';
  end if;

  select id into v_rec from public.form_1099_recipients where run_id = v_run;

  -- ── the snapshot does not follow later edits ───────────────
  update public.contractor_profiles set legal_name = 'ZZ Renamed Later' where staff_id = v_rei;
  if (select legal_name from public.form_1099_recipients where id = v_rec) <> 'ZZ Verify Person' then
    failures := failures || 'FAILED: renaming the profile rewrote what was filed';
  else
    raise notice 'ok  editing a profile does not rewrite a filed run';
  end if;

  begin
    update public.form_1099_recipients set nonemployee_comp = 1 where id = v_rec;
    failures := failures || 'FAILED: a filed amount was edited';
  exception when check_violation then
    raise notice 'ok  a filed amount cannot be edited, only corrected';
  end;

  -- ── electronic delivery needs consent ──────────────────────
  begin
    perform public.record_1099_delivery(v_rec, 'Email', current_date);
    failures := failures || 'FAILED: an electronic delivery was recorded without consent';
  exception when check_violation then
    raise notice 'ok  electronic delivery without consent is refused';
  end;

  perform public.record_1099_delivery(v_rec, 'Post', current_date);
  if (select delivery_method from public.form_1099_recipients where id = v_rec) <> 'Post' then
    failures := failures || 'FAILED: posting the copy was not recorded';
  else
    raise notice 'ok  posting the copy is always allowed and is recorded';
  end if;

  begin
    perform public.record_1099_delivery(v_rec, 'Post', current_date + 1);
    failures := failures || 'FAILED: a copy was delivered in the future';
  exception when check_violation then
    raise notice 'ok  a copy cannot be delivered in the future';
  end;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  -- ── consent is the contractor's own to give ────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_rei_uid, 'role', 'authenticated')::text, true);

  begin
    perform public.generate_1099_run(v_year);
    failures := failures || 'FAILED: a contractor generated a 1099 run';
  exception when insufficient_privilege then
    raise notice 'ok  only Admin can generate a run';
  end;

  begin
    perform public.record_1099_delivery(v_rec, 'Post', current_date);
    failures := failures || 'FAILED: a contractor recorded their own delivery';
  exception when insufficient_privilege then
    raise notice 'ok  only Admin can record delivery';
  end;

  perform public.set_e_delivery_consent(true);
  if (select e_delivery_consent_on from public.contractor_profiles where staff_id = v_rei)
     is distinct from current_date then
    failures := failures || 'FAILED: the contractor could not record their own consent';
  else
    raise notice 'ok  a contractor records their own consent';
  end if;

  perform public.set_e_delivery_consent(false);
  if (select e_delivery_consent_on from public.contractor_profiles where staff_id = v_rei)
     is not null then
    failures := failures || 'FAILED: consent could not be withdrawn';
  else
    raise notice 'ok  consent can be withdrawn as easily as it was given';
  end if;

  -- A contractor sees their own 1099 — it is their tax document — and no one else's.
  select count(*) into v_count from public.form_1099_recipients;
  if v_count <> 1 then
    failures := failures || format('FAILED: a contractor saw %s recipient rows, expected 1', v_count);
  else
    raise notice 'ok  a contractor sees their own 1099 and nobody else''s';
  end if;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  if failures = '{}' then
    raise notice '';
    raise notice '--- 1099 RUN, DELIVERY AND CONSENT VERIFIED ---';
  else
    raise notice '';
    raise notice '%  PROBLEM(S):', array_length(failures, 1);
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
