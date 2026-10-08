-- Zion Vocational Rehab CRM — warrants reconciled against what was billed
--
-- What has to hold, each tried from the direction that would break it:
--
--   A warrant line becomes a payment only when the page proves it: both
--   copies of the V-number agree, the lines add up to the page total, the
--   warrant number and date were read, and the V-number is an authorization on
--   file with its exact suffix. Anything else waits for review, paying nothing.
--
--   A line the workbook already recorded (same warrant, authorization, amount)
--   is linked to that payment and never paid twice, however often it is run.
--
--   A validated line pays the unpaid invoice for that amount, or creates one
--   marked as reconciled from the warrant. An invoice over what the
--   authorization allows is not created; the line waits with the reason.
--
--   By hand, only Admin and Billing record or set aside a line. Nobody writes
--   payments directly. An invoice marked Paid by hand records its payment, and
--   un-paying it takes that payment back.
--
--   The position view counts received as what a warrant actually paid and
--   outstanding as what is submitted and not yet paid - the owner's definitions,
--   14 Sept 2026 - so an invoice still in Draft is invoiced but not outstanding.
--
-- Runs inside a transaction that is rolled back. Nothing here is left behind.

begin;

do $$
declare
  v_admin   uuid;
  v_adm_uid uuid;
  v_js      uuid;
  v_js_uid  uuid;
  v_client  uuid;
  v_auth1   uuid;
  v_auth2a  uuid;
  v_auth2   uuid;
  v_wb_inv  uuid;
  v_wb_pay  uuid;
  v_draft   uuid;
  v_doc     uuid;
  v_p1      uuid;
  v_p2      uuid;
  v_p3      uuid;
  v_p4      uuid;
  v_l1      uuid;
  v_l2      uuid;
  v_l3      uuid;
  v_l31     uuid;
  v_l32     uuid;
  v_l33     uuid;
  v_hand    uuid;
  v_count   int;
  r         record;
  failures  text[] := '{}';
