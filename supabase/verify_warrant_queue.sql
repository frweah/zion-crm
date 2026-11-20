-- Zion Vocational Rehab CRM — Needs review asks the record (0376)
--
-- Owner, 19 November 2026, on Admin → Warrants › Needs review: "(1) collapse
-- repeated scans of the same stub to one line; (2) a line whose authorization
-- and amount match a recorded payment exactly is auto-accepted as 'matches
-- payment on record' and leaves the queue - nothing new is written, the line
-- is just no longer a question; (3) a claim letter matches against its base
-- authorization's payments; (4) what remains is the real queue, with the
-- reason each line is there."
--
-- What has to hold:
--
--   two scans of one stub come back as one line, saying it was read twice;
--
--   a line the record accounts for is settled, names the payment that
--   accounts for it, and is asked nothing;
--
--   a claim letter is matched against its base authorization's payments;
--
--   one payment answers for one line, so a second line wanting the same
--   figure is still a question;
--
--   two lines on one page for the same authorization stay two lines;
--
--   a line whose scans read different amounts says both figures rather than
--   picking one;
--
--   nothing is written - the lines keep their status and no payment is made -
--   so taking the payment back makes its line a question again;
--
--   and the queue is Admin's.
--
-- Made-up people (ZZ). Everything is rolled back.

begin;

do $$
declare
  v_admin     uuid;
  v_admin_uid uuid := gen_random_uuid();
  v_bill      uuid;
  v_bill_uid  uuid := gen_random_uuid();
  v_client    uuid;
  v_a uuid; v_b uuid; v_c uuid; v_d uuid; v_e uuid;
  v_doc1 uuid; v_doc2 uuid; v_doc3 uuid;
  v_p1 uuid; v_p2 uuid; v_p3 uuid;
  v_pay_a uuid;
  v_warrant text := 'F99000881';
  v_when    date := public.practice_today() - 7;
  n         integer;
  r         record;
  v_text    text;
  failures  text[] := '{}';
