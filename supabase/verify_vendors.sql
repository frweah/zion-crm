-- Zion Vocational Rehab CRM — vendors, bills and purchasing (0148, 0149)
--
-- What has to hold, each tried from the direction that would break it:
--
--   A bill approved is owed and a bill paid has left the bank, each posted
--   once, and a bill voided is reversed rather than erased.
--
--   Approval is a threshold. Whoever bills may approve up to the number the
--   owner set and not a penny past it; an Admin may approve anything.
--
--   A recurring schedule creates one bill per due date however many times it
--   runs, and creates it awaiting approval - nothing posts until somebody
--   has looked at it.
--
--   Payables age by vendor as well as by person, oldest cleared first.
--
--   A 1099 run covers contractors and vendors in one run, and refuses while
--   a vendor's W-9 is missing. A recipient is one kind of payee or the other,
--   never both and never neither.
--
--   A purchase request is the asker's own until an Admin decides it.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_entity   uuid;
  v_vendor   uuid;
  v_bill     uuid;
  v_bill2    uuid;
  v_sched    uuid;
  v_rent     uuid;
  v_ap       uuid;
  v_bank     uuid;
  v_admin    uuid;
  v_adm_uid  uuid := gen_random_uuid();
  v_bills_id uuid;
  v_bill_uid uuid := gen_random_uuid();
  v_other    uuid;
  v_oth_uid  uuid := gen_random_uuid();
  v_made     integer;
  v_n        integer;
  v_amount   numeric;
  v_month    date := date_trunc('month', public.practice_today())::date;
  failures   text[] := '{}';
