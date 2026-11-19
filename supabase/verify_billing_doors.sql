-- Zion Vocational Rehab CRM — every door that settles an authorization (0375)
--
-- Owner, 19 November 2026, on the Billing fault: "Smoke presses every control
-- in your table as the Billing account against a test row and proves the state
-- changed."
--
-- The smoke presses the screens, which is where "the action answers" is
-- proved. It cannot prove the state changed, because the account it signs in
-- as is a system account and 0120 refuses it every write - deliberately, so
-- that a mistake in a check cannot change anybody's record. So this is the
-- other half, and the half the state change belongs in: every control in that
-- table, pressed as a Billing person, with what it was supposed to do asked of
-- the row afterwards.
--
-- What has to hold:
--
--   Ready to bill, Waiting on payment, Record a payment, Date paid, taking a
--   payment back, Mark N paid, straight to Paid, Close with a reason and Open
--   it again each change the thing they say they change;
--
--   a payment writes its day into the correction log, so a paid date is a
--   logged change like any other and cannot appear from nowhere;
--
--   the Edit form still saves everything it is for, and refuses the paid date
--   and the amount paid in a sentence with the next move in it;
--
--   and no authorization on file carries a paid date with no payment behind
--   it, which is the state V1045641 was found in.
--
-- Made-up people (ZZ/ZQ). Everything is rolled back.

begin;

do $$
declare
  v_bil      uuid;
  v_bil_uid  uuid := gen_random_uuid();
  v_client   uuid;
  v_a1       uuid;
  v_a2       uuid;
  v_a3       uuid;
  v_pay      uuid;
  v_inv      uuid;
  v_when     date := date '2026-06-30';
  v_moved    date := date '2026-06-15';
  v_text     text;
  v_msg      text;
  n          integer;
  r          record;
  failures   text[] := '{}';
