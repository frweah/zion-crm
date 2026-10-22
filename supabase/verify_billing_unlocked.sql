-- Zion Vocational Rehab CRM — billing unlocked (0190–0192)
--
-- The owner's own three tests are the first three sections, in their words:
--
--   "paying one of a client's three authorizations changes only that one"
--   "editing a number keeps the PDF attached"
--   "bulk-paying 10 rows records 10 payments with the same date"
--
-- And then the things that had better still be true once the doors are open:
--
--   A correction to a number or an amount is refused without a reason, and a
--   first entry is not a correction - that distinction is load-bearing,
--   because warrant reconciliation writes the amount paid where there was
--   none, and requiring a reason for that would stop every payment the
--   warrant reader records.
--
--   The correction log is added to and never edited or deleted. Same for the
--   directory log, which clients now write to.
--
--   A bulk clear reports per row. A row that comes to nothing is named, not
--   skipped in silence and not allowed to take the other nine down with it -
--   six of the practice's twenty-one open authorizations come to nothing.
--
--   A warrant line that turns up later for a payment recorded by hand with
--   no warrant number claims that payment instead of paying it twice.
--
--   None of these functions is reachable by somebody not signed in, or by a
--   role that does not own billing.
--
-- Uses made-up people (ZZ/ZQ), except where the directory log is being tested
-- - that log deliberately ignores invented names (0179), so the one client
-- whose logging is checked has a synthetic name that is not a fixture name,
-- exactly as verify_directory_changes.sql does. Everything is rolled back.

begin;

do $$
declare
  v_entity   uuid;
  v_bil      uuid;
  v_bil_uid  uuid := gen_random_uuid();
  v_rep      uuid;
  v_rep_uid  uuid := gen_random_uuid();
  v_client   uuid;
  v_other    uuid;
  v_a1       uuid;
  v_a2       uuid;
  v_a3       uuid;
  v_att      uuid;
  v_pdf      text := 'zz/billing-unlocked/authorization.pdf';
  v_pay      uuid;
  v_doc      uuid;
  v_page     uuid;
  v_line     uuid;
  v_batch    uuid[] := '{}';
  v_id       uuid;
  v_logged   uuid;
  v_fixture  uuid;
  v_n        integer;
  v_text     text;
  v_when     date := date '2026-06-30';
  r          record;
  failures   text[] := '{}';