begin
  select id, user_id into v_admin, v_adm_uid from public.staff where role = 'Admin' and active order by created_at limit 1;
  select id, user_id into v_js, v_js_uid from public.staff where active and role = 'Job Search' order by created_at limit 1;

  -- ── the workbook's payments came across ────────────────────
  -- The payment hangs off the authorization now, not off an invoice (§10).
  if exists (select 1 from public.authorizations a
              where a.status = 'Paid' and coalesce(a.paid_amount, 0) > 0
                and not exists (select 1 from public.payments p where p.auth_id = a.id)) then
    failures := failures || 'FAILED: a paid authorization has no payment on record'::text;
  else
    raise notice 'ok  every paid authorization on file has its payment on record';
  end if;

  insert into public.clients (name, stage, status, assigned_staff_id)
  values ('ZZ Warrant Client', 'Job Coaching', 'Active', v_admin) returning id into v_client;

  insert into public.authorizations (client_id, number, service_type, rate_type, rate, status)
  values (v_client, 'ZQ9600001', 'Job Placement', 'Flat Fee', 560, 'Authorized') returning id into v_auth1;
  insert into public.authorizations (client_id, number, service_type, rate_type, rate, total_hours, status)
  values (v_client, 'ZQ9600002A', 'Job Coaching', 'Hourly', 45, 20, 'Authorized') returning id into v_auth2a;
  -- A different rate, so the two lines below pay different amounts and the
  -- suffix is the only thing that can be routing them.
  insert into public.authorizations (client_id, number, service_type, rate_type, rate, total_hours, status)
  values (v_client, 'ZQ9600002', 'Job Coaching', 'Hourly', 44, 20, 'Authorized') returning id into v_auth2;

  -- §13.9 pays a line only when the authorization has been submitted and the
  -- line is for what it comes to. Ten hours each: 450 and 440.
  insert into public.service_entries (auth_id, date, hours)
  values (v_auth2a, date '2026-01-05', 10), (v_auth2, date '2026-01-05', 10);
  insert into public.forms (template_id, client_id, auth_id, status, data)
  select t.id, v_client, a.id, 'Completed', '{}'::jsonb
    from public.form_templates t
   cross join (select v_auth2a as id union all select v_auth2) a
   where t.required_for_billing and 'Job Coaching' = any (t.services);
  -- The hours landed on the month they were worked (0171), and the month is
  -- the bill (§5) - so it is the months that are submitted, and a coaching
  -- warrant line resolves to the month it paid (0174).
  update public.authorizations set status = 'Due'
   where parent_id in (v_auth2a, v_auth2);
  update public.authorizations
     set status = 'Submitted', submitted_on = date '2026-01-02', recipient = 'ZZ USOR'
   where parent_id in (v_auth2a, v_auth2);

  -- What the workbook recorded: one payment on warrant ZW0000001, against the
  -- authorization itself.
  perform set_config('zion.reconciling', 'on', true);
  -- Through the flow, not around it: Due, submitted, then paid.
  update public.authorizations set status = 'Due' where id = v_auth1;
  -- A completion row is opened for every flat fee by a trigger, so this sets
  -- the date on the one that is already there.
  update public.completions
     set start_date = date '2025-12-01', completion = date '2026-01-01'
   where auth_id = v_auth1;
  update public.authorizations
     set status = 'Submitted', submitted_on = date '2026-01-02', recipient = 'ZZ USOR'
   where id = v_auth1;
  update public.authorizations
     set status = 'Paid', paid_on = date '2026-01-15', paid_amount = 560, warrant = 'ZW0000001'
   where id = v_auth1;
  insert into public.payments (auth_id, amount, warrant_no, warrant_date, voucher, source, recorded_by_name)
  values (v_auth1, 560, 'ZW0000001', date '2026-01-15', '26PR00000000001', 'Workbook', 'Workbook import')
  returning id into v_wb_pay;
  perform set_config('zion.reconciling', '', true);

  insert into public.warrant_documents (sha256, filename, page_count)
  values (repeat('e', 64), 'paid_invoices.pdf', 4) returning id into v_doc;

  insert into public.warrant_pages (document_id, page_no, warrant_no, warrant_date, total)
  values (v_doc, 1, 'ZW0000001', date '2026-01-15', 1450.00) returning id into v_p1;
  insert into public.warrant_lines (page_id, line_no, voucher, invoice_ref, described_ref, amount)
  values (v_p1, 1, '26PR00000000001', 'ZQ9600001', 'ZQ9600001', 560) returning id into v_l1;
  -- As the real stubs print it: the suffix before the slash only.
  insert into public.warrant_lines (page_id, line_no, voucher, invoice_ref, described_ref, amount)
  values (v_p1, 2, '26PR00000000002', 'ZQ9600002A', 'ZQ9600002', 450) returning id into v_l2;
  insert into public.warrant_lines (page_id, line_no, voucher, invoice_ref, described_ref, amount, service_date)
  values (v_p1, 3, '26PR00000000003', 'ZQ9600002', 'ZQ9600002', 440, date '2026-01-05') returning id into v_l3;

  -- The lines add up to 90; the page says 100.
  insert into public.warrant_pages (document_id, page_no, warrant_no, warrant_date, total)
  values (v_doc, 2, 'ZW0000002', date '2026-02-15', 100.00) returning id into v_p2;
  insert into public.warrant_lines (page_id, line_no, invoice_ref, described_ref, amount)
  values (v_p2, 1, 'ZQ9600002A', 'ZQ9600002A', 90);

  -- A page that adds up, with three lines that must not be paid as read.
  insert into public.warrant_pages (document_id, page_no, warrant_no, warrant_date, total)
  values (v_doc, 3, 'ZW0000003', date '2026-03-15', 100.00) returning id into v_p3;
  insert into public.warrant_lines (page_id, line_no, invoice_ref, described_ref, amount)
  values (v_p3, 1, 'ZQ9600001', 'ZQ9600009', 50) returning id into v_l31;
  insert into public.warrant_lines (page_id, line_no, invoice_ref, described_ref, amount)
  values (v_p3, 2, 'ZQ9699999', 'ZQ9699999', 30) returning id into v_l32;
  insert into public.warrant_lines (page_id, line_no, invoice_ref, described_ref, amount)
  values (v_p3, 3, 'ZQ9600002B', 'ZQ9600002B', 20) returning id into v_l33;

  -- More than the authorization allows.
  insert into public.warrant_pages (document_id, page_no, warrant_no, warrant_date, total)
  values (v_doc, 4, 'ZW0000004', date '2026-04-15', 9999.00) returning id into v_p4;
  insert into public.warrant_lines (page_id, line_no, invoice_ref, described_ref, amount)
  values (v_p4, 1, 'ZQ9600001', 'ZQ9600001', 9999);

  -- ── nobody else writes it ──────────────────────────────────
  if has_function_privilege('anon', 'public.reconcile_warrant_line(uuid, boolean, uuid, numeric)', 'execute')
     or has_function_privilege('anon', 'public.reconcile_warrant_page(uuid)', 'execute')
     or has_function_privilege('anon', 'public.dismiss_warrant_line(uuid, text)', 'execute') then
    failures := failures || 'FAILED: an anonymous caller may reconcile or dismiss warrant lines'::text;
  elsif has_table_privilege('authenticated', 'public.payments', 'insert')
     or has_table_privilege('authenticated', 'public.payments', 'update')
     or has_table_privilege('authenticated', 'public.warrant_lines', 'update') then
    failures := failures || 'FAILED: a signed-in person could write payments or warrant lines directly'::text;
  else
    raise notice 'ok  payments and warrant lines are written only through reconciliation';
  end if;

  -- ── as the agent ───────────────────────────────────────────
  perform set_config('role', 'service_role', true);
  perform set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);

  select * into r from public.reconcile_warrant_page(v_p1);
  if r.reconciled <> 2 or r.already_recorded <> 1 or r.needs_review <> 0 then
    failures := failures || format('FAILED: page 1 should reconcile 2 and recognise 1 as recorded (got %s/%s/%s)',
                                   r.reconciled, r.already_recorded, r.needs_review);
  else
    raise notice 'ok  a page that proves itself reconciles every line';
  end if;

  if (select count(*) from public.payments where auth_id = v_auth1) <> 1
     or (select warrant_line_id from public.payments where id = v_wb_pay) is distinct from v_l1
     or (select status from public.warrant_lines where id = v_l1) <> 'Already recorded' then
    failures := failures || 'FAILED: a payment the workbook recorded was paid again, or not linked to its line'::text;
  else
    raise notice 'ok  a line the workbook already recorded is linked to that payment, not paid twice';
  end if;

  -- The line pays the authorization itself (§10): no invoice is marked, and
  -- none is created.
  if not exists (select 1 from public.authorizations ch
                  where ch.parent_id = v_auth2a and ch.status = 'Paid'
                    and ch.paid_on = date '2026-01-15' and ch.warrant = 'ZW0000001'
                    and ch.paid_amount = 450)
     or not exists (select 1 from public.payments p
                      join public.authorizations ch on ch.id = p.auth_id
                     where ch.parent_id = v_auth2a and p.source = 'Warrant'
                       and p.amount = 450 and p.warrant_line_id = v_l2
                       and p.voucher = '26PR00000000002') then
    failures := failures || 'FAILED: the suffixed authorization was not marked Paid with the warrant, or its payment not recorded'::text;
  else
    raise notice 'ok  a suffix printed only before the slash pays that suffixed authorization, on the warrant date';
  end if;

  if not exists (select 1 from public.authorizations ch
                  where ch.parent_id = v_auth2 and ch.status = 'Paid' and ch.paid_amount = 440) then
    failures := failures || 'FAILED: the base authorization was not paid by its own line'::text;
  elsif exists (select 1 from public.payments p join public.authorizations ch on ch.id = p.auth_id
                 where ch.parent_id = v_auth2a and p.amount = 440) then
    failures := failures || 'FAILED: a V-number with no suffix was paid onto the suffixed authorization'::text;
  else
    raise notice 'ok  a line pays the authorization its V-number names, and nothing is created to hold it';
  end if;

  perform public.reconcile_warrant_page(v_p1);
  if (select count(*) from public.payments where warrant_no = 'ZW0000001') <> 3 then
    failures := failures || 'FAILED: reconciling a page twice recorded payments twice'::text;
  else
    raise notice 'ok  reconciling the same page again records nothing more';
  end if;

  -- The same warrant again, in another file: a later scan of the same stub.
  perform set_config('role', 'postgres', true);
  insert into public.warrant_documents (sha256, filename, page_count)
  values (repeat('f', 64), 'single warrant scan.pdf', 1) returning id into v_hand;
  insert into public.warrant_pages (document_id, page_no, warrant_no, warrant_date, total)
  values (v_hand, 1, 'ZW0000001', date '2026-01-15', 1450.00) returning id into v_hand;
  insert into public.warrant_lines (page_id, line_no, invoice_ref, described_ref, amount)
  values (v_hand, 1, 'ZQ9600001', 'ZQ9600001', 560), (v_hand, 2, 'ZQ9600002A', 'ZQ9600002A', 450),
         (v_hand, 3, 'ZQ9600002', 'ZQ9600002', 440);
  perform set_config('role', 'service_role', true);

  select * into r from public.reconcile_warrant_page(v_hand);
  if r.already_recorded <> 3 or r.reconciled <> 0
     or (select count(*) from public.payments where warrant_no = 'ZW0000001') <> 3
     or (select count(*) from public.payments p join public.authorizations ch on ch.id = p.auth_id
          where ch.parent_id = v_auth2) <> 1 then
    failures := failures || format('FAILED: a second copy of a warrant paid its lines again (%s reconciled, %s recorded)',
                                   r.reconciled, r.already_recorded);
  else
    raise notice 'ok  a second copy of the same warrant in another file pays nothing twice';
  end if;
  v_hand := null;

  perform public.reconcile_warrant_page(v_p2);
  if (select status from public.warrant_pages where id = v_p2) <> 'Needs review'
     or not exists (select 1 from public.warrant_lines where page_id = v_p2 and problem like '%add up to 90.00%100.00%')
     or exists (select 1 from public.payments where warrant_no = 'ZW0000002') then
    failures := failures || 'FAILED: a page whose lines do not add up to its total paid something, or did not say why'::text;
  else
    raise notice 'ok  lines that do not add up to the page total pay nothing and wait for review';
  end if;

  perform public.reconcile_warrant_page(v_p3);
  if (select problem from public.warrant_lines where id = v_l31) not like '%disagree%' then
    failures := failures || 'FAILED: two different V-number copies on a line were not caught'::text;
  elsif (select problem from public.warrant_lines where id = v_l32) not like '%not an authorization on file%' then
    failures := failures || 'FAILED: a V-number not on file was not sent for review'::text;
  elsif (select problem from public.warrant_lines where id = v_l33) not like '%ZQ9600002B%not an authorization%'
     or exists (select 1 from public.payments where warrant_no = 'ZW0000003') then
    failures := failures || 'FAILED: a suffix not on file was matched to the base authorization'::text;
  else
    raise notice 'ok  disagreeing copies, a number not on file, and a suffix not on file each wait for review';
  end if;

  perform public.reconcile_warrant_page(v_p4);
  if not exists (select 1 from public.warrant_lines where page_id = v_p4 and status = 'Needs review'
                   and problem like '%does not match that payment%')
     or exists (select 1 from public.payments where auth_id = v_auth1 and amount = 9999) then
    failures := failures || 'FAILED: a line for an amount nobody can account for was recorded, or did not say why'::text;
  else
    raise notice 'ok  a line that does not match what was paid creates nothing and waits with the reason';
  end if;

  -- ── who ────────────────────────────────────────────────────
  if v_js is not null then
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', v_js_uid, 'role', 'authenticated')::text, true);
    if exists (select 1 from public.warrant_pages where id = v_p3) then
      failures := failures || 'FAILED: Job Search can read warrant pages'::text;
    end if;
    begin
      perform public.reconcile_warrant_line(v_l32, true, v_auth2a, 30);
      failures := failures || 'FAILED: Job Search recorded a warrant line by hand'::text;
    exception when insufficient_privilege then
      raise notice 'ok  only Admin and Billing read warrants and record a line by hand';
    end;
  end if;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);

  begin
    perform public.reconcile_warrant_line(v_l32, true, null, 30);
    failures := failures || 'FAILED: a line was recorded by hand without saying which authorization'::text;
  exception when check_violation then
    raise notice 'ok  recording by hand needs the authorization';
  end;

  -- Called on its own: a check in the same statement would not see the rows it writes.
  r := null;
  select public.reconcile_warrant_line(v_l32, true, v_auth2a, 30) as status into r;
  if r.status <> 'Resolved by hand'
     or not exists (select 1 from public.payments where warrant_line_id = v_l32 and source = 'By hand'
                      and auth_id = v_auth2a and amount = 30 and recorded_by = v_admin)
     or (select decided_by from public.warrant_lines where id = v_l32) is distinct from v_admin then
    failures := failures || 'FAILED: a line recorded by hand was not paid onto the chosen authorization, or not attributed'::text;
  else
    raise notice 'ok  a person picks the authorization from the page image, and the payment says who';
  end if;

  begin
    perform public.dismiss_warrant_line(v_l31, '  ');
    failures := failures || 'FAILED: a line was set aside without a reason'::text;
  exception when check_violation then
    raise notice 'ok  setting a line aside needs a reason';
  end;
  perform public.dismiss_warrant_line(v_l31, 'Misread: a page from another vendor');
  if (select status from public.warrant_lines where id = v_l31) <> 'Dismissed'
     or (select status from public.warrant_pages where id = v_p3) <> 'Needs review' then
    failures := failures || 'FAILED: dismissing a line did not set it aside, or cleared a page with a line still waiting'::text;
  else
    raise notice 'ok  a dismissed line is set aside, and the page waits while any line does';
  end if;

  begin
    insert into public.payments (auth_id, amount, source) values (v_auth2a, 1, 'By hand');
    failures := failures || 'FAILED: Admin wrote a payment directly'::text;
  exception when insufficient_privilege then
    raise notice 'ok  even Admin cannot write a payment except through reconciliation or an invoice';
  end;

  -- Marking something Paid by hand used to be an invoice's doing, and the
  -- invoice recorded its own payment. There is no invoice and no by-hand pay
  -- path (§10): a payment exists because a warrant line produced it, which is
  -- the assertion above. The authorization's own status is moved by the
  -- reconciliation, never typed.
  if exists (select 1 from public.authorizations a
              where a.status = 'Paid'
                and not exists (select 1 from public.payments p where p.auth_id = a.id)) then
    failures := failures || 'FAILED: something is marked Paid with no payment behind it'::text;
  else
    raise notice 'ok  nothing is Paid without a payment behind it, and payments come only from a warrant';
  end if;

  -- ── the position, returned from §10 ────────────────────────
  --
  -- This assertion was owed. It checked billing_position's figures, and every
  -- one of them came off the invoice; §1 moved the view onto the authorization
  -- and §10 moved the warrant onto it too, so the figures can be asserted
  -- again - from the record that holds them.
  --
  -- ZQ9600002A: 20 hours at 45 authorized, ten of them logged and paid on the
  -- warrant for 450.
  if (select authorized from public.billing_position where auth_id = v_auth2a) <> 900 then
    failures := failures || 'FAILED: the position has lost what the authorization authorized'::text;
  elsif (select sum(bp.paid) from public.billing_position bp
           join public.authorizations ch on ch.id = bp.auth_id
          where ch.parent_id = v_auth2a) <> 450 then
    failures := failures || format('FAILED: the position has paid %s on a 450 warrant payment',
                                   (select sum(bp.paid) from public.billing_position bp
                                      join public.authorizations ch on ch.id = bp.auth_id
                                     where ch.parent_id = v_auth2a));
  elsif (select coalesce(sum(bp.outstanding), 0) from public.billing_position bp
           join public.authorizations ch on ch.id = bp.auth_id
          where ch.parent_id = v_auth2a) <> 0 then
    failures := failures || format('FAILED: a paid authorization is still outstanding for %s',
                                   (select coalesce(sum(bp.outstanding), 0) from public.billing_position bp
                                      join public.authorizations ch on ch.id = bp.auth_id
                                     where ch.parent_id = v_auth2a));
  else
    raise notice 'ok  the position reads what was authorized, what came in on the warrant, and nothing still owed';
  end if;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  if failures = '{}' then
    raise notice '';
    raise notice '--- WARRANT RECONCILIATION VERIFIED ---';
  else
    raise notice '';
    raise notice '%  PROBLEM(S):', array_length(failures, 1);
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
