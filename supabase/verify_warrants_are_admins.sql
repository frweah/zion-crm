-- Zion Vocational Rehab CRM — a warrant is Admin's (0360, 0361, 0362)
--
-- The owner's ruling, 14 November 2026: a warrant stub, a warrant line, a
-- voucher number and a warrant total are Admin's. Billing sees the outcome -
-- Paid or Short-paid, the day, the amount - and nothing else, and so does a
-- reports manager holding a billing grant.
--
-- What makes this worth a verify script rather than a screen test is what the
-- survey found. The three warrant tables were gated and nothing else was: the
-- warrant and voucher numbers also sit on `payments`, `invoices` and
-- `authorizations`, whose read policy is "somebody is signed in", so every
-- role in the practice could read all 159 warrant numbers and all 159
-- vouchers. The screens never showed them. So the question here is never "what
-- does the screen draw" - it is what the database hands over when asked.
--
-- Two things that would each make the whole thing hollow are asked for
-- explicitly:
--
--   * the billing grant. `staff_has_area('billing', ...)` is how a CPA and
--     Margaret are let into the money, and every warrant gate used to ask it.
--     A ruling that moved the screens and left the grant asking would move
--     nothing, so Margaret is asked for everything Billing is asked for.
--
--   * the ordinary work. A rule that stops Billing recording a payment, or
--     editing an authorization, or reading what it was paid, is a rule that
--     gets switched off in a week. The last block asserts the day's work still
--     goes through.
--
-- Everything is rolled back.

begin;

do $$
declare
  failures text[] := '{}';

  v_billing  record;
  v_grantee  record;
  v_admin    record;

  v_client   uuid;
  v_auth     uuid;
  v_doc      uuid;
  v_page     uuid;
  v_line     uuid;
  v_pay      uuid;

  v_n        integer;
  v_closed   text;
  v_open     text;
  v_ok       boolean;
  v_msg      text;

  -- The columns that must be closed to everybody signed in, and nothing else.
  -- `payments.warrant_date` is not here on purpose: it is the day the money
  -- arrived, which is the "paid on" the owner's ruling leaves with Billing.
  v_expected text := 'authorizations.warrant, invoices.voucher, invoices.warrant, '
                     || 'payments.voucher, payments.warrant_line_id, '
                     || 'payments.warrant_no';
