-- Zion Vocational Rehab CRM — the invoice ledger (0306-0312)
--
-- What has to hold:
--
--   Submit writes the invoice, with the hours it is for, and a second Submit
--   over the same hours bills nothing. An authorization with an invoice still
--   outstanding gets no second one.
--
--   A payment settles the invoice it answers. A short payment says
--   Short-paid, and the difference is readable. Taking it back puts the
--   invoice back to Submitted.
--
--   Where two claims are outstanding, a payment does not guess which one it
--   answers.
--
--   Chasing fires at thirty days and again at forty-five, and not before
--   either. Work logged and not invoiced is raised after the 5th of the
--   following month, and not before it.
--
--   A short payment is raised the day it happens, and stops being raised once
--   somebody records what came of querying it. A note that settles the
--   question has to say what settled it, it is never rewritten, and settling
--   one does not stop the chase on money still owed.
--
--   And on the live ledger: every authorization's invoices agree with its
--   payments, and every payment that names a warrant is on an invoice.
--
--   Nobody signed out can read any of it, and the system account cannot
--   write to it.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_admin uuid; v_admin_uid uuid := gen_random_uuid();
  v_client uuid; v_auth uuid; v_auth2 uuid;
  v_inv uuid; v_inv2 uuid; v_inv3 uuid; v_pay uuid;
  v_auth3 uuid; v_q uuid; v_num bigint;
  v_e1 uuid; v_e2 uuid;
  v_n integer; v_amount numeric; v_status text;
  v_office uuid;
  failures text[] := '{}';