begin
  -- ═══ 0. the invariant, on what is on file ══════════════════
  --
  -- Asked before this script has written anything, so it is about the
  -- practice's records and not about its own fixture. A paid date with no
  -- payment behind it is the fault: the record says the money came and the
  -- ledger says it did not, and the board draws both sentences on one row.
  select count(*) into n
    from public.authorizations a
   where a.paid_on is not null
     and not exists (select 1 from public.payments p where p.auth_id = a.id);
  if n <> 0 then
    select string_agg(coalesce(nullif(a.number, ''), a.service_type), ', ') into v_text
      from public.authorizations a
     where a.paid_on is not null
       and not exists (select 1 from public.payments p where p.auth_id = a.id);
    failures := failures || format(
      'FAILED: %s authorization(s) carry a paid date with no payment behind it: %s', n, v_text)::text;
  else
    raise notice 'ok  nothing on file says it was paid without a payment behind it';
  end if;

  -- ═══ the fixture ═══════════════════════════════════════════
  insert into public.staff (name, email, role, active)
  values ('ZZ Doors Billing', 'zz-doors-billing@example.test', 'Billing', true) returning id into v_bil;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_bil_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-doors-billing@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_bil_uid where id = v_bil;

  insert into public.clients (name, stage, status)
  values ('ZZ Doors Client', 'Job Placement', 'Active') returning id into v_client;

  insert into public.authorizations
    (client_id, number, service_type, rate_type, rate, start_date, end_date, received_on, status)
  values (v_client, 'ZQ-DR-1', 'Job Development', 'Flat Fee', 500,
          date '2026-01-01', date '2026-12-31', date '2026-02-01', 'Authorized') returning id into v_a1;
  insert into public.authorizations
    (client_id, number, service_type, rate_type, rate, start_date, end_date, received_on, status)
  values (v_client, 'ZQ-DR-2', 'Job Development', 'Flat Fee', 250,
          date '2026-01-01', date '2026-12-31', date '2026-02-01', 'Due') returning id into v_a2;
  insert into public.authorizations
    (client_id, number, service_type, rate_type, rate, start_date, end_date, received_on, status)
  values (v_client, 'ZQ-DR-3', 'Job Development', 'Flat Fee', 125,
          date '2026-01-01', date '2026-12-31', date '2026-02-01', 'Due') returning id into v_a3;

  -- An invoice with a number on it, written rather than raised: `raise_invoice`
  -- takes the next number from a sequence, and a rollback does not give a
  -- sequence value back (0333 spent 138 of them). Waiting on payment and a
  -- typed submission date both need a number to exist, so one is written here.
  -- The number is a figure, not a string - the column is a bigint, and the
  -- first version of this read "ZQ-INV-DR-1" and got as far as the insert.
  insert into public.invoices (number, client_id, auth_id, amount, status, sent_to, source)
  values (9000001, v_client, v_a1, 500, 'Submitted', 'zz-office@example.test', 'Backfill')
  returning id into v_inv;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_bil_uid, 'role', 'authenticated')::text, true);

  -- ═══ 1. Ready to bill ══════════════════════════════════════
  perform public.set_authorization_status(v_a1, 'Due', null, null);
  select status into v_text from public.authorizations where id = v_a1;
  if v_text <> 'Due' then
    failures := failures || format('FAILED: Ready to bill left it %s', v_text)::text;
  else
    raise notice 'ok  Ready to bill moves it to Due';
  end if;

  -- ═══ 2. Waiting on payment, the board pill ═════════════════
  perform public.set_authorization_status(v_a1, 'Submitted', null, null);
  select status, submitted_on into r from public.authorizations where id = v_a1;
  if r.status <> 'Submitted' or r.submitted_on is null then
    failures := failures || format(
      'FAILED: Waiting on payment left it %s with submitted_on %s', r.status, r.submitted_on)::text;
  else
    raise notice 'ok  Waiting on payment moves it to Submitted and stamps the day';
  end if;

  -- ═══ 3. Record a payment ═══════════════════════════════════
  --
  -- The one door: the record's own form, the board's Paid-on cell, the bulk
  -- clear and the status pill's Paid all arrive here.
  v_pay := public.record_payment(v_a1, v_when, null, null, null);
  select status, paid_on, paid_amount into r from public.authorizations where id = v_a1;
  if r.status <> 'Paid' or r.paid_on <> v_when or r.paid_amount <> 500 then
    failures := failures || format(
      'FAILED: a recorded payment left it %s, paid_on %s, paid_amount %s',
      r.status, r.paid_on, r.paid_amount)::text;
  else
    raise notice 'ok  Record a payment makes it Paid, dated, and for what it comes to';
  end if;

  select count(*) into n from public.payments where auth_id = v_a1 and amount = 500;
  if n <> 1 then
    failures := failures || format('FAILED: %s payment row(s) behind a payment of 500', n)::text;
  else
    raise notice 'ok  with one payment row behind it';
  end if;

  select status, amount_paid into r from public.invoices where id = v_inv;
  if r.status <> 'Paid' or coalesce(r.amount_paid, 0) <> 500 then
    failures := failures || format(
      'FAILED: the invoice says %s with %s received', r.status, r.amount_paid)::text;
  else
    raise notice 'ok  and the invoice it answers is settled';
  end if;

  -- ═══ 4. and the day is written down ════════════════════════
  --
  -- The ruling: "Filling a blank paid_on is a logged change like any other."
  -- Until 0375 `record_payment` set a reason only where the status had been
  -- Authorized, so an ordinary payment wrote the paid date with nothing in
  -- the correction log - the trigger logs a field that needs no reason only
  -- when a reason was given.
  select count(*) into n
    from public.authorization_corrections
   where auth_id = v_a1 and field = 'Paid on' and new_value = v_when::text;
  if n <> 1 then
    failures := failures || format(
      'FAILED: %s correction-log row(s) for the paid date a payment wrote', n)::text;
  else
    select reason into v_text from public.authorization_corrections
     where auth_id = v_a1 and field = 'Paid on' limit 1;
    if v_text not like '%500.00%' or v_text not like '%June%' then
      failures := failures || format(
        'FAILED: the log row for the paid date does not say what arrived or when: %s', v_text)::text;
    else
      raise notice 'ok  the paid date is in the correction log, naming the payment: %', v_text;
    end if;
  end if;

  -- ═══ 5. Date paid ══════════════════════════════════════════
  perform public.correct_payment_date(v_a1, v_moved, 'ZZ doors: the remittance is dated the 15th');
  select paid_on into v_text from public.authorizations where id = v_a1;
  if v_text::date <> v_moved then
    failures := failures || format('FAILED: Date paid left it dated %s', v_text)::text;
  else
    raise notice 'ok  Date paid moves the month Money counts it in';
  end if;

  -- ═══ 6. and the payment can be taken back ══════════════════
  perform public.remove_payment(v_pay, 'ZZ doors: it was somebody else''s warrant');
  select status, paid_on, coalesce(paid_amount, 0) as paid_amount into r
    from public.authorizations where id = v_a1;
  if r.status <> 'Submitted' or r.paid_on is not null or r.paid_amount <> 0 then
    failures := failures || format(
      'FAILED: taking the payment back left it %s, paid_on %s, paid_amount %s',
      r.status, r.paid_on, r.paid_amount)::text;
  else
    raise notice 'ok  taking the payment back puts it where it was, with no paid date left behind';
  end if;

  -- ═══ 7. Mark N paid, the bulk clear ════════════════════════
  select outcome, detail into r from public.bulk_mark_paid(array[v_a2], v_when);
  if r.outcome <> 'paid' then
    failures := failures || format('FAILED: the bulk clear said "%s": %s', r.outcome, r.detail)::text;
  elsif (select status from public.authorizations where id = v_a2) <> 'Paid' then
    failures := failures || 'FAILED: the bulk clear said paid and the row is not'::text;
  else
    raise notice 'ok  Mark N paid pays the rows it was given';
  end if;

  -- ═══ 8. straight to Paid, from the status form ═════════════
  --
  -- Which is `record_payment` underneath, so there is no authorization saying
  -- Paid with no payment behind it.
  perform public.set_authorization_status(v_a3, 'Paid', null, v_when);
  select status into v_text from public.authorizations where id = v_a3;
  select count(*) into n from public.payments where auth_id = v_a3;
  if v_text <> 'Paid' or n <> 1 then
    failures := failures || format(
      'FAILED: setting the status to Paid left it %s with %s payment(s)', v_text, n)::text;
  else
    raise notice 'ok  setting the status to Paid goes through the payment';
  end if;

  -- ═══ 9. Close, with a reason ═══════════════════════════════
  perform public.set_authorization_status(v_a2, 'Closed', 'ZZ doors: never billed', null);
  select status, closed_reason into r from public.authorizations where id = v_a2;
  if r.status <> 'Closed' or r.closed_reason <> 'ZZ doors: never billed' then
    failures := failures || format(
      'FAILED: Close left it %s with the reason "%s"', r.status, r.closed_reason)::text;
  else
    raise notice 'ok  Close closes it and keeps the reason';
  end if;

  -- ═══ 10. Open it again ═════════════════════════════════════
  perform public.reopen_authorization(v_a2, 'ZZ doors: closed in error');
  select status, closed_reason into r from public.authorizations where id = v_a2;
  if r.status <> 'Authorized' or coalesce(r.closed_reason, '') <> '' then
    failures := failures || format(
      'FAILED: Open it again left it %s still saying "%s"', r.status, r.closed_reason)::text;
  else
    raise notice 'ok  Open it again puts it back to Authorized and drops the reason';
  end if;

  -- ═══ 11. the Edit form still saves the record ══════════════
  select count(*) into n from public.edit_authorization(
    v_a3, jsonb_build_object('note', 'ZZ doors note', 'recipient', 'ZZ office'), null);
  if n < 2 then
    failures := failures || format('FAILED: the Edit form saved %s of the two fields it was given', n)::text;
  else
    raise notice 'ok  the Edit form still saves what it is for';
  end if;

  -- ═══ 12. and refuses the money ═════════════════════════════
  v_msg := null;
  begin
    perform public.edit_authorization(v_a3, jsonb_build_object('paid_on', '2026-07-01'), 'ZZ doors');
  exception when others then v_msg := sqlerrm;
  end;
  if v_msg is null then
    failures := failures || 'FAILED: a paid date was typed onto the record through the Edit form'::text;
  elsif v_msg not like '%Record a payment%' then
    failures := failures || format(
      'FAILED: the refusal for a typed paid date does not say where to go instead: %s', v_msg)::text;
  else
    raise notice 'ok  a typed paid date is refused, and says where to go: %', v_msg;
  end if;

  v_msg := null;
  begin
    perform public.edit_authorization(v_a3, jsonb_build_object('paid_amount', '99'), 'ZZ doors');
  exception when others then v_msg := sqlerrm;
  end;
  if v_msg is null then
    failures := failures || 'FAILED: an amount paid was typed onto the record through the Edit form'::text;
  elsif v_msg not like '%sum of the payments%' then
    failures := failures || format(
      'FAILED: the refusal for a typed amount does not say what the figure is: %s', v_msg)::text;
  else
    raise notice 'ok  a typed amount paid is refused, and says what the figure is: %', v_msg;
  end if;

  -- And the refusal came before anything was written, which is the reason it
  -- sits with the preconditions rather than beside the write.
  select note into v_text from public.authorizations where id = v_a3;
  if v_text <> 'ZZ doors note' then
    failures := failures || format(
      'FAILED: the refused edit changed the record anyway - the note now says "%s"', v_text)::text;
  else
    raise notice 'ok  and a refused edit leaves the rest of the record alone';
  end if;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('role', 'postgres', true);

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- EVERY DOOR THAT SETTLES AN AUTHORIZATION VERIFIED ---';
end $$;

rollback;
