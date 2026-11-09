-- Zion Vocational Rehab CRM — a warrant accounts for every dollar on it (0326)
--
-- What has to hold:
--
--   A person reading the page image can add a payment line the reader did not
--   find, and correct the figures on one it read wrong. Both leave the line
--   waiting for review: supplying what the stub says is not deciding what it
--   pays, and the database still checks the V-number, the amount and the
--   duplicate rule afterwards.
--
--   `raw` is never touched. It is what the reader saw, and it is the evidence
--   that a correction was a correction.
--
--   A line that has already paid something cannot have its figures changed
--   under the payment.
--
--   The same line cannot be added twice.
--
--   And the question none of this was asking before: the money recorded
--   against a warrant number comes to that warrant's total. A stub read in
--   part leaves money the practice was paid and has not written down, and
--   warrant F15677921 is the first one in 208 that it ever happened to.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_admin uuid; v_admin_uid uuid := gen_random_uuid();
  v_other uuid; v_other_uid uuid := gen_random_uuid();
  v_client uuid; v_auth_a uuid; v_auth_b uuid;
  v_doc uuid; v_page uuid; v_line uuid; v_added uuid;
  v_text text; v_raw text; v_count integer; v_gap numeric;
  v_status text; v_lines_total numeric;
  v_warrant text := 'F99000777';
  failures text[] := '{}';