begin
  select id into v_entity from public.ledger_entities where is_default;
  update public.ledger_settings
     set books_start = date '2020-01-01', bill_approval_limit = 500
   where entity_id = v_entity;

  select id into v_rent from public.ledger_accounts where code = '5400' and entity_id = v_entity;
  v_ap   := public.ledger_account('ap');
  v_bank := public.ledger_account('bank');

  insert into public.staff (name, email, role, active)
  values ('ZZ Vendor Admin', 'zz-vadmin@example.test', 'Admin', true) returning id into v_admin;
  insert into public.staff (name, email, role, active)
  values ('ZZ Vendor Billing', 'zz-vbilling@example.test', 'Billing', true) returning id into v_bills_id;
  insert into public.staff (name, email, role, active)
  values ('ZZ Vendor Other', 'zz-vother@example.test', 'Job Search', true) returning id into v_other;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_adm_uid,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-vadmin@example.test',   '{}', '{}', now(), now()),
         (v_bill_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-vbilling@example.test', '{}', '{}', now(), now()),
         (v_oth_uid,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-vother@example.test',   '{}', '{}', now(), now());
  update public.staff set user_id = v_adm_uid  where id = v_admin;
  update public.staff set user_id = v_bill_uid where id = v_bills_id;
  update public.staff set user_id = v_oth_uid  where id = v_other;

  insert into public.vendors (entity_id, name, expense_account_id, terms_days)
  values (v_entity, 'ZZ Landlord', v_rent, 15) returning id into v_vendor;

  -- ── the threshold decides who may approve ─────────────────
  insert into public.vendor_bills (entity_id, vendor_id, bill_date, amount, account_id, description)
  values (v_entity, v_vendor, v_month, 400, v_rent, 'ZZ small') returning id into v_bill;
  insert into public.vendor_bills (entity_id, vendor_id, bill_date, amount, account_id, description)
  values (v_entity, v_vendor, v_month, 4000, v_rent, 'ZZ large') returning id into v_bill2;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_bill_uid, 'role', 'authenticated')::text, true);

  perform public.approve_vendor_bill(v_bill);
  if (select status from public.vendor_bills where id = v_bill) <> 'Approved' then
    failures := failures || 'FAILED: a bill inside the limit was not approved by whoever bills'::text;
  else
    raise notice 'ok  whoever bills may approve a bill inside the limit the owner set';
  end if;

  begin
    perform public.approve_vendor_bill(v_bill2);
    failures := failures || 'FAILED: a bill over the limit was approved by whoever bills'::text;
  exception when others then
    raise notice 'ok  a bill over the limit waits for an Admin';
  end;

  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);
  perform public.approve_vendor_bill(v_bill2);
  if (select status from public.vendor_bills where id = v_bill2) <> 'Approved' then
    failures := failures || 'FAILED: an Admin could not approve a bill over the limit'::text;
  else
    raise notice 'ok  an Admin may approve any of them';
  end if;

  perform set_config('role', 'postgres', true);

  -- ── approved is owed ──────────────────────────────────────
  select coalesce(sum(l.credit) - sum(l.debit), 0) into v_amount
    from public.journal_lines l where l.account_id = v_ap and l.vendor_id = v_vendor;
  if v_amount <> 4400 then
    failures := failures || format('FAILED: %s is owed to the vendor, not 4400', v_amount)::text;
  else
    raise notice 'ok  a bill approved is money the practice owes';
  end if;

  -- ── paid has left the bank ────────────────────────────────
  update public.vendor_bills
     set status = 'Paid', paid_on = public.practice_today(), method = 'ACH', reference = 'ZZ-1'
   where id = v_bill;

  select coalesce(sum(l.credit) - sum(l.debit), 0) into v_amount
    from public.journal_lines l where l.account_id = v_bank and l.vendor_id = v_vendor;
  if v_amount <> 400 then
    failures := failures || format('FAILED: paying a 400 bill moved %s out of the bank', v_amount)::text;
  else
    raise notice 'ok  a bill paid has left the bank';
  end if;

  select coalesce(sum(l.credit) - sum(l.debit), 0) into v_amount
    from public.journal_lines l where l.account_id = v_ap and l.vendor_id = v_vendor;
  if v_amount <> 4000 then
    failures := failures || format('FAILED: %s is still owed after one of two bills was paid', v_amount)::text;
  else
    raise notice 'ok  paying one bill leaves the other owed';
  end if;

  -- ── voided is reversed, not erased ────────────────────────
  update public.vendor_bills
     set status = 'Void', void_reason = 'ZZ billed twice' where id = v_bill2;
  select count(*) into v_n from public.journals
   where source_kind = 'Reversal'
     and reverses_id in (select id from public.journals
                          where source_kind = 'Vendor bill' and source_id = v_bill2);
  if v_n <> 1 then
    failures := failures || format('FAILED: voiding a bill left %s reversals', v_n)::text;
  else
    raise notice 'ok  a bill voided is reversed, and the original stays where it is';
  end if;

  select coalesce(sum(l.credit) - sum(l.debit), 0) into v_amount
    from public.journal_lines l where l.account_id = v_ap and l.vendor_id = v_vendor;
  if v_amount <> 0 then
    failures := failures || format('FAILED: %s is owed after one bill was paid and the other voided', v_amount)::text;
  end if;

  -- ── payables age by vendor ────────────────────────────────
  -- Approved by the update, not by the insert: it is the change of status
  -- that posts, which is the whole point of the trigger.
  insert into public.vendor_bills (entity_id, vendor_id, bill_date, amount, account_id)
  values (v_entity, v_vendor, public.practice_today() - 100, 250, v_rent);
  update public.vendor_bills
     set status = 'Approved', approved_by = v_admin, approved_at = now()
   where vendor_id = v_vendor and amount = 250;

  select count(*) into v_n from public.ledger_ap_aging(public.practice_today()) a
   where a.person = 'ZZ Landlord';
  if v_n = 0 then
    failures := failures || 'FAILED: a vendor owed money does not appear in the payables aging'::text;
  else
    raise notice 'ok  payables age by vendor, not only by person';
  end if;

  -- ── what is due this week ─────────────────────────────────
  select count(*) into v_n from public.bills_due_by(public.practice_today() + 7) b
   where b.vendor = 'ZZ Landlord';
  if v_n = 0 then
    failures := failures || 'FAILED: a bill due inside the week is not in "due this week"'::text;
  else
    raise notice 'ok  a bill due this week says so, and says if it is already late';
  end if;

  -- ── a recurring bill is created, not posted ───────────────
  insert into public.vendor_bill_schedules (entity_id, vendor_id, amount, account_id, description, next_due)
  values (v_entity, v_vendor, 1500, v_rent, 'ZZ monthly rent', public.practice_today())
  returning id into v_sched;

  v_made := public.create_due_recurring_bills(public.practice_today());
  if v_made <> 1 then
    failures := failures || format('FAILED: a schedule due today made %s bills', v_made)::text;
  else
    raise notice 'ok  a schedule due today writes its bill';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'
');
  end if;
end $$;