begin
  select id into v_entity from public.ledger_entities where is_default;
  update public.ledger_settings set books_start = date '2020-01-01' where entity_id = v_entity;

  insert into public.staff (name, email, role, active)
  values ('ZZ Unlock Billing', 'zz-unlock-billing@example.test', 'Billing', true) returning id into v_bil;
  insert into public.staff (name, email, role, active)
  values ('ZZ Unlock Reports', 'zz-unlock-reports@example.test', 'Reports', true) returning id into v_rep;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_bil_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-unlock-billing@example.test', '{}', '{}', now(), now()),
         (v_rep_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-unlock-reports@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_bil_uid where id = v_bil;
  update public.staff set user_id = v_rep_uid where id = v_rep;

  insert into public.clients (name, stage, status)
  values ('ZZ Unlock Client', 'Job Placement', 'Active') returning id into v_client;
  insert into public.clients (name, stage, status)
  values ('ZZ Unlock Bystander', 'Job Placement', 'Active') returning id into v_other;

  -- Three authorizations on one client, all owed, all priced.
  insert into public.authorizations
    (client_id, number, service_type, rate_type, rate, start_date, end_date, received_on, status)
  values (v_client, 'ZQ-UN-1', 'Job Coaching', 'Flat Fee', 300,
          date '2026-01-01', date '2026-12-31', date '2026-02-01', 'Due') returning id into v_a1;
  insert into public.authorizations
    (client_id, number, service_type, rate_type, rate, start_date, end_date, received_on, status)
  values (v_client, 'ZQ-UN-2', 'Job Coaching', 'Flat Fee', 400,
          date '2026-01-01', date '2026-12-31', date '2026-02-01', 'Due') returning id into v_a2;
  insert into public.authorizations
    (client_id, number, service_type, rate_type, rate, start_date, end_date, received_on, status)
  values (v_client, 'ZQ-UN-3', 'Job Coaching', 'Flat Fee', 500,
          date '2026-01-01', date '2026-12-31', date '2026-02-01', 'Due') returning id into v_a3;

  insert into public.attachments (client_id, auth_id, filename, storage_path, category)
  values (v_client, v_a1, 'ZQ-UN-1 signed authorization.pdf', v_pdf, 'Authorization')
  returning id into v_att;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_bil_uid, 'role', 'authenticated')::text, true);

  -- ═══ 1. paying one changes only that one ═══════════════════
  v_pay := public.record_payment(v_a1, v_when, null, 'ZW-UN-0001', null);

  select status into v_text from public.authorizations where id = v_a1;
  if v_text <> 'Paid' then
    failures := failures || format('FAILED: the authorization that was paid says %s', v_text)::text;
  else
    raise notice 'ok  the authorization that was paid is Paid';
  end if;

  if (select paid_amount from public.authorizations where id = v_a1) <> 300
     or (select paid_on from public.authorizations where id = v_a1) <> v_when
     or (select warrant from public.authorizations where id = v_a1) <> 'ZW-UN-0001' then
    failures := failures || 'FAILED: the amount, the date or the warrant did not land on the record'::text;
  else
    raise notice 'ok  with the amount it comes to, the date received, and the warrant number';
  end if;

  select count(*) into v_n from public.authorizations
   where id in (v_a2, v_a3)
     and (status <> 'Due' or paid_on is not null or paid_amount is not null or warrant is not null);
  if v_n > 0 then
    failures := failures || format('FAILED: paying one authorization moved %s of the client''s others', v_n)::text;
  else
    raise notice 'ok  and the client''s other two authorizations did not move';
  end if;

  select count(*) into v_n from public.payments where auth_id in (v_a2, v_a3);
  if v_n > 0 then
    failures := failures || format('FAILED: %s payment(s) were recorded against the other two', v_n)::text;
  else
    raise notice 'ok  no payment was recorded against them either';
  end if;

  if (select status from public.clients where id = v_client) <> 'Active'
     or (select stage from public.clients where id = v_client) <> 'Job Placement' then
    failures := failures || 'FAILED: paying an authorization changed the client'::text;
  else
    raise notice 'ok  and the client itself was not touched';
  end if;

  -- ═══ 2. editing a number keeps the PDF attached ════════════
  perform public.edit_authorization(v_a2, jsonb_build_object('number', 'ZQ-UN-2-R'),
                                    'USOR reissued it with a corrected number');

  if (select number from public.authorizations where id = v_a2) <> 'ZQ-UN-2-R' then
    failures := failures || 'FAILED: the number did not change'::text;
  else
    raise notice 'ok  the number changed';
  end if;

  -- The attachment is on the first authorization; the number being edited is
  -- the second. Both are checked, because an edit that re-pointed every
  -- attachment on the client would pass a test that only looked at one.
  perform public.edit_authorization(v_a1, jsonb_build_object('number', 'ZQ-UN-1-R'),
                                    'USOR reissued it with a corrected number');

  if not exists (select 1 from public.attachments
                  where id = v_att and auth_id = v_a1 and storage_path = v_pdf
                    and category = 'Authorization') then
    failures := failures || 'FAILED: editing the number lost the authorization''s PDF'::text;
  else
    raise notice 'ok  and its PDF is still attached to it, at the same path';
  end if;

  select count(*) into v_n from public.authorization_corrections
   where auth_id = v_a1 and field = 'Number' and was_value = 'ZQ-UN-1' and new_value = 'ZQ-UN-1-R'
     and reason <> '';
  if v_n <> 1 then
    failures := failures || format('FAILED: the number change was logged %s times, not once', v_n)::text;
  else
    raise notice 'ok  and the change is in the correction log with its reason';
  end if;

  -- ═══ 3. ten rows, ten payments, one date ═══════════════════
  perform set_config('role', 'postgres', true);
  for v_n in 1 .. 10 loop
    insert into public.authorizations
      (client_id, number, service_type, rate_type, rate, start_date, end_date, received_on, status)
    values (v_other, format('ZQ-UN-B%s', v_n), 'Job Coaching', 'Flat Fee', 100 + v_n,
            date '2026-01-01', date '2026-12-31', date '2026-02-01', 'Due')
    returning id into v_id;
    v_batch := v_batch || v_id;
  end loop;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_bil_uid, 'role', 'authenticated')::text, true);

  select count(*) into v_n from public.bulk_mark_paid(v_batch, v_when) where outcome = 'paid';
  if v_n <> 10 then
    failures := failures || format('FAILED: bulk pay cleared %s of 10 rows', v_n)::text;
  else
    raise notice 'ok  ten rows marked paid in one go';
  end if;

  select count(*) into v_n from public.payments where auth_id = any(v_batch);
  if v_n <> 10 then
    failures := failures || format('FAILED: %s payments were recorded for 10 rows', v_n)::text;
  else
    raise notice 'ok  and ten payments were recorded, one each';
  end if;

  select count(*) into v_n from public.payments
   where auth_id = any(v_batch) and warrant_date = v_when;
  if v_n <> 10 then
    failures := failures || format('FAILED: %s of 10 payments carry the received date given', v_n)::text;
  else
    raise notice 'ok  all ten with the one received date that was given';
  end if;

  select count(*) into v_n from public.authorizations where id = any(v_batch) and status <> 'Paid';
  if v_n > 0 then
    failures := failures || format('FAILED: %s of the 10 rows are not Paid', v_n)::text;
  else
    raise notice 'ok  and every one of the ten says Paid';
  end if;

  select count(*) into v_n from public.payments
   where auth_id = any(v_batch) and amount = 100 + 1;
  if v_n <> 1 then
    failures := failures || 'FAILED: the payments did not take each authorization''s own amount'::text;
  else
    raise notice 'ok  each for its own amount, not one amount for all ten';
  end if;

  -- ── a row that comes to nothing is named, not skipped ──────
  -- Six of the practice's twenty-one open authorizations are hourly with no
  -- hours logged, so they come to nothing. The batch must not die on them and
  -- must not pass over them in silence.
  perform set_config('role', 'postgres', true);
  insert into public.authorizations
    (client_id, number, service_type, rate_type, rate, total_hours, start_date, end_date, received_on, status)
  values (v_other, 'ZQ-UN-ZERO', 'Job Coaching', 'Hourly', 0, 10,
          date '2026-01-01', date '2026-12-31', date '2026-02-01', 'Due') returning id into v_id;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_bil_uid, 'role', 'authenticated')::text, true);

  select outcome, detail into r from public.bulk_mark_paid(array[v_id], v_when);
  if r.outcome <> 'left alone' then
    failures := failures || format('FAILED: an authorization that comes to nothing was reported as %s', r.outcome)::text;
  elsif r.detail not ilike '%comes to nothing%' then
    failures := failures || format('FAILED: it was left alone without saying why: %s', r.detail)::text;
  else
    raise notice 'ok  a row that comes to nothing is left alone, and says so';
  end if;
  if (select status from public.authorizations where id = v_id) <> 'Due' then
    failures := failures || 'FAILED: it was marked paid anyway'::text;
  end if;
  if exists (select 1 from public.payments where auth_id = v_id) then
    failures := failures || 'FAILED: a payment of nothing was recorded'::text;
  end if;

  -- ═══ 4. a correction needs a reason; a first entry does not ═
  begin
    perform public.edit_authorization(v_a3, jsonb_build_object('number', 'ZQ-UN-3-X'), null);
    failures := failures || 'FAILED: a number was changed with no reason given'::text;
  exception when check_violation then
    raise notice 'ok  changing a number that was already there needs a reason';
  end;

  begin
    perform public.edit_authorization(v_a3, jsonb_build_object('rate', '650'), null);
    failures := failures || 'FAILED: a rate was changed with no reason given'::text;
  exception when check_violation then
    raise notice 'ok  so does changing the rate';
  end;

  -- The same field, from empty: recording what the paperwork says.
  perform set_config('role', 'postgres', true);
  insert into public.authorizations
    (client_id, number, service_type, rate_type, rate, start_date, end_date, received_on, status)
  values (v_other, '', 'Job Coaching', 'Flat Fee', 250,
          date '2026-01-01', date '2026-12-31', date '2026-02-01', 'Due') returning id into v_id;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_bil_uid, 'role', 'authenticated')::text, true);

  begin
    perform public.edit_authorization(v_id, jsonb_build_object('number', 'ZQ-UN-FIRST'), null);
    if (select number from public.authorizations where id = v_id) <> 'ZQ-UN-FIRST' then
      failures := failures || 'FAILED: a first number was not recorded'::text;
    else
      raise notice 'ok  but filling in a number that was blank is a first entry, not a correction';
    end if;
  exception when check_violation then
    failures := failures || 'FAILED: filling in a blank number was refused for want of a reason'::text;
  end;

  -- This is the one that would break warrant reconciliation if it went wrong.
  if exists (select 1 from public.authorization_corrections
              where auth_id = v_id and field = 'Number' and reason = '') then
    failures := failures || 'FAILED: a first entry was written into the correction log as a correction'::text;
  else
    raise notice 'ok  and a first entry does not clutter the correction log';
  end if;

  -- ═══ 5. the logs are records ═══════════════════════════════
  begin
    update public.authorization_corrections set reason = 'ZZ rewritten' where auth_id = v_a1;
    failures := failures || 'FAILED: the correction log can be rewritten'::text;
  exception when insufficient_privilege then
    raise notice 'ok  the correction log cannot be rewritten';
  end;
  begin
    delete from public.authorization_corrections where auth_id = v_a1;
    failures := failures || 'FAILED: the correction log can be deleted from'::text;
  exception when insufficient_privilege then
    raise notice 'ok  nor deleted from';
  end;

  -- ═══ 6. a later warrant line claims the payment ════════════
  -- Recorded by hand with no warrant number, which is what clearing a
  -- months-old item from the working list actually looks like: the remittance
  -- says what arrived and when, and the stub turns up weeks later.
  perform public.record_payment(v_a3, v_when, 500, null, null);
  if (select count(*) from public.payments where auth_id = v_a3) <> 1 then
    failures := failures || 'FAILED: recording a payment with no warrant number did not work'::text;
  else
    raise notice 'ok  a payment can be recorded with no warrant number';
  end if;

  perform set_config('role', 'postgres', true);
  insert into public.warrant_documents (sha256, filename, page_count)
  values (repeat('d', 64), 'zz_unlock_stub.pdf', 1) returning id into v_doc;
  insert into public.warrant_pages (document_id, page_no, warrant_no, warrant_date, total)
  values (v_doc, 1, 'ZW-UN-0009', v_when, 500.00) returning id into v_page;
  insert into public.warrant_lines (page_id, line_no, voucher, invoice_ref, described_ref, amount)
  values (v_page, 1, '26PR0000UN0009', 'ZQ-UN-3', 'ZQ-UN-3', 500) returning id into v_line;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_bil_uid, 'role', 'authenticated')::text, true);

  v_text := public.reconcile_warrant_line(v_line, false, null, null);

  if (select count(*) from public.payments where auth_id = v_a3) <> 1 then
    failures := failures || format('FAILED: the warrant line paid it twice - %s payments on one authorization',
      (select count(*) from public.payments where auth_id = v_a3))::text;
  else
    raise notice 'ok  and a warrant line for it later does not pay it twice';
  end if;

  if (select payment_id from public.warrant_lines where id = v_line) is distinct from
     (select id from public.payments where auth_id = v_a3) then
    failures := failures || format('FAILED: the line did not claim the payment already on record (it said %s)', v_text)::text;
  else
    raise notice 'ok  it claims the payment that was already there';
  end if;

  if (select warrant_no from public.payments where auth_id = v_a3) <> 'ZW-UN-0009'
     or (select warrant from public.authorizations where id = v_a3) <> 'ZW-UN-0009' then
    failures := failures || 'FAILED: the warrant number the payment never had was not filled in'::text;
  else
    raise notice 'ok  and the payment and the record take the warrant number from it';
  end if;

  -- ═══ 7. closing in bulk, with one reason ═══════════════════
  select count(*) into v_n from public.bulk_close(array[v_a2], 'ZZ cleared: never billed, confirmed with the counselor')
   where outcome = 'closed';
  if v_n <> 1 then
    failures := failures || 'FAILED: bulk close did not close it'::text;
  elsif (select closed_reason from public.authorizations where id = v_a2)
        <> 'ZZ cleared: never billed, confirmed with the counselor' then
    failures := failures || 'FAILED: the reason did not land on the record'::text;
  else
    raise notice 'ok  a bulk close carries its one reason onto every record';
  end if;

  begin
    perform public.bulk_close(array[v_a3], '   ');
    failures := failures || 'FAILED: a bulk close went through with no reason'::text;
  exception when check_violation then
    raise notice 'ok  and a bulk close with no reason is refused';
  end;

  -- ═══ 8. a client change is logged ══════════════════════════
  -- Deliberately not a ZZ name: 0179 stops the log recording invented people,
  -- and what is checked here is that a real change *is* recorded. Both halves
  -- are tried, because a guard that quietly stopped logging everything would
  -- pass a test that only checked the first.
  perform set_config('role', 'postgres', true);
  insert into public.clients (name, stage, status, phone)
  values ('Marlow Unlock Testperson', 'Job Placement', 'Active', '555-0100') returning id into v_logged;
  insert into public.clients (name, stage, status)
  values ('ZQ Unlock Invented', 'Job Placement', 'Active') returning id into v_fixture;

  if not exists (select 1 from public.directory_changes
                  where entity = 'Client' and entity_key = v_logged::text and action = 'Added') then
    failures := failures || 'FAILED: adding a client was not written to the log'::text;
  else
    raise notice 'ok  adding a client is written to the directory log';
  end if;

  if exists (select 1 from public.directory_changes where entity_key = v_fixture::text) then
    failures := failures || 'FAILED: an invented client was written into the log'::text;
  else
    raise notice 'ok  and a client invented for a test is not';
  end if;

  update public.clients set phone = '555-0199' where id = v_logged;
  if not exists (select 1 from public.directory_changes
                  where entity = 'Client' and entity_key = v_logged::text and action = 'Edited'
                    and changes -> 'phone' ->> 'from' = '555-0100'
                    and changes -> 'phone' ->> 'to' = '555-0199') then
    failures := failures || 'FAILED: a change to a client''s phone number was not logged from and to'::text;
  else
    raise notice 'ok  an edit is logged with the field, from what, to what';
  end if;

  select count(*) into v_n from public.directory_changes where entity_key = v_logged::text;
  update public.clients set phone = '555-0199' where id = v_logged;
  if (select count(*) from public.directory_changes where entity_key = v_logged::text) <> v_n then
    failures := failures || 'FAILED: a save that changed nothing was logged'::text;
  else
    raise notice 'ok  and a save that changes nothing logs nothing';
  end if;

  -- The counselor half still works, which is the regression this could cause.
  perform set_config('role', 'postgres', true);
  insert into public.counselors (name, email) values ('Ardith Unlock Testperson', 'zz-unlock-c@example.test')
  returning id into v_id;
  if not exists (select 1 from public.directory_changes
                  where entity = 'Counselor' and entity_key = v_id::text and action = 'Added') then
    failures := failures || 'FAILED: counselors stopped being logged'::text;
  else
    raise notice 'ok  and counselors are still logged, under their own entity';
  end if;
  -- Nothing is cleaned up here: the transaction is rolled back, and the log
  -- would refuse anyway. Which is worth asserting, since a client's history
  -- is now in it.
  begin
    delete from public.directory_changes where entity_key = v_logged::text;
    failures := failures || 'FAILED: a client''s entry can be deleted from the log'::text;
  exception when insufficient_privilege then
    raise notice 'ok  and a client''s entry cannot be removed from it';
  end;

  -- ═══ 9. who may do any of this ═════════════════════════════
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_rep_uid, 'role', 'authenticated')::text, true);
  begin
    perform public.record_payment(v_a3, v_when, 100, null, null);
    failures := failures || 'FAILED: somebody on Reports recorded a payment'::text;
  exception when insufficient_privilege then
    raise notice 'ok  somebody who does not own billing cannot record a payment';
  end;
  begin
    perform public.edit_authorization(v_a3, jsonb_build_object('rate', '1'), 'ZZ trying it on');
    failures := failures || 'FAILED: somebody on Reports edited an authorization'::text;
  exception when insufficient_privilege then
    raise notice 'ok  nor edit an authorization';
  end;
  begin
    perform public.bulk_mark_paid(array[v_a3], v_when);
    failures := failures || 'FAILED: somebody on Reports bulk-paid'::text;
  exception when insufficient_privilege then
    raise notice 'ok  nor clear a batch of them';
  end;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('role', 'postgres', true);

  if has_function_privilege('anon', 'public.record_payment(uuid, date, numeric, text, text)', 'execute')
     or has_function_privilege('anon', 'public.edit_authorization(uuid, jsonb, text)', 'execute')
     or has_function_privilege('anon', 'public.set_authorization_status(uuid, text, text, date)', 'execute')
     or has_function_privilege('anon', 'public.bulk_mark_paid(uuid[], date)', 'execute')
     or has_function_privilege('anon', 'public.bulk_close(uuid[], text)', 'execute')
     or has_function_privilege('anon', 'public.billing_hands()', 'execute') then
    failures := failures || 'FAILED: somebody not signed in can reach one of the billing functions'::text;
  else
    raise notice 'ok  and somebody not signed in can reach none of them';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- BILLING UNLOCKED, AND STILL WRITTEN DOWN ---';
end $$;

rollback;