begin
  -- ── the practice ───────────────────────────────────────────
  insert into public.staff (name, email, role, active)
  values ('ZZ Warrant Admin', 'zz-warrant-admin@example.test', 'Admin', true) returning id into v_admin;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_admin_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-warrant-admin@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_admin_uid where id = v_admin;

  insert into public.staff (name, email, role, active)
  values ('ZZ Warrant Coach', 'zz-warrant-coach@example.test', 'Job Coach', true) returning id into v_other;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_other_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-warrant-coach@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_other_uid where id = v_other;

  insert into public.clients (name, stage, status, assigned_staff_id)
  values ('ZZ Warranted Person', 'Job Search', 'Active', v_admin) returning id into v_client;

  -- Two submitted authorizations, each with an invoice, which is what the
  -- amount on a line is checked against.
  insert into public.authorizations
    (client_id, number, service_type, rate_type, rate, status, start_date, end_date,
     submitted_on, submitted_by)
  values (v_client, 'V0000951', 'WSA Tier 2', 'Flat Fee', 585, 'Submitted',
          public.practice_today() - 90, public.practice_today() + 30,
          public.practice_today() - 20, v_admin)
  returning id into v_auth_a;
  insert into public.authorizations
    (client_id, number, service_type, rate_type, rate, status, start_date, end_date,
     submitted_on, submitted_by)
  values (v_client, 'V0000952', 'Job Development', 'Flat Fee', 560, 'Submitted',
          public.practice_today() - 90, public.practice_today() + 30,
          public.practice_today() - 20, v_admin)
  returning id into v_auth_b;

  -- ── a stub the reader got half of ──────────────────────────
  insert into public.warrant_documents (sha256, filename, relative_path, page_count)
  values (repeat('a', 64), 'zz-warrant.pdf', 'zz-warrant.pdf', 1) returning id into v_doc;

  insert into public.warrant_pages
    (document_id, page_no, image_path, ocr_text, ocr_confidence, rotation,
     warrant_no, warrant_date, total, lines_total, status, problems)
  values (v_doc, 1, '', 'ZZ unreadable stub', 50, 0,
          v_warrant, public.practice_today() - 2, 1145.00, 585.90, 'Needs review',
          array['line 1: could not be read whole'])
  returning id into v_page;

  insert into public.warrant_lines
    (page_id, line_no, raw, dept, voucher, invoice_ref, described_ref,
     client_code, client_name, amount, status, problem)
  values (v_page, 1, '6006 99AW00000000001 / 999001- ZZ 585.90', '6006', '',
          '', '', '', '', 585.90, 'Needs review', '')
  returning id into v_line;
  v_raw := '6006 99AW00000000001 / 999001- ZZ 585.90';

  insert into public.invoices (client_id, auth_id, number, claim, submitted_on, submitted_by, amount, source)
  values (v_client, v_auth_a, 999001, 'A', public.practice_today() - 20, v_admin, 585, 'Backfill'),
         (v_client, v_auth_b, 999002, 'A', public.practice_today() - 20, v_admin, 560, 'Backfill');

  -- ── the warrant does not add up, and something says so ─────
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_admin_uid, 'role', 'authenticated')::text, true);

  select w.gap into v_gap from public.warrants_not_accounted_for() w where w.warrant_no = v_warrant;
  if v_gap is null then
    failures := failures || 'FAILED: a warrant with nothing recorded against it is not listed as unaccounted for'::text;
  elsif v_gap <> 1145.00 then
    failures := failures || format('FAILED: 1145.00 is unaccounted for and the gap reads %s', v_gap)::text;
  else
    raise notice 'ok  a warrant whose money is not recorded is named, with the gap';
  end if;

  -- ── a coach cannot touch a warrant line ────────────────────
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_other_uid, 'role', 'authenticated')::text, true);
  v_text := '';
  begin
    perform public.correct_warrant_line(v_line, '99AW00000000001', 'V0000951', '999001', 'ZZ', null, 585.00);
    v_text := 'allowed';
  exception when insufficient_privilege then
    v_text := sqlerrm;
  end;
  if v_text = 'allowed' then
    failures := failures || 'FAILED: a Job Coach corrected a warrant line'::text;
  else
    raise notice 'ok  a warrant line is Admin''s and Billing''s';
  end if;

  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_admin_uid, 'role', 'authenticated')::text, true);

  -- ── the figures a person reads off the page ────────────────
  perform public.correct_warrant_line(v_line, '99AW00000000001', 'V0000951', '999001', 'ZZ', null, 585.00);

  select amount, status, problem, raw into v_gap, v_status, v_text, v_raw
    from public.warrant_lines where id = v_line;
  if v_gap <> 585.00 then
    failures := failures || format('FAILED: the line was corrected to 585.00 and reads %s', v_gap)::text;
  elsif v_status <> 'Needs review' then
    failures := failures || format('FAILED: a corrected line went straight to %s', v_status)::text;
  elsif v_raw <> '6006 99AW00000000001 / 999001- ZZ 585.90' then
    failures := failures || 'FAILED: correcting a line overwrote what the reader saw'::text;
  elsif v_text not like '%ZZ Warrant Admin%' then
    failures := failures || format('FAILED: the line does not say who read it: %s', v_text)::text;
  else
    raise notice 'ok  a corrected line keeps what the reader saw, says who read it, and still waits';
  end if;

  -- ── the line the reader never found ────────────────────────
  v_added := public.add_warrant_line(v_page, '99AW00000000002', 'V0000952', '999002', 'ZZ', null, 560.00);

  select count(*) into v_count from public.warrant_lines where page_id = v_page;
  select lines_total, status into v_lines_total, v_status from public.warrant_pages where id = v_page;
  if v_count <> 2 then
    failures := failures || format('FAILED: the page has %s line(s), not two', v_count)::text;
  elsif v_lines_total <> 1145.00 then
    failures := failures || format('FAILED: two lines of 585 and 560 make the page read %s', v_lines_total)::text;
  elsif v_status <> 'Needs review' then
    failures := failures || format('FAILED: a page with a line just added is %s', v_status)::text;
  else
    raise notice 'ok  a line the reader missed can be added, and the page adds up again';
  end if;

  -- ── and not twice ──────────────────────────────────────────
  v_text := '';
  begin
    perform public.add_warrant_line(v_page, '99AW00000000002', 'V0000952', '999002', 'ZZ', null, 560.00);
    v_text := 'allowed';
  exception when unique_violation then
    v_text := sqlerrm;
  end;
  if v_text = 'allowed' then
    failures := failures || 'FAILED: the same line was added to the page twice'::text;
  elsif v_text not like '%already on this page%' then
    failures := failures || format('FAILED: refused, but not in a sentence: %s', v_text)::text;
  else
    raise notice 'ok  the same line cannot be added to a page twice';
  end if;

  -- ── the page proves itself, and nobody overrode it ─────────
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  perform public.reconcile_warrant_page(v_page);

  select count(*) into v_count from public.warrant_lines
   where page_id = v_page and status = 'Needs review';
  select status into v_status from public.warrant_pages where id = v_page;
  if v_count <> 0 then
    failures := failures || format('FAILED: %s line(s) still waiting after the page was reconciled', v_count)::text;
  elsif v_status <> 'Reconciled' then
    failures := failures || format('FAILED: a page whose lines all settled is %s', v_status)::text;
  else
    raise notice 'ok  the lines a person supplied are matched by the ordinary checks, not by a person';
  end if;

  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_admin_uid, 'role', 'authenticated')::text, true);

  select w.gap into v_gap from public.warrants_not_accounted_for() w where w.warrant_no = v_warrant;
  if v_gap is not null then
    failures := failures || format('FAILED: %s of the warrant is still unaccounted for', v_gap)::text;
  else
    raise notice 'ok  and the warrant accounts for every dollar on it';
  end if;

  -- ── a line that has paid something is history ──────────────
  v_text := '';
  begin
    perform public.correct_warrant_line(v_line, '99AW00000000001', 'V0000951', '999001', 'ZZ', null, 1.00);
    v_text := 'allowed';
  exception when check_violation then
    v_text := sqlerrm;
  end;
  if v_text = 'allowed' then
    failures := failures || 'FAILED: the figures under a payment were changed'::text;
  elsif v_text not like '%part of a payment%' then
    failures := failures || format('FAILED: refused, but not in a sentence: %s', v_text)::text;
  else
    raise notice 'ok  a line that has paid something cannot have its figures changed under the payment';
  end if;

  perform set_config('request.jwt.claims', '', true);

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