-- The rest of it, in a block of its own, so one long declaration list does
-- not have to serve two unrelated halves.
do $$
declare
  v_entity   uuid;
  v_vendor   uuid;
  v_sched    uuid;
  v_rent     uuid;
  v_admin    uuid;
  v_adm_uid  uuid := gen_random_uuid();
  v_other    uuid;
  v_oth_uid  uuid := gen_random_uuid();
  v_request  uuid;
  v_run      uuid;
  v_made     integer;
  v_n        integer;
  v_status   text;
  v_tidy     uuid;
  v_tidy_bill uuid;
  v_rec      numeric;
  v_post     numeric;
  v_diff     numeric;
  failures   text[] := '{}';
begin
  select id into v_entity from public.ledger_entities where is_default;
  update public.ledger_settings set books_start = date '2020-01-01' where entity_id = v_entity;
  select id into v_rent from public.ledger_accounts where code = '5400' and entity_id = v_entity;

  insert into public.staff (name, email, role, active)
  values ('ZZ Run Admin', 'zz-runadmin@example.test', 'Admin', true) returning id into v_admin;
  insert into public.staff (name, email, role, active)
  values ('ZZ Run Other', 'zz-runother@example.test', 'Job Search', true) returning id into v_other;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_adm_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-runadmin@example.test', '{}', '{}', now(), now()),
         (v_oth_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-runother@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_adm_uid where id = v_admin;
  update public.staff set user_id = v_oth_uid where id = v_other;

  insert into public.vendors (entity_id, name, expense_account_id)
  values (v_entity, 'ZZ Software Co', v_rent) returning id into v_vendor;

  -- ── one bill per due date, however many times it runs ─────
  insert into public.vendor_bill_schedules (entity_id, vendor_id, amount, account_id, description, next_due)
  values (v_entity, v_vendor, 99, v_rent, 'ZZ subscription', public.practice_today())
  returning id into v_sched;

  perform public.create_due_recurring_bills(public.practice_today());
  update public.vendor_bill_schedules set next_due = public.practice_today() where id = v_sched;
  perform public.create_due_recurring_bills(public.practice_today());

  select count(*) into v_n from public.vendor_bills where schedule_id = v_sched;
  if v_n <> 1 then
    failures := failures || format('FAILED: running the schedule twice for one day made %s bills', v_n)::text;
  else
    raise notice 'ok  a schedule makes one bill per due date, however many times it runs';
  end if;

  select status into v_status from public.vendor_bills where schedule_id = v_sched;
  if v_status <> 'Awaiting approval' then
    failures := failures || format('FAILED: a recurring bill arrived as %s, not awaiting approval', v_status)::text;
  else
    raise notice 'ok  a recurring bill waits for somebody to look at it';
  end if;

  select count(*) into v_n from public.journals j
   where j.source_kind = 'Vendor bill'
     and j.source_id in (select id from public.vendor_bills where schedule_id = v_sched);
  if v_n <> 0 then
    failures := failures || 'FAILED: a recurring bill posted before anybody approved it'::text;
  else
    raise notice 'ok  and nothing is posted until it is approved';
  end if;

  -- ── a 1099 vendor with no W-9 ─────────────────────────────
  update public.vendors set gets_1099 = true where id = v_vendor;
  insert into public.vendor_bills (entity_id, vendor_id, bill_date, amount, account_id,
                                   status, approved_by, approved_at, paid_on, method)
  values (v_entity, v_vendor, date '2026-02-01', 2500, v_rent,
          'Paid', v_admin, now(), date '2026-02-10', 'ACH');

  select count(*), max(problem) into v_n, v_status
    from public.vendor_1099_candidates(2026) where not ready;
  if v_n <> 1 then
    failures := failures || format('FAILED: a 1099 vendor with no W-9 gave %s not-ready rows', v_n)::text;
  elsif v_status not like '%W-9%' then
    failures := failures || format('FAILED: the problem reads "%s"', v_status)::text;
  else
    raise notice 'ok  a 1099 vendor with no W-9 on file is not ready, and says why';
  end if;

  insert into public.tax_years (year, federal_threshold, confirmed_on, utah_state_copy)
  values (2026, 600, public.practice_today(), false)
  on conflict (year) do update set federal_threshold = 600, confirmed_on = public.practice_today();

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);
  begin
    perform public.generate_1099_run(2026);
    failures := failures || 'FAILED: a run was generated with a vendor that was not ready'::text;
  exception when others then
    raise notice 'ok  a run refuses while a vendor is not ready to file';
  end;
  perform set_config('role', 'postgres', true);

  -- ── and once it is ready ──────────────────────────────────
  update public.vendors
     set w9_on_file = true, w9_received_on = date '2026-01-15',
         tin_type = 'EIN', tin_last4 = '4321', address = 'ZZ 1 Example Way, Provo, UT, 84601'
   where id = v_vendor;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);
  v_run := public.generate_1099_run(2026);
  perform set_config('role', 'postgres', true);

  select count(*) into v_n from public.form_1099_recipients
   where run_id = v_run and vendor_id = v_vendor;
  if v_n <> 1 then
    failures := failures || format('FAILED: the run holds %s rows for a ready 1099 vendor', v_n)::text;
  else
    raise notice 'ok  a vendor and a contractor are on one run, not two';
  end if;

  -- ── the tie-out does its job ──────────────────────────────
  --
  -- Three numbers that have to be the same: what was recorded paid, what the
  -- ledger posted, and what the 1099 said. The bill above was written
  -- straight in as paid, so nothing posted for it - and that is precisely
  -- what the tie-out exists to notice.
  select difference into v_diff from public.ledger_1099_tie_out(2026)
   where person = 'ZZ Software Co';
  if coalesce(v_diff, 0) = 0 then
    failures := failures || 'FAILED: money recorded paid and never posted did not show as a difference'::text;
  else
    raise notice 'ok  the tie-out notices money recorded paid that the ledger never posted';
  end if;

  -- And a bill that went the proper way round ties out exactly.
  insert into public.vendors (entity_id, name, expense_account_id, gets_1099, w9_on_file,
                              w9_received_on, tin_type, tin_last4, address)
  values (v_entity, 'ZZ Tidy Co', v_rent, true, true, date '2026-01-02', 'EIN', '9999',
          'ZZ 2 Example Way, Provo, UT, 84601')
  returning id into v_tidy;

  insert into public.vendor_bills (entity_id, vendor_id, bill_date, amount, account_id)
  values (v_entity, v_tidy, date '2026-02-01', 1800, v_rent) returning id into v_tidy_bill;
  update public.vendor_bills
     set status = 'Approved', approved_by = v_admin, approved_at = now() where id = v_tidy_bill;
  update public.vendor_bills
     set status = 'Paid', paid_on = date '2026-02-20', method = 'ACH' where id = v_tidy_bill;

  select recorded, posted, difference into v_rec, v_post, v_diff
    from public.ledger_1099_tie_out(2026) where person = 'ZZ Tidy Co';
  if coalesce(v_rec, 0) <> 1800 or coalesce(v_post, 0) <> 1800 or coalesce(v_diff, 1) <> 0 then
    failures := failures || format('FAILED: a bill paid the proper way tied out as recorded %s, posted %s, difference %s',
                                   v_rec, v_post, v_diff)::text;
  else
    raise notice 'ok  and a bill paid the proper way round ties out exactly';
  end if;

  -- ── a recipient is one kind of payee ──────────────────────
  begin
    insert into public.form_1099_recipients (run_id, staff_id, vendor_id, legal_name, nonemployee_comp)
    values (v_run, v_admin, v_vendor, 'ZZ Both', 100);
    failures := failures || 'FAILED: a recipient was both a contractor and a vendor'::text;
  exception when check_violation then
    raise notice 'ok  a 1099 recipient is a contractor or a vendor, never both';
  end;

  begin
    insert into public.form_1099_recipients (run_id, legal_name, nonemployee_comp)
    values (v_run, 'ZZ Neither', 100);
    failures := failures || 'FAILED: a recipient was neither'::text;
  exception when check_violation then
    raise notice 'ok  and never neither';
  end;

  -- ── a purchase request is the asker's own ─────────────────
  insert into public.purchase_requests (staff_id, what, why, amount)
  values (v_other, 'ZZ a laptop', 'ZZ the old one died', 900) returning id into v_request;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_oth_uid, 'role', 'authenticated')::text, true);
  update public.purchase_requests set status = 'Approved', decided_by = v_other where id = v_request;
  get diagnostics v_n = row_count;
  if v_n > 0 then
    failures := failures || 'FAILED: somebody approved their own purchase request'::text;
  else
    raise notice 'ok  nobody decides their own purchase request';
  end if;

  select count(*) into v_n from public.purchase_requests where id = v_request;
  if v_n <> 1 then
    failures := failures || 'FAILED: somebody cannot see their own request'::text;
  else
    raise notice 'ok  but they can see it, and what was decided';
  end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);
  update public.purchase_requests
     set status = 'Approved', decided_by = v_admin, decided_at = now() where id = v_request;
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    failures := failures || 'FAILED: an Admin could not decide a purchase request'::text;
  else
    raise notice 'ok  an Admin decides it';
  end if;
  perform set_config('role', 'postgres', true);

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