begin
  insert into public.staff (name, email, role, active)
  values ('ZZ Invoice Admin', 'zz-invoice-admin@example.test', 'Admin', true) returning id into v_admin;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_admin_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-invoice-admin@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_admin_uid where id = v_admin;

  insert into public.clients (name, stage, status, assigned_staff_id)
  values ('ZZ Invoiced Person', 'Job Search', 'Active', v_admin) returning id into v_client;

  insert into public.authorizations
    (client_id, number, service_type, rate_type, rate, total_hours, status, start_date, end_date)
  -- WSA Tier 2 rather than Job Coaching, deliberately. Job Coaching is the
  -- one monthly service, and route_entry_to_month moves every hour logged
  -- against it onto a month of its own - so an hourly fixture on Job Coaching
  -- would log three hours and find none, which is how the first run of this
  -- script failed and what led to the parent guard in raise_invoice. The
  -- parent case is its own case below.
  values (v_client, 'V0000901', 'WSA Tier 2', 'Hourly', 45, 20, 'Due',
          public.practice_today() - 90, public.practice_today() + 90)
  returning id into v_auth;

  insert into public.service_entries (auth_id, date, hours, notes, staff_id)
  values (v_auth, public.practice_today() - 20, 3.00, 'ZQ first visit', v_admin) returning id into v_e1;
  insert into public.service_entries (auth_id, date, hours, notes, staff_id)
  values (v_auth, public.practice_today() - 10, 2.00, 'ZQ second visit', v_admin) returning id into v_e2;

  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_admin_uid, 'role', 'authenticated')::text, true);

  -- ── Submit writes it, with the hours on it ─────────────────
  v_inv := public.submit_invoice(v_auth);
  select amount into v_amount from public.invoices where id = v_inv;
  select count(*) into v_n from public.invoice_lines where invoice_id = v_inv;
  if v_amount <> 225.00 then
    failures := failures || format('FAILED: five hours at 45 was invoiced as %s', v_amount)::text;
  elsif v_n <> 2 then
    failures := failures || format('FAILED: the invoice has %s line(s) for two visits', v_n)::text;
  elsif (select count(*) from public.invoice_lines where invoice_id = v_inv and entry_id in (v_e1, v_e2)) <> 2 then
    failures := failures || 'FAILED: the lines are not the service entries they bill'::text;
  else
    raise notice 'ok  Submit writes the invoice, at the hours logged, with a line for each';
  end if;

  -- ── and will not send the same claim twice ─────────────────
  begin
    perform public.submit_invoice(v_auth);
    failures := failures || 'FAILED: a second invoice was raised while the first was outstanding'::text;
  exception when unique_violation then
    raise notice 'ok  an authorization with an invoice outstanding gets no second one';
  end;

  -- ── a payment settles it ───────────────────────────────────
  perform public.record_payment(v_auth, public.practice_today(), 225.00, 'FZZ0001', 'ZZAW0000001');
  select status, amount_paid into v_status, v_amount from public.invoices where id = v_inv;
  if v_status <> 'Paid' then
    failures := failures || format('FAILED: a payment in full left the invoice %s', v_status)::text;
  elsif v_amount <> 225.00 then
    failures := failures || format('FAILED: the invoice records %s paid', v_amount)::text;
  elsif (select warrant from public.invoices where id = v_inv) <> 'FZZ0001' then
    failures := failures || 'FAILED: the warrant did not reach the invoice'::text;
  elsif (select count(*) from public.payments where invoice_id = v_inv) <> 1 then
    failures := failures || 'FAILED: the payment is not pointed at the invoice it answers'::text;
  else
    raise notice 'ok  a payment settles the invoice it answers, and brings the warrant with it';
  end if;

  -- ── the second claim, after the first was paid ─────────────
  insert into public.service_entries (auth_id, date, hours, notes, staff_id)
  values (v_auth, public.practice_today() - 5, 4.00, 'ZQ third visit', v_admin);
  v_inv2 := public.submit_invoice(v_auth);
  if (select amount from public.invoices where id = v_inv2) <> 180.00 then
    failures := failures || format('FAILED: the second claim billed %s rather than the four new hours',
                                   (select amount from public.invoices where id = v_inv2))::text;
  elsif (select count(*) from public.invoice_lines where invoice_id = v_inv2) <> 1 then
    failures := failures || 'FAILED: the second claim billed hours that were already on the first'::text;
  else
    raise notice 'ok  a repeat claim bills only the hours nothing has billed yet';
  end if;

  -- ── a short payment is short by arithmetic ─────────────────
  -- The authorization went to Paid when the first claim was paid, and
  -- record_payment takes a payment against one that is Submitted or Due. A
  -- second claim going out is the authorization being submitted again, which
  -- the state machine allows, so that is what the fixture does. It is also
  -- the first place the two models visibly come apart: the authorization is a
  -- ceiling with one status, and the claims against it each have their own.
  perform public.set_authorization_status(v_auth, 'Submitted',
    'ZQ the second claim went out, so it is submitted again');
  perform public.record_payment(v_auth, public.practice_today(), 100.00, 'FZZ0002', 'ZZAW0000002');
  select status, amount_paid into v_status, v_amount from public.invoices where id = v_inv2;
  if v_status <> 'Short-paid' then
    failures := failures || format('FAILED: $100 against $180 left the invoice %s', v_status)::text;
  elsif (select amount - amount_paid from public.invoices where id = v_inv2) <> 80.00 then
    failures := failures || 'FAILED: the difference on a short-paid invoice does not read as 80'::text;
  else
    raise notice 'ok  a short payment says Short-paid, and the difference is the arithmetic';
  end if;

  -- ── and taking it back undoes it ───────────────────────────
  select id into v_pay from public.payments where invoice_id = v_inv2 limit 1;
  perform public.remove_payment(v_pay, 'ZQ taken back to see whether the invoice notices');
  select status, amount_paid into v_status, v_amount from public.invoices where id = v_inv2;
  if v_status <> 'Submitted' or v_amount is not null then
    failures := failures || format('FAILED: taking the payment back left the invoice %s with %s paid',
                                   v_status, coalesce(v_amount::text, 'nothing'))::text;
  else
    raise notice 'ok  taking a payment back puts its invoice back to Submitted';
  end if;

  -- ── a coaching parent is not what gets invoiced ───────────
  insert into public.authorizations
    (client_id, number, service_type, rate_type, rate, total_hours, status, start_date, end_date)
  values (v_client, 'V0000904', 'Job Coaching', 'Hourly', 45, 40, 'Due',
          public.practice_today() - 90, public.practice_today() + 90)
  returning id into v_auth2;
  -- Logging an hour against it opens the month, which is what makes it a parent.
  insert into public.service_entries (auth_id, date, hours, notes, staff_id)
  values (v_auth2, public.practice_today() - 7, 2.00, 'ZQ coaching hour', v_admin);
  if not exists (select 1 from public.authorizations where parent_id = v_auth2) then
    failures := failures || 'FAILED: logging coaching hours did not open a month'::text;
  else
    begin
      perform public.submit_invoice(v_auth2);
      failures := failures || 'FAILED: a coaching parent was invoiced'::text;
    exception when check_violation then
      raise notice 'ok  a coaching parent is not invoiced; its months are';
    end;
    -- And the month is invoiceable, at the hours logged on it. The call is
    -- made into a variable rather than inside the comparison: submit_invoice
    -- writes a row, and a scalar subquery around it can be evaluated more
    -- than once - which is how the second call hit its own "already
    -- outstanding" guard and failed this case.
    select id into v_inv from public.authorizations where parent_id = v_auth2;
    v_inv := public.submit_invoice(v_inv);
    if (select amount from public.invoices where id = v_inv) <> 90.00 then
      failures := failures || 'FAILED: the coaching month did not invoice its own two hours'::text;
    else
      raise notice 'ok  and the month invoices the hours that were logged on it';
    end if;
  end if;

  -- ── two claims outstanding: no guessing ────────────────────
  insert into public.authorizations
    (client_id, number, service_type, rate_type, rate, status, start_date, end_date)
  values (v_client, 'V0000902', 'Job Development', 'Flat Fee', 560, 'Due',
          public.practice_today() - 90, public.practice_today() + 90)
  returning id into v_auth2;

  insert into public.invoices (client_id, auth_id, submitted_on, submitted_by, amount, source)
  values (v_client, v_auth2, public.practice_today() - 40, v_admin, 560, 'Backfill'),
         (v_client, v_auth2, public.practice_today() - 10, v_admin, 560, 'Backfill');

  perform public.record_payment(v_auth2, public.practice_today(), 560.00, 'FZZ0003', 'ZZAW0000003');
  if (select count(*) from public.payments where auth_id = v_auth2 and invoice_id is not null) <> 0 then
    failures := failures || 'FAILED: a payment picked one of two outstanding claims to answer'::text;
  else
    raise notice 'ok  with two claims outstanding a payment waits to be told which it answers';
  end if;

  -- ── chasing, at thirty and at forty-five ──────────────────
  -- The older of the two invoices on V0000902 is forty days old, so it is
  -- chased at the intake desk and not yet escalated. One day short of each
  -- threshold raises nothing.
  select count(*) into v_n from public.chase_invoices(public.practice_today() - 11);
  if v_n <> 0 then
    failures := failures || format('FAILED: %s chase(s) at twenty-nine days', v_n)::text;
  else
    raise notice 'ok  nothing is chased at twenty-nine days';
  end if;

  if (select count(*) from public.chase_invoices(public.practice_today())) = 0 then
    failures := failures || 'FAILED: a forty-day-old invoice was not chased'::text;
  elsif (select count(*) from public.tasks
          where source_kind = 'invoice_unpaid_45' and status = 'Open') <> 0 then
    failures := failures || 'FAILED: a forty-day-old invoice was escalated before forty-five days'::text;
  else
    raise notice 'ok  thirty days raises it at the intake desk and not above';
  end if;

  perform public.chase_invoices(public.practice_today() + 5);
  if (select count(*) from public.tasks
       where source_kind = 'invoice_unpaid_45' and status = 'Open') = 0 then
    failures := failures || 'FAILED: forty-five days did not reach the owner'::text;
  else
    raise notice 'ok  forty-five days reaches the owner, and the earlier one stays';
  end if;

  -- ── a short payment can be queried ────────────────────
  -- The half Phase 3 left out: the chase raised a short payment every night
  -- for ever, because nothing could tell it the conversation had happened.
  --
  -- Measured on the item rather than on what chase_invoices returned.
  -- notify_person returns nothing when neither the bell nor My day had
  -- anything new, so a second call over the same invoice is silent whatever
  -- the rule says - counting its rows would have passed a rule that does
  -- nothing, and the first version of this case did exactly that.
  insert into public.authorizations
    (client_id, number, service_type, rate_type, rate, status, submitted_on, start_date, end_date)
  values (v_client, 'V0000905', 'Job Development', 'Flat Fee', 560, 'Submitted',
          public.practice_today() - 3, public.practice_today() - 90, public.practice_today() + 90)
  returning id into v_auth3;

  insert into public.invoices (client_id, auth_id, submitted_on, submitted_by, amount, source)
  values (v_client, v_auth3, public.practice_today() - 3, v_admin, 560, 'Backfill')
  returning id into v_inv3;

  perform public.record_payment(v_auth3, public.practice_today(), 400.00, 'FZZ0004', 'ZZAW0000004');
  perform public.chase_invoices(public.practice_today());

  select count(*) into v_n from public.tasks
   where source_kind = 'invoice_short_paid' and source_ref = v_inv3 and status = 'Open';
  if (select status from public.invoices where id = v_inv3) <> 'Short-paid' then
    failures := failures || 'FAILED: $400 against $560 did not read as short-paid'::text;
  elsif v_n = 0 then
    failures := failures || 'FAILED: a short payment was not raised at all'::text;
  else
    raise notice 'ok  a short payment is raised the day it happens';
  end if;

  -- A call with no answer yet changes nothing. It is a note, not a decision.
  v_q := public.record_invoice_query(v_inv3, 'ZQ Downtown billing', 'ZQ they are looking into it');
  if not exists (select 1 from public.tasks
                  where source_kind = 'invoice_short_paid' and source_ref = v_inv3 and status = 'Open') then
    failures := failures || 'FAILED: an unsettled note took the short payment off the list'::text;
  else
    raise notice 'ok  a note that settles nothing leaves the short payment on the list';
  end if;

  -- And one that closes the question has to carry the answer.
  begin
    perform public.record_invoice_query(v_inv3, 'ZQ Downtown billing', null, true);
    failures := failures || 'FAILED: a note closed the question without saying what settled it'::text;
  exception when check_violation then
    raise notice 'ok  a note that closes the question has to say what settled it';
  end;

  v_q := public.record_invoice_query(v_inv3, 'ZQ Downtown billing',
    'ZQ the difference was a rate correction and will not be paid', true);
  -- Settled: the item goes, the bell goes, and the next sweep does not bring
  -- either back.
  perform public.chase_invoices(public.practice_today());
  if exists (select 1 from public.tasks
              where source_kind = 'invoice_short_paid' and source_ref = v_inv3 and status = 'Open') then
    failures := failures || 'FAILED: a settled short payment is still on somebody''s list'::text;
  elsif exists (select 1 from public.notifications
                 where dedupe_key = 'invoice_short_paid:' || v_inv3::text) then
    failures := failures || 'FAILED: the bell still rings for a settled short payment'::text;
  else
    raise notice 'ok  and a settled one comes off the list and stays off';
  end if;

  -- ── settling a query does not settle a debt ───────────
  -- The forty-day-old invoice on V0000902 is unpaid rather than short-paid.
  -- A note saying somebody was spoken to does not take money owed off the
  -- list, and that is the distinction the whole rule turns on.
  select id into v_inv from public.invoices where auth_id = v_auth2 order by submitted_on limit 1;
  perform public.record_invoice_query(v_inv, 'ZQ Downtown billing',
    'ZQ they say it is in the next batch', true);
  if not exists (select 1 from public.tasks
                  where source_kind = 'invoice_unpaid' and source_ref = v_inv and status = 'Open') then
    failures := failures || 'FAILED: a resolved note cleared the chase on money still owed'::text;
  else
    raise notice 'ok  a resolved note does not stop the chase on money still owed';
  end if;

  -- ── and a note is never rewritten ─────────────────
  begin
    update public.invoice_queries set said = 'ZQ something else' where id = v_q;
    failures := failures || 'FAILED: a note about a query was rewritten'::text;
  exception when check_violation or insufficient_privilege then
    begin
      delete from public.invoice_queries where id = v_q;
      failures := failures || 'FAILED: a note about a query was deleted'::text;
    exception when check_violation or insufficient_privilege then
      raise notice 'ok  a note is never changed or removed - the next note says what changed';
    end;
  end;

  -- ── work logged and not invoiced ──────────────────────────
  insert into public.authorizations
    (client_id, number, service_type, rate_type, rate, total_hours, status, start_date, end_date)
  values (v_client, 'V0000903', 'Job Coaching', 'Hourly', 45, 20, 'Due',
          public.practice_today() - 120, public.practice_today() + 90)
  returning id into v_auth2;
  insert into public.service_entries (auth_id, date, hours, notes, staff_id)
  values (v_auth2, date_trunc('month', public.practice_today() - 40)::date + 3, 2.00, 'ZQ unbilled', v_admin);

  -- The 4th of the month after that work: not yet due.
  select count(*) into v_n from public.invoices_due(
    (date_trunc('month', public.practice_today() - 40) + interval '1 month' + interval '3 days')::date);
  if v_n <> 0 then
    failures := failures || format('FAILED: %s invoice(s) called due on the 4th', v_n)::text;
  else
    raise notice 'ok  work logged last month is not late on the 4th';
  end if;

  select count(*) into v_n from public.invoices_due(
    (date_trunc('month', public.practice_today() - 40) + interval '1 month' + interval '4 days')::date);
  if v_n = 0 then
    failures := failures || 'FAILED: work logged and not invoiced was not raised on the 5th'::text;
  else
    raise notice 'ok  and it is late on the 5th, for the person carrying the client and the intake desk';
  end if;

  -- ── the live ledger agrees with itself ────────────────────
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  -- The practice's own ledger, not this script's fixtures. Everything above
  -- created clients, authorizations and payments inside this transaction, and
  -- a check that counts its own fixtures is measuring itself - including one
  -- payment left deliberately unanswered to prove a payment does not guess.
  select count(*) into v_n
    from public.authorizations a
    join public.clients c on c.id = a.client_id
   where not public.is_fixture_name(c.name)
     and (select coalesce(sum(i.amount_paid), 0) from public.invoices i where i.auth_id = a.id)
         <> (select coalesce(sum(p.amount), 0) from public.payments p
              where p.auth_id = a.id and p.invoice_id is not null);
  if v_n <> 0 then
    failures := failures || format('FAILED: %s authorization(s) whose invoices disagree with the payments on them', v_n)::text;
  else
    raise notice 'ok  every authorization''s invoices agree with the payments pointed at them';
  end if;

  -- Where an invoice says what it was for, that is what it was for. The five
  -- still owed carry the days off their USOR forms; the 156 backfilled from
  -- the warrant index carry none, because the stub that paid them says what
  -- was paid and not which days were worked. Counting the fixtures too: an
  -- invoice Submit raised is lines by construction, and this is the assertion
  -- that would notice if it stopped being.
  select count(*) into v_n
    from public.invoices i
   where exists (select 1 from public.invoice_lines l where l.invoice_id = i.id)
     and (select coalesce(sum(l.amount), 0) from public.invoice_lines l where l.invoice_id = i.id)
         <> coalesce(i.amount, 0);
  if v_n <> 0 then
    failures := failures || format('FAILED: %s invoice(s) whose lines do not come to what was invoiced', v_n)::text;
  else
    raise notice 'ok  where an invoice has lines, they come to what was invoiced';
  end if;

  -- Every payment that names a warrant answers an invoice. The one that names
  -- none is the 26 October entry whose warrant is not on file: the owner ruled
  -- on 6 November that it was paid and the stub has not arrived, so it stays,
  -- on the Billing list that 0311 reads, until reconciliation matches it. This
  -- check asks about payments that name a warrant, so it does not excuse that
  -- one - it is not one of them.
  select count(*) into v_n
    from public.payments p
    join public.authorizations a on a.id = p.auth_id
    join public.clients c on c.id = a.client_id
   where p.invoice_id is null and coalesce(btrim(p.warrant_no), '') <> ''
     and not public.is_fixture_name(c.name);
  if v_n <> 0 then
    failures := failures || format('FAILED: %s payment(s) name a warrant and no invoice', v_n)::text;
  else
    raise notice 'ok  every payment that names a warrant is on an invoice';
  end if;

  -- ── and none of it is reachable signed out ────────────────
  if has_table_privilege('anon', 'public.invoices', 'select')
     or has_table_privilege('anon', 'public.invoice_lines', 'select')
     or has_table_privilege('anon', 'public.invoice_queries', 'select')
     or has_function_privilege('anon', 'public.record_invoice_query(uuid, text, text, boolean, date)', 'execute')
     or has_function_privilege('anon', 'public.submit_invoice(uuid, uuid, uuid, numeric)', 'execute')
     or has_function_privilege('authenticated', 'public.raise_invoice(uuid, uuid, uuid, numeric, uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.chase_invoices(date)', 'execute') then
    failures := failures || 'FAILED: something about invoices is reachable by somebody who should not reach it'::text;
  else
    raise notice 'ok  signed out reaches none of it, and the inner function is nobody''s to call';
  end if;

  if has_table_privilege('authenticated', 'public.invoices', 'insert')
     or has_table_privilege('authenticated', 'public.invoices', 'update')
     or has_table_privilege('authenticated', 'public.invoices', 'delete')
     or has_table_privilege('authenticated', 'public.invoice_queries', 'insert')
     or has_table_privilege('authenticated', 'public.invoice_queries', 'update')
     or has_table_privilege('authenticated', 'public.invoice_queries', 'delete') then
    failures := failures || 'FAILED: the invoice ledger can be written to without going through a function'::text;
  else
    raise notice 'ok  the ledger is only written through the functions that say who did it';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
