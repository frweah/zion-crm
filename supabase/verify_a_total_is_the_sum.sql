-- A total is the sum of its payments (0292)
--
-- What has to hold:
--
--   An authorization's paid_amount is the sum of its payment rows. Always:
--   after a payment is added, after one is taken back, and whatever a caller
--   asks for. It was a stored column that anything could set, and four
--   authorizations had drifted from their own payments because of it.
--
--   A warrant line may pay an authorization that already has a payment, when
--   that payment is on a different warrant. Two payments from two warrants is
--   an ordinary thing. This is F15658189 line 3's exact shape: V1028879 was
--   already paid $585 from F15617525, the 15 October warrant names it again
--   for $585, and the old rule refused that line with "this line does not
--   match that payment" - which is how nine payments came to be entered by
--   hand on 3 November.
--
--   The same line twice is still refused.
--
--   And the F on a printed stub is not part of the warrant number.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_client uuid; v_counsel uuid; v_auth uuid;
  v_doc uuid; v_page_a uuid; v_page_b uuid; v_line_a uuid; v_line_b uuid; v_line_c uuid;
  v_outcome text; v_total numeric; v_n integer;
  failures text[] := '{}';
begin
  insert into public.counselors (name, email, office)
  values ('ZQ Sum Counselor', 'zq-sum@example.test', 'Salt Lake City') returning id into v_counsel;
  insert into public.clients (name, stage, status, counselor_id)
  values ('ZZ Sum Testperson', 'Job Search', 'Active', v_counsel) returning id into v_client;

  -- A flat fee of 585, the shape V1028879 is.
  insert into public.authorizations (client_id, number, service_type, rate_type, rate,
                                     status, start_date, end_date, submitted_on)
  values (v_client, 'ZQ-SUM-1', 'WSA Tier 1', 'Flat Fee', 585, 'Submitted',
          public.practice_today() - 90, public.practice_today() - 10, public.practice_today() - 40)
  returning id into v_auth;

  -- ── the total is the sum ──────────────────────────────────
  if (select coalesce(paid_amount, 0) from public.authorizations where id = v_auth) <> 0 then
    failures := failures || 'FAILED: an authorization with no payments does not read as nothing paid'::text;
  end if;

  -- A caller asking for a figure of its own is refused when the transaction
  -- tries to commit. Deferred rather than immediate, because recording a
  -- payment updates the authorization and then inserts the payment row - so
  -- the two disagree for a moment by design, and only the commit has to find
  -- them agreeing.
  begin
    update public.authorizations set paid_amount = 9999 where id = v_auth;
    -- Force the deferred triggers to fire now rather than at the end of the
    -- whole script, which is what a real transaction's commit would do.
    set constraints all immediate;
    failures := failures || 'FAILED: a figure typed over the top was accepted, so the total is still a stored column'::text;
  exception when check_violation then
    raise notice 'ok  a total typed over the top is refused: the payments decide';
  end;
  -- And the row is as it was.
  if (select coalesce(paid_amount, 0) from public.authorizations where id = v_auth) <> 0 then
    failures := failures || 'FAILED: the refused figure stuck anyway'::text;
  end if;
  set constraints all deferred;

  insert into public.payments (auth_id, amount, warrant_no, warrant_date, voucher, source,
                               recorded_by_name)
  values (v_auth, 585, 'F19999001', public.practice_today() - 40, 'ZQ-V-1', 'By hand', 'ZQ');
  if (select coalesce(paid_amount, 0) from public.authorizations where id = v_auth) <> 585 then
    failures := failures || 'FAILED: adding a payment did not reach the total'::text;
  else
    raise notice 'ok  a payment reaches the total';
  end if;

  insert into public.payments (auth_id, amount, warrant_no, warrant_date, voucher, source,
                               recorded_by_name)
  values (v_auth, 585, 'F19999002', public.practice_today() - 10, 'ZQ-V-2', 'By hand', 'ZQ');
  if (select coalesce(paid_amount, 0) from public.authorizations where id = v_auth) <> 1170 then
    failures := failures || 'FAILED: a second payment did not reach the total'::text;
  else
    raise notice 'ok  and a second one does, from a second warrant';
  end if;

  -- Paid above what was authorized is flagged rather than corrected: nothing
  -- here knows which of the two payments is wrong.
  if not exists (
    select 1 from public.authorization_attention_for(array[v_auth], public.practice_today())
     where attention like 'Paid more than authorized%'
  ) then
    failures := failures || 'FAILED: an authorization paid above what it allows says nothing about it'::text;
  else
    raise notice 'ok  and paid above what was authorized says so, with both figures';
  end if;

  -- Taking one back brings the total down with it.
  delete from public.payments where auth_id = v_auth and warrant_no = 'F19999002';
  if (select coalesce(paid_amount, 0) from public.authorizations where id = v_auth) <> 585 then
    failures := failures || 'FAILED: removing a payment did not bring the total down'::text;
  else
    raise notice 'ok  and taking one back brings the total down with it';
  end if;

  delete from public.payments where auth_id = v_auth;
  if (select coalesce(paid_amount, 0) from public.authorizations where id = v_auth) <> 0 then
    failures := failures || 'FAILED: an authorization with no payments left still says it was paid'::text;
  else
    raise notice 'ok  and no payments left means nothing paid';
  end if;

  -- ── the F is not part of the number ───────────────────────
  if not public.same_warrant('F15617525', '15617525')
     or not public.same_warrant('15658189', 'F 15658189')
     or public.same_warrant('F15617525', 'F15658189')
     or public.same_warrant('', 'F15617525') then
    failures := failures || 'FAILED: two ways of writing the same warrant number are not the same warrant'::text;
  else
    raise notice 'ok  the F on a printed stub is not part of the number';
  end if;

  -- ── F15658189 line 3's shape ──────────────────────────────
  -- Paid from one warrant, named again on another. The old rule refused the
  -- second line; it is an ordinary second payment.
  insert into public.payments (auth_id, amount, warrant_no, warrant_date, voucher, source,
                               recorded_by_name)
  values (v_auth, 585, 'F19999001', public.practice_today() - 40, 'ZQ-V-1', 'By hand', 'ZQ');

  insert into public.warrant_documents (sha256, filename, relative_path, page_count)
  values (repeat('a', 64), 'zq-warrant.pdf', 'zq-warrant.pdf', 1) returning id into v_doc;
  insert into public.warrant_pages (document_id, page_no, image_path, warrant_no, warrant_date,
                                    total, lines_total, status)
  values (v_doc, 1, 'zq/page-001.jpg', 'F19999003', public.practice_today() - 5, 585, 585, 'Needs review')
  returning id into v_page_b;
  insert into public.warrant_lines (page_id, line_no, raw, invoice_ref, described_ref, client_name,
                                    voucher, described_amount, amount, status)
  values (v_page_b, 1, '600 27AW00009999001 ZQ-SUM-1 /999901-A Testperson-ZQ-SUM-1-585.00 585.00',
          'ZQ-SUM-1', 'ZQ-SUM-1', 'ZZ Sum Testperson', '27AW00009999001', 585, 585, 'Needs review')
  returning id into v_line_b;

  -- As the agent, which is how the reconciler is normally called: the nightly
  -- run reads the warrants folder. Admin and Billing may also call it.
  perform set_config('request.jwt.claims',
                     json_build_object('role', 'service_role')::text, true);
  v_outcome := public.reconcile_warrant_line(v_line_b);
  if v_outcome = 'Needs review' then
    failures := failures || format('FAILED: a line on a second warrant was refused - %s',
      (select problem from public.warrant_lines where id = v_line_b))::text;
  elsif (select coalesce(paid_amount, 0) from public.authorizations where id = v_auth) <> 1170 then
    failures := failures || format('FAILED: the second warrant did not reach the total - the line came back %L, the line reads %L, and there are %s payment(s)',
      v_outcome,
      (select status from public.warrant_lines where id = v_line_b),
      (select count(*) from public.payments where auth_id = v_auth))::text;
  else
    raise notice 'ok  a line on a second warrant pays an authorization that was already paid';
  end if;

  -- ── and the same line twice is still refused ──────────────
  -- The page now holds two lines, so its total has to say so, or the line is
  -- refused for not adding up rather than for being the same line twice -
  -- which would make this assertion pass without proving anything.
  insert into public.warrant_lines (page_id, line_no, raw, invoice_ref, described_ref, client_name,
                                    voucher, described_amount, amount, status)
  values (v_page_b, 2, '600 27AW00009999002 ZQ-SUM-1 /999902-A Testperson-ZQ-SUM-1-585.00 585.00',
          'ZQ-SUM-1', 'ZQ-SUM-1', 'ZZ Sum Testperson', '27AW00009999002', 585, 585, 'Needs review')
  returning id into v_line_c;
  update public.warrant_pages set total = 1170, lines_total = 1170 where id = v_page_b;

  select count(*) into v_n from public.payments where auth_id = v_auth;
  v_outcome := public.reconcile_warrant_line(v_line_c);
  if v_outcome <> 'Needs review' then
    failures := failures || 'FAILED: the same payment was recorded from two lines on one warrant'::text;
  elsif (select count(*) from public.payments where auth_id = v_auth) <> v_n then
    failures := failures || 'FAILED: a second line on the same warrant added a payment'::text;
  else
    raise notice 'ok  and a second line on the same warrant for the same money is refused';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- A TOTAL IS THE SUM VERIFIED ---';
end $$;

rollback;