begin
  -- ── who is asking ──────────────────────────────────────────
  select s.id, s.user_id, s.name into v_billing
    from public.staff s
   where s.active and s.user_id is not null and s.role = 'Billing'
     and not coalesce(s.is_system, false)
   order by s.created_at limit 1;

  -- The reports manager with a billing edit grant: the person the ruling is
  -- really about, because her grant used to open every warrant gate.
  select s.id, s.user_id, s.name into v_grantee
    from public.staff s
    join public.staff_access_grants g
      on g.staff_id = s.id and g.area = 'billing' and g.revoked_at is null
   where s.active and s.user_id is not null and s.role <> 'Admin'
   order by s.created_at limit 1;

  select s.id, s.user_id, s.name into v_admin
    from public.staff s
   where s.active and s.user_id is not null and s.role = 'Admin'
     and not coalesce(s.is_system, false)
   order by s.created_at limit 1;

  if v_billing.user_id is null or v_admin.user_id is null then
    raise exception 'This needs a signed-in Billing person and an Admin to ask as.';
  end if;

  -- ── the fixture: one warrant, one line, one payment ────────
  select id into v_client from public.clients where status = 'Active' order by created_at limit 1;
  insert into public.authorizations
    (client_id, number, service_type, funding_source, rate_type, rate, total_hours,
     start_date, end_date, status, submitted_on)
  values (v_client, 'ZZ-WARRANT-1', 'Job Search', 'Utah VR', 'Hourly', 50, 10,
          public.practice_today() - 60, public.practice_today() + 60, 'Submitted',
          public.practice_today() - 5)
  returning id into v_auth;

  insert into public.warrant_documents (sha256, filename, relative_path, page_count, first_seen)
  values (encode(sha256('zz-warrant-fixture'::bytea), 'hex'), 'ZZ warrant fixture.pdf',
          '_Warrants/ZZ warrant fixture.pdf', 1, now())
  returning id into v_doc;

  insert into public.warrant_pages
    (document_id, page_no, image_path, ocr_text, rotation, warrant_no, warrant_date,
     total, lines_total, status, problems, received_at)
  values (v_doc, 1, 'warrants/zz-warrant-fixture-1.png', 'ZZ fixture', 0, 'ZZ15000001',
          public.practice_today(), 500.00, 500.00, 'Needs review', '{}', now())
  returning id into v_page;

  insert into public.warrant_lines
    (page_id, line_no, raw, dept, voucher, invoice_ref, described_ref, client_code,
     client_name, service_date, described_amount, amount, status, problem, decided_by_name)
  values (v_page, 1, 'ZZ fixture line', 'ZQ', 'ZQ9000001', 'ZZ-WARRANT-1', 'ZZ-WARRANT-1',
          '999999', 'ZQ Fixture', public.practice_today(), 500.00, 500.00,
          'Needs review', '', '')
  returning id into v_line;

  insert into public.payments
    (auth_id, amount, warrant_no, warrant_date, voucher, source, recorded_by, recorded_by_name)
  values (v_auth, 500.00, 'ZZ15000001', public.practice_today(), 'ZQ9000001',
          'Warrant', v_admin.id, 'ZQ Fixture')
  returning id into v_pay;

  insert into public.authorization_corrections
    (auth_id, auth_number, field, was_value, new_value, reason, staff_id, staff_name)
  -- 'Warrant' with a capital, because `field` holds the label a person reads
  -- and the constraint on the column is that list. The first version of the
  -- policy in 0360 compared the column name and so hid nothing.
  values (v_auth, 'ZZ-WARRANT-1', 'Warrant', '', 'ZZ15000001', 'fixture',
          v_admin.id, 'ZQ Fixture');

  /*
   * And a correction on a different field whose *words* name the warrant.
   *
   * This is the one the smoke found and nothing else did: the reason on a
   * 'Paid on' correction read "Warrant F15677921 is dated Nov 3, 2026 and the
   * payment was recorded as Nov 6", and the field is not 'Warrant', so the
   * field test let it through. The row is kept whole - it is somebody's
   * account of a real correction - and the trigger from 0364 records that it
   * is Admin's.
   */
  insert into public.authorization_corrections
    (auth_id, auth_number, field, was_value, new_value, reason, staff_id, staff_name)
  values (v_auth, 'ZZ-WARRANT-1', 'Paid on', '', public.practice_today()::text,
          'Warrant ZZ15000001 is dated today and the payment was recorded yesterday.',
          v_admin.id, 'ZQ Fixture');


  -- ── 1. the closed set is exactly the warrant columns ───────
  --
  -- Asked of the catalogue, not of a list of names: a column added to one of
  -- these three tables tomorrow arrives ungranted, because the grant is by
  -- name. Which way it goes wrong matters - an ungranted ordinary column is an
  -- empty screen, and a granted warrant column is the leak - so both
  -- directions are one assertion about the whole set.
  select coalesce(string_agg(c.relname || '.' || a.attname, ', ' order by c.relname, a.attname), '')
    into v_closed
    from pg_attribute a
    join pg_class c on c.oid = a.attrelid
    join pg_namespace ns on ns.oid = c.relnamespace
   where ns.nspname = 'public' and c.relname in ('payments', 'invoices', 'authorizations')
     and a.attnum > 0 and not a.attisdropped
     and not has_column_privilege('authenticated', c.oid, a.attname, 'select');

  if v_closed <> v_expected then
    failures := failures || format(
      'FAILED: the columns closed to everybody signed in are [%s] and should be [%s]',
      v_closed, v_expected)::text;
  else
    raise notice 'ok  the closed columns are exactly the warrant ones: %', v_closed;
  end if;

  -- And the warrant is closed to writing as well as reading, or it is a field
  -- Billing cannot see and can still set.
  if has_column_privilege('authenticated', 'public.authorizations'::regclass, 'warrant', 'update') then
    failures := failures ||
      'FAILED: authenticated may still UPDATE authorizations.warrant'::text;
  else
    raise notice 'ok  nobody signed in may write authorizations.warrant either';
  end if;

  -- ── 2. no view carries a warrant ───────────────────────────
  select coalesce(string_agg(c.relname || '.' || a.attname, ', ' order by c.relname, a.attname), '')
    into v_open
    from pg_attribute a
    join pg_class c on c.oid = a.attrelid
    join pg_namespace ns on ns.oid = c.relnamespace
   where ns.nspname = 'public' and c.relkind = 'v'
     and a.attnum > 0 and not a.attisdropped
     and (a.attname like '%warrant%' or a.attname = 'voucher')
     and c.relname <> 'payment_waiting_for_its_warrant';

  if v_open <> '' then
    failures := failures || format(
      'FAILED: these views still carry a warrant column, and a definer view is a door a column grant does not shut: %s',
      v_open)::text;
  else
    raise notice 'ok  no view in public carries a warrant column, bar the waiting list itself';
  end if;

  -- ── 3. asked as Billing, and as the grant holder ───────────
  foreach v_msg in array array['Billing', 'the billing grant'] loop
    if v_msg = 'Billing' then
      perform set_config('request.jwt.claims',
        json_build_object('sub', v_billing.user_id::text, 'role', 'authenticated')::text, true);
    elsif v_grantee.user_id is null then
      raise notice 'ok  (nobody holds a billing grant today, so there is nothing to ask)';
      continue;
    else
      perform set_config('request.jwt.claims',
        json_build_object('sub', v_grantee.user_id::text, 'role', 'authenticated')::text, true);
    end if;
    perform set_config('role', 'authenticated', true);

    -- the three tables
    select count(*) into v_n from public.warrant_pages;
    if v_n <> 0 then
      failures := failures || format('FAILED: %s reads %s warrant page(s)', v_msg, v_n)::text;
    end if;
    select count(*) into v_n from public.warrant_lines;
    if v_n <> 0 then
      failures := failures || format('FAILED: %s reads %s warrant line(s)', v_msg, v_n)::text;
    end if;
    select count(*) into v_n from public.warrant_documents;
    if v_n <> 0 then
      failures := failures || format('FAILED: %s reads %s warrant document(s)', v_msg, v_n)::text;
    end if;

    -- the columns. A closed column raises rather than answering, so each is
    -- asked in its own block: a refusal is the pass.
    begin
      select count(*) into v_n from public.payments where warrant_no is not null;
      failures := failures || format('FAILED: %s reads payments.warrant_no', v_msg)::text;
    exception when insufficient_privilege then null;
    end;
    begin
      select count(*) into v_n from public.payments where voucher is not null;
      failures := failures || format('FAILED: %s reads payments.voucher', v_msg)::text;
    exception when insufficient_privilege then null;
    end;
    -- And the other way: the day the money arrived is Billing's, and a dozen
    -- views date a payment by it.
    begin
      select count(*) into v_n from public.payments where warrant_date is not null;
      if v_n = 0 then
        failures := failures || format(
          'FAILED: %s reads no payment date at all, so nothing can date a payment', v_msg)::text;
      end if;
    exception when insufficient_privilege then
      failures := failures || format(
        'FAILED: %s cannot read the day a payment arrived, which is the paid-on date', v_msg)::text;
    end;
    begin
      select count(*) into v_n from public.invoices where warrant is not null;
      failures := failures || format('FAILED: %s reads invoices.warrant', v_msg)::text;
    exception when insufficient_privilege then null;
    end;
    begin
      select count(*) into v_n from public.invoices where voucher is not null;
      failures := failures || format('FAILED: %s reads invoices.voucher', v_msg)::text;
    exception when insufficient_privilege then null;
    end;
    begin
      select count(*) into v_n from public.authorizations where warrant is not null;
      failures := failures || format('FAILED: %s reads authorizations.warrant', v_msg)::text;
    exception when insufficient_privilege then null;
    end;

    -- the waiting list and the gap, both of which read closed columns as their
    -- owner and so must refuse by the rule inside them rather than by a grant
    select count(*) into v_n from public.payment_waiting_for_its_warrant;
    if v_n <> 0 then
      failures := failures || format(
        'FAILED: %s sees %s row(s) of the warrants-not-on-file list', v_msg, v_n)::text;
    end if;
    select count(*) into v_n from public.warrants_not_accounted_for();
    if v_n <> 0 then
      failures := failures || format(
        'FAILED: %s sees %s warrant(s) that do not add up, with the numbers', v_msg, v_n)::text;
    end if;

    -- the correction log: the row is hidden, the rest of the log is not
    select count(*) into v_n from public.authorization_corrections where field = 'Warrant';
    if v_n <> 0 then
      failures := failures || format(
        'FAILED: %s reads %s logged warrant change(s), before and after', v_msg, v_n)::text;
    end if;

    -- And the correction whose words name a warrant, on a field that is not
    -- the warrant. Asked through the flag rather than by searching the text,
    -- which is the same way the policy asks it.
    select count(*) into v_n from public.authorization_corrections k
     where exists (select 1 from public.correction_is_admins c where c.correction_id = k.id);
    if v_n <> 0 then
      failures := failures || format(
        'FAILED: %s reads %s correction(s) whose reason names a warrant', v_msg, v_n)::text;
    end if;


    -- and the five functions
    v_ok := false;
    begin
      perform public.add_warrant_line(v_page, 'ZQ9000002', 'ZZ-WARRANT-1', '999999', 'ZQ', null, 10.00);
    exception when others then v_ok := true;
    end;
    if not v_ok then
      failures := failures || format('FAILED: %s added a line to a warrant page', v_msg)::text;
    end if;

    v_ok := false;
    begin
      perform public.dismiss_warrant_line(v_line, 'fixture');
    exception when others then v_ok := true;
    end;
    if not v_ok then
      failures := failures || format('FAILED: %s set a warrant line aside', v_msg)::text;
    end if;

    v_ok := false;
    begin
      perform public.reconcile_warrant_page(v_page);
    exception when others then v_ok := true;
    end;
    if not v_ok then
      failures := failures || format('FAILED: %s reconciled a warrant page', v_msg)::text;
    end if;

    v_ok := false;
    begin
      perform public.correct_warrant_line(v_line, 'ZQ9000003', 'ZZ-WARRANT-1', '999999', 'ZQ', null, 10.00);
    exception when others then v_ok := true;
    end;
    if not v_ok then
      failures := failures || format('FAILED: %s corrected a warrant line', v_msg)::text;
    end if;

    -- the write door: a warrant number on a payment, and on an edit
    v_ok := false;
    begin
      perform public.record_payment(v_auth, public.practice_today(), 10.00, 'ZZ15000002', null);
    exception when others then v_ok := true;
    end;
    if not v_ok then
      failures := failures || format('FAILED: %s recorded a payment with a warrant number', v_msg)::text;
    end if;

    v_ok := false;
    begin
      perform public.edit_authorization(v_auth, jsonb_build_object('warrant', 'ZZ15000003'), 'fixture');
    exception when others then v_ok := true;
    end;
    if not v_ok then
      failures := failures || format('FAILED: %s set a warrant through edit_authorization', v_msg)::text;
    end if;

    v_ok := false;
    begin
      perform public.add_authorization(v_client, 'ZZ-WARRANT-2', 'Job Search', 'Hourly', 50, 10,
        public.practice_today(), public.practice_today() + 30, '', 'Utah VR', null,
        public.practice_today(), public.practice_today(), 100.00, 'ZZ15000004');
    exception when others then v_ok := true;
    end;
    if not v_ok then
      failures := failures || format(
        'FAILED: %s added an authorization already paid, with a warrant number on it', v_msg)::text;
    end if;

    perform set_config('request.jwt.claims', '', true);
    perform set_config('role', 'postgres', true);
    raise notice 'ok  % is refused every warrant: the tables, the columns, the views and the seven functions', v_msg;
  end loop;

  -- ── 4. the ordinary work still goes through ────────────────
  --
  -- The assertion that matters most. A rule that stopped Billing recording
  -- what arrived, or reading what was paid, would be switched off within the
  -- week, and then none of the above would hold either.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_billing.user_id::text, 'role', 'authenticated')::text, true);

  -- what it was paid, by the authorization
  select count(*) into v_n from public.payments_for_billing(array[v_auth]);
  if v_n = 0 then
    failures := failures ||
      'FAILED: Billing cannot read the payment on an authorization at all'::text;
  else
    select count(*) into v_n from public.payments_for_billing(array[v_auth])
     where amount = 500.00 and paid_on = public.practice_today();
    if v_n <> 1 then
      failures := failures ||
        'FAILED: Billing reads the payment but not the amount and the day it arrived'::text;
    else
      raise notice 'ok  Billing reads the payment: 500.00, and the day it arrived';
    end if;
  end if;

  -- and in the month
  select count(*) into v_n
    from public.payments_paid_between(public.practice_today(), public.practice_today() + 1)
   where id = v_pay;
  if v_n <> 1 then
    failures := failures || 'FAILED: Billing cannot read the month''s payments'::text;
  else
    raise notice 'ok  Billing reads the month''s payments';
  end if;

  -- the outcome on the record
  select count(*) into v_n from public.authorizations
   where id = v_auth and status is not null;
  if v_n <> 1 then
    failures := failures || 'FAILED: Billing cannot read the authorization''s status'::text;
  end if;

  select count(*) into v_n from public.authorization_record where id = v_auth;
  if v_n <> 1 then
    failures := failures || 'FAILED: Billing cannot read the authorization record'::text;
  else
    raise notice 'ok  Billing reads the authorization record, its status, paid day and amount';
  end if;

  select count(*) into v_n from public.client_authorizations where client_id = v_client;
  if v_n = 0 then
    failures := failures || 'FAILED: Billing cannot read a client''s authorizations'::text;
  end if;

  select count(*) into v_n from public.billed_work where auth_id = v_auth;
  if v_n <> 1 then
    failures := failures || 'FAILED: Billing cannot read billed work'::text;
  else
    raise notice 'ok  Billing reads the client''s authorizations and the billed work';
  end if;

  -- a payment with no warrant on it: the whole of what Billing records now
  v_msg := null;
  begin
    v_pay := public.record_payment(v_auth, public.practice_today(), 25.00, null, null);
  exception when others then v_msg := sqlerrm;
  end;
  if v_msg is not null then
    failures := failures || format(
      'FAILED: Billing cannot record a payment at all now: %s', v_msg)::text;
  else
    raise notice 'ok  Billing records a payment with no warrant field, which is the owner''s ruling';
  end if;

  -- an edit that is not a warrant
  v_msg := null;
  begin
    perform public.edit_authorization(v_auth, jsonb_build_object('note', 'ZZ fixture note'), 'fixture');
  exception when others then v_msg := sqlerrm;
  end;
  if v_msg is not null then
    failures := failures || format(
      'FAILED: Billing cannot edit an authorization now: %s', v_msg)::text;
  else
    raise notice 'ok  Billing still edits everything on an authorization but the warrant';
  end if;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('role', 'postgres', true);

  -- ── 5. Admin still does the work ───────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin.user_id::text, 'role', 'authenticated')::text, true);

  select count(*) into v_n from public.warrant_pages where id = v_page;
  if v_n <> 1 then
    failures := failures || 'FAILED: Admin cannot read a warrant page'::text;
  end if;
  select count(*) into v_n from public.warrant_lines where id = v_line;
  if v_n <> 1 then
    failures := failures || 'FAILED: Admin cannot read a warrant line'::text;
  end if;
  select count(*) into v_n from public.authorization_corrections
   where auth_id = v_auth and field = 'Warrant';
  if v_n <> 1 then
    failures := failures || 'FAILED: Admin cannot read a logged warrant change'::text;
  end if;
  select count(*) into v_n from public.authorization_corrections k
   where k.auth_id = v_auth
     and exists (select 1 from public.correction_is_admins c where c.correction_id = k.id);
  -- One: the fixture's 'Paid on' correction, whose words name the warrant.
  -- The 'Warrant' correction beside it is hidden by the field rather than by
  -- the flag, and its own reason names nothing.
  if v_n <> 1 then
    failures := failures || format(
      'FAILED: Admin reads %s of the 1 correction whose words name a warrant, so the account of a real correction has been lost to a permission',
      v_n)::text;
  else
    raise notice 'ok  and Admin reads the correction whose words name a warrant, words intact';
  end if;

  v_msg := null;
  begin
    perform public.dismiss_warrant_line(v_line, 'fixture: set aside by Admin');
  exception when others then v_msg := sqlerrm;
  end;
  if v_msg is not null then
    failures := failures || format('FAILED: Admin cannot set a warrant line aside: %s', v_msg)::text;
  else
    raise notice 'ok  Admin reads the stub, the line and the logged change, and sets a line aside';
  end if;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('role', 'postgres', true);

  -- ── 6. the storage bucket, and the prose ───────────────────
  --
  -- The stub images. A policy naming Billing is the same door one layer down,
  -- and it is not reached through any screen this ruling moved.
  select count(*) into v_n
    from pg_policy p
    join pg_class c on c.oid = p.polrelid
    join pg_namespace ns on ns.oid = c.relnamespace
   where ns.nspname = 'storage' and c.relname = 'objects'
     and pg_get_expr(p.polqual, p.polrelid) like '%warrants%'
     and pg_get_expr(p.polqual, p.polrelid) like '%Billing%';
  if v_n <> 0 then
    failures := failures ||
      'FAILED: a storage policy on the warrants bucket still names Billing'::text;
  else
    raise notice 'ok  only Admin can sign a link to a stub image';
  end if;

  -- And the numbers that no grant can close, because they are in sentences.
  select count(*) into v_n
    from (select note from public.authorizations
           union all select note from public.invoices) t
   where coalesce(note, '') ~ 'warrant\s+[A-Z]?[0-9]{6,}'
      or coalesce(note, '') ~ 'voucher\s+[0-9A-Za-z-]{4,}';
  if v_n <> 0 then
    failures := failures || format(
      'FAILED: %s note(s) name a warrant or voucher number in prose, which Billing reads on the record',
      v_n)::text;
  else
    raise notice 'ok  no note on an authorization or an invoice names a warrant number';
  end if;

  -- The records-request bundle, which a client may ask for and Billing may
  -- generate: the invoice in it carries no warrant and no voucher.
  if (select pg_get_functiondef(p.oid) from pg_proc p
        join pg_namespace ns on ns.oid = p.pronamespace
       where ns.nspname = 'public' and p.proname = 'records_request_bundle')
     ~* '''(warrant|voucher)'',' then
    failures := failures ||
      'FAILED: the records-request bundle still puts the warrant or the voucher in the invoice'::text;
  else
    raise notice 'ok  the bundle carries no warrant and no voucher';
  end if;

  /*
   * The status history.
   *
   * `authorization_transition` wrote `new.warrant` as the note on every move
   * to Paid - nothing else - so thirteen rows of a log that Billing reads were
   * a bare warrant number. Found by rendering the authorization record as the
   * Billing person and reading the HTML, which is the only thing that found
   * it: no column grant covers a log, and no screen names a warrant column to
   * put it there.
   *
   * Asked of the whole table, and of the trigger that writes it, because a
   * row cleared without the writer being stopped comes straight back.
   */
  select count(*) into v_n
    from public.authorization_events e
   where exists (
     select 1 from (
       select warrant_no as n from public.payments where coalesce(warrant_no, '') <> ''
       union select warrant from public.authorizations where coalesce(warrant, '') <> ''
       union select warrant_no from public.warrant_pages where coalesce(warrant_no, '') <> ''
     ) w
      where e.note like '%' || w.n || '%');
  if v_n <> 0 then
    failures := failures || format(
      'FAILED: %s status note(s) name a warrant, and Billing reads that log', v_n)::text;
  elsif (select pg_get_functiondef(p.oid) from pg_proc p
           join pg_namespace ns on ns.oid = p.pronamespace
          where ns.nspname = 'public' and p.proname = 'authorization_transition')
        like '%nullif(new.warrant%' then
    failures := failures ||
      'FAILED: the status trigger still writes the warrant number as the note'::text;
  else
    raise notice 'ok  no status note names a warrant, and the trigger no longer writes one';
  end if;

  -- And the ledger stops writing one into a journal memo, which Books shows.
  if (select count(*) from pg_proc p
        join pg_namespace ns on ns.oid = p.pronamespace
       where ns.nspname = 'public' and p.proname in ('post_authorization', 'post_billing_item')
         and pg_get_functiondef(p.oid) like '%'', warrant ''%') <> 0 then
    failures := failures ||
      'FAILED: a ledger posting still writes the warrant number into the journal memo'::text;
  else
    raise notice 'ok  no journal memo is written with a warrant number in it';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- WARRANTS VERIFIED ---';
end $$;

rollback;