begin
  -- ═══ the practice ══════════════════════════════════════════
  insert into public.staff (name, email, role, active)
  values ('ZZ Queue Admin', 'zz-queue-admin@example.test', 'Admin', true) returning id into v_admin;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_admin_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-queue-admin@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_admin_uid where id = v_admin;

  insert into public.staff (name, email, role, active)
  values ('ZZ Queue Billing', 'zz-queue-billing@example.test', 'Billing', true) returning id into v_bill;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_bill_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-queue-billing@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_bill_uid where id = v_bill;

  insert into public.clients (name, stage, status, assigned_staff_id)
  values ('ZZ Queued Person', 'Job Search', 'Active', v_admin) returning id into v_client;

  -- Five submitted authorizations. The numbers are V-numbers because the
  -- claim-letter rule reads one.
  insert into public.authorizations
    (client_id, number, service_type, rate_type, rate, status, start_date, end_date, submitted_on, submitted_by)
  values (v_client, 'V0007601', 'WSA Tier 2',      'Flat Fee', 585, 'Submitted',
          public.practice_today() - 90, public.practice_today() + 30, public.practice_today() - 20, v_admin)
  returning id into v_a;
  insert into public.authorizations
    (client_id, number, service_type, rate_type, rate, status, start_date, end_date, submitted_on, submitted_by)
  values (v_client, 'V0007602', 'Job Development', 'Flat Fee', 560, 'Submitted',
          public.practice_today() - 90, public.practice_today() + 30, public.practice_today() - 20, v_admin)
  returning id into v_b;
  insert into public.authorizations
    (client_id, number, service_type, rate_type, rate, status, start_date, end_date, submitted_on, submitted_by)
  values (v_client, 'V0007603', 'Job Development', 'Flat Fee', 900, 'Submitted',
          public.practice_today() - 90, public.practice_today() + 30, public.practice_today() - 20, v_admin)
  returning id into v_c;
  insert into public.authorizations
    (client_id, number, service_type, rate_type, rate, status, start_date, end_date, submitted_on, submitted_by)
  values (v_client, 'V0007604', 'WSA Tier 1',      'Flat Fee', 450, 'Submitted',
          public.practice_today() - 90, public.practice_today() + 30, public.practice_today() - 20, v_admin)
  returning id into v_d;
  insert into public.authorizations
    (client_id, number, service_type, rate_type, rate, status, start_date, end_date, submitted_on, submitted_by)
  values (v_client, 'V0007605', 'WSA Tier 1',      'Flat Fee', 270, 'Submitted',
          public.practice_today() - 90, public.practice_today() + 30, public.practice_today() - 20, v_admin)
  returning id into v_e;

  -- ═══ the stub, scanned twice ═══════════════════════════════
  --
  -- One warrant, two documents: a standalone PDF and the same page inside a
  -- multi-page scan, which is how the practice's _Warrants folder actually
  -- fills up. The second scan read one amount wrong.
  insert into public.warrant_documents (sha256, filename, relative_path, page_count)
  values (repeat('b', 64), 'zz-queue-standalone.pdf', 'zz-queue-standalone.pdf', 1) returning id into v_doc1;
  insert into public.warrant_documents (sha256, filename, relative_path, page_count)
  values (repeat('c', 64), 'zz-queue-scan.pdf', 'zz-queue-scan.pdf', 9) returning id into v_doc2;
  insert into public.warrant_documents (sha256, filename, relative_path, page_count)
  values (repeat('d', 64), 'zz-queue-not-a-warrant.pdf', 'zz-queue-not-a-warrant.pdf', 1) returning id into v_doc3;

  insert into public.warrant_pages
    (document_id, page_no, image_path, ocr_text, ocr_confidence, rotation,
     warrant_no, warrant_date, total, lines_total, status, problems)
  values (v_doc1, 1, '', 'ZZ stub, clearest copy', 90, 0,
          v_warrant, v_when, 9999.00, 3245.00, 'Needs review',
          array['the lines do not add up to the total'])
  returning id into v_p1;

  insert into public.warrant_pages
    (document_id, page_no, image_path, ocr_text, ocr_confidence, rotation,
     warrant_no, warrant_date, total, lines_total, status, problems)
  values (v_doc2, 4, '', 'ZZ stub, second copy', 70, 0,
          v_warrant, v_when, 9999.00, 2145.00, 'Needs review',
          array['the lines do not add up to the total'])
  returning id into v_p2;

  insert into public.warrant_pages
    (document_id, page_no, image_path, ocr_text, ocr_confidence, rotation,
     warrant_no, warrant_date, total, lines_total, status, problems)
  values (v_doc3, 1, '', 'ZZ covering letter', 40, 0,
          '', null, null, null, 'Not a warrant', array['no warrant number']::text[])
  returning id into v_p3;

  insert into public.warrant_lines
    (page_id, line_no, raw, dept, voucher, invoice_ref, described_ref, client_code, client_name,
     amount, described_amount, status, problem)
  values
    -- the clearest copy
    (v_p1, 1, 'ZZ 6006 99AW00000007601 / V0007601 585.00',  '6006', '99AW00000007601', 'V0007601',  'V0007601', '990001', 'ZZ Queued Person', 585.00, 585.00, 'Needs review', 'The lines add up to 3245.00 and the page total is 9999.00.'),
    (v_p1, 2, 'ZZ 6006 99AW00000007602 / V0007602 560.00',  '6006', '99AW00000007602', 'V0007602',  'V0007602', '990002', 'ZZ Queued Person', 560.00, 560.00, 'Needs review', 'The lines add up to 3245.00 and the page total is 9999.00.'),
    (v_p1, 3, 'ZZ 6006 99AW00000007603 / V0007603A 900.00', '6006', '99AW00000007603', 'V0007603A', 'V0007603', '990003', 'ZZ Queued Person', 900.00, 900.00, 'Needs review', 'The lines add up to 3245.00 and the page total is 9999.00.'),
    (v_p1, 4, 'ZZ 6006 99AW00000007604 / V0007604 450.00',  '6006', '99AW00000007604', 'V0007604',  'V0007604', '990004', 'ZZ Queued Person', 450.00, 450.00, 'Needs review', 'The lines add up to 3245.00 and the page total is 9999.00.'),
    (v_p1, 5, 'ZZ 6006 99AW00000007614 / V0007604 450.00',  '6006', '99AW00000007614', 'V0007604',  'V0007604', '990004', 'ZZ Queued Person', 450.00, 450.00, 'Needs review', 'The lines add up to 3245.00 and the page total is 9999.00.'),
    (v_p1, 6, 'ZZ 6006 99AW00000007605 / V0007605 300.00',  '6006', '99AW00000007605', 'V0007605',  'V0007605', '990005', 'ZZ Queued Person', 300.00, 300.00, 'Needs review', 'The lines add up to 3245.00 and the page total is 9999.00.'),
    -- the second copy: the same first two lines, one amount misread
    (v_p2, 1, 'ZZ 6006 99AW00000007601 / V0007601 585.00',  '6006', '99AW00000007601', 'V0007601',  'V0007601', '990001', 'ZZ Queued Person', 585.00, 585.00, 'Needs review', 'The lines add up to 2145.00 and the page total is 9999.00.'),
    (v_p2, 2, 'ZZ 6006 99AW00000007602 / V0007602 1560.00', '6006', '99AW00000007602', 'V0007602',  'V0007602', '990002', 'ZZ Queued Person', 1560.00, 1560.00, 'Needs review', 'The lines add up to 2145.00 and the page total is 9999.00.'),
    -- and a line on a page that is not a warrant at all
    (v_p3, 1, 'ZZ covering letter 6006 99AW00000007699 / V0007601 1.00', '6006', '99AW00000007699', 'V0007601', 'V0007601', '990001', 'ZZ Queued Person', 1.00, 1.00, 'Needs review', 'Not a warrant.');

  -- ═══ the money already on the record ═══════════════════════
  --
  -- Recorded the way Billing records it, before the stub was scanned - which
  -- is the shape every one of the 95 lines this ruling is about was in.
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_admin_uid, 'role', 'authenticated')::text, true);

  v_pay_a := public.record_payment(v_a, v_when, 585,  v_warrant, null);
  perform    public.record_payment(v_c, v_when, 900,  v_warrant, null);
  perform    public.record_payment(v_d, v_when, 450,  v_warrant, null);
  perform    public.record_payment(v_e, v_when, 270,  v_warrant, null);

  -- ═══ 1. two scans, one line ════════════════════════════════
  select count(*) into n from public.warrant_review_queue() q where q.warrant_no = v_warrant;
  if n <> 6 then
    failures := failures || format('FAILED: 8 readings of 6 stub lines came back as %s row(s)', n)::text;
  else
    raise notice 'ok  two scans of one stub are one line, not two';
  end if;

  select q.readings into n from public.warrant_review_queue() q where q.ref = 'V0007601';
  if coalesce(n, 0) <> 2 then
    failures := failures || format('FAILED: the line both scans read says it was read %s time(s)', coalesce(n::text, 'no'))::text;
  else
    raise notice 'ok  and it says it was read twice, naming both scans';
  end if;

  -- A line on a page that is not a warrant is not a question about a warrant.
  if exists (select 1 from public.warrant_review_queue() q where q.warrant_no = '') then
    failures := failures || 'FAILED: a line on a page marked "Not a warrant" is in the queue'::text;
  else
    raise notice 'ok  a page that is not a warrant asks nothing';
  end if;

  -- ═══ 2. the record settles it ══════════════════════════════
  select * into r from public.warrant_review_queue() q where q.ref = 'V0007601';
  if not r.settled then
    failures := failures || format('FAILED: a line for money already recorded is still a question: %s', r.why)::text;
  elsif r.payment_id <> v_pay_a then
    failures := failures || 'FAILED: a settled line does not name the payment that settles it'::text;
  elsif coalesce(r.why, 'x') <> '' then
    failures := failures || format('FAILED: a settled line is asked "%s"', r.why)::text;
  else
    raise notice 'ok  a line the record accounts for is settled, and names the payment';
  end if;

  -- ═══ 3. a claim letter is the base authorization ═══════════
  select * into r from public.warrant_review_queue() q where q.ref = 'V0007603A';
  if r.auth_id is distinct from v_c then
    failures := failures || 'FAILED: a claim letter was not matched to its base authorization'::text;
  elsif r.claim is distinct from 'A' then
    failures := failures || format('FAILED: the claim letter reads %s', coalesce(r.claim, 'nothing'))::text;
  elsif not r.settled then
    failures := failures || format('FAILED: a claim letter against a paid base is still a question: %s', r.why)::text;
  else
    raise notice 'ok  a claim letter matches its base authorization''s payments';
  end if;

  -- ═══ 4. one payment answers for one line ═══════════════════
  select count(*) into n from public.warrant_review_queue() q
   where q.ref = 'V0007604' and q.settled;
  if n <> 1 then
    failures := failures || format('FAILED: one payment of 450.00 settled %s line(s)', n)::text;
  else
    raise notice 'ok  one payment answers for one line, and not for the next one';
  end if;

  select count(*) into n from public.warrant_review_queue() q where q.ref = 'V0007604';
  if n <> 2 then
    failures := failures || format('FAILED: two lines on one page for the same authorization came back as %s', n)::text;
  else
    raise notice 'ok  and two lines on one page stay two lines';
  end if;

  select q.why into v_text from public.warrant_review_queue() q
   where q.ref = 'V0007604' and not q.settled;
  if v_text not like '%already answers for another line%' then
    failures := failures || format('FAILED: the second line for one payment is asked "%s"', v_text)::text;
  else
    raise notice 'ok  with the reason: a payment that has already answered for a line';
  end if;

  -- ═══ 5. the scans disagree, and it says both ═══════════════
  select * into r from public.warrant_review_queue() q where q.ref = 'V0007602';
  if r.settled then
    failures := failures || 'FAILED: a line whose two scans read different amounts was settled anyway'::text;
  elsif r.amount is not null then
    failures := failures || format('FAILED: a disputed amount reads as %s', r.amount)::text;
  elsif r.why not like '%$560.00%' or r.why not like '%$1,560.00%' then
    failures := failures || format('FAILED: the two figures read are not both named: "%s"', r.why)::text;
  else
    raise notice 'ok  a line two scans disagree about says both figures and settles neither';
  end if;

  -- ═══ 6. and the record holding another figure ══════════════
  select q.why into v_text from public.warrant_review_queue() q where q.ref = 'V0007605';
  if v_text not like '%holds $270.00%' or v_text not like '%pays $300.00%' then
    failures := failures || format('FAILED: a line the record disagrees with is asked "%s"', v_text)::text;
  else
    raise notice 'ok  a line the record disagrees with names both figures';
  end if;

  -- ═══ 7. nothing was written ════════════════════════════════
  --
  -- The point of the ruling: a settled line is not a decision somebody has to
  -- make and unmake, it is the record answering. So the lines still say what
  -- the reader concluded, and asking the queue made no payment.
  select count(*) into n from public.warrant_lines l
    join public.warrant_pages p on p.id = l.page_id
   where p.warrant_no = v_warrant and l.status <> 'Needs review';
  if n <> 0 then
    failures := failures || format('FAILED: asking the queue changed %s line(s)', n)::text;
  else
    raise notice 'ok  asking the queue writes nothing: every line still reads as the reader left it';
  end if;

  select count(*) into n from public.payments p
   where p.auth_id in (v_a, v_b, v_c, v_d, v_e);
  if n <> 4 then
    failures := failures || format('FAILED: four payments were recorded and the ledger holds %s', n)::text;
  else
    raise notice 'ok  and makes no payment';
  end if;

  -- ═══ 8. take the payment back and it is a question again ═══
  perform public.remove_payment(v_pay_a, 'ZZ verify: the warrant paid somebody else.');
  select * into r from public.warrant_review_queue() q where q.ref = 'V0007601';
  if r.settled then
    failures := failures || 'FAILED: a line stayed settled after its payment was taken back'::text;
  elsif r.why not like '%no payment on file%' then
    failures := failures || format('FAILED: the line whose payment was taken back is asked "%s"', r.why)::text;
  else
    raise notice 'ok  take the payment back and the line is a question again';
  end if;

  -- ═══ 9. the queue is Admin's ═══════════════════════════════
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_bill_uid, 'role', 'authenticated')::text, true);
  select count(*) into n from public.warrant_review_queue();
  if n <> 0 then
    failures := failures || format('FAILED: Billing read %s row(s) of the warrant queue', n)::text;
  else
    raise notice 'ok  a warrant is Admin''s, and the queue answers nobody else';
  end if;

  perform set_config('request.jwt.claims', '', true);

  if array_length(failures, 1) > 0 then
    raise exception E'\n%', array_to_string(failures, E'\n');
  end if;
  raise notice E'\n--- NEEDS REVIEW ASKS THE RECORD ---';
end $$;

rollback;
