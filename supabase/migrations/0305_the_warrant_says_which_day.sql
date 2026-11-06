-- Zion Vocational Rehab CRM — Phase 2, the last disagreements
--
-- "The warrant is the truth. Where the CRM disagrees on amount, date, or
-- authorization, the warrant wins, with a correction-log entry."
--
-- Four payments carry the day somebody recorded them rather than the day the
-- state paid them - in each case the day the person sat down to enter a
-- batch, which is why three of the four are 26 October. One payment has no
-- voucher where the warrant gives one.
--
-- Both halves are corrected: the payment row, which is the ledger, and the
-- authorization's own paid_on, which is the summary of it. correct_payment_date
-- writes the correction-log entry for the second; the first is the row the
-- ledger is summed from and has no function of its own, so it is updated
-- beside it in the same transaction.
--
-- ── and one place the warrant does not win ───────────────────
--
-- V996569's voucher reads 26AWO00000067561 in the warrant index and
-- 26AW00000067561 in the CRM - a letter O where every other voucher in 156
-- lines has a zero. The index was built by OCR from a scan; the CRM was typed
-- from the remittance advice. This one is not corrected, and it is the reason
-- the rule is "the warrant wins" rather than "the index wins": the index is a
-- reading of the warrant, and a reading can be wrong in a way the thing read
-- is not. It is in the report.

begin;

do $$
declare
  v_admin uuid;
  v_uid   uuid;
  r       record;
  v_n     integer := 0;
begin
  select id, user_id into v_admin, v_uid
    from public.staff where role = 'Admin' and active and not is_system
   order by created_at limit 1;
  if v_uid is null then
    raise exception 'no active Admin with a sign-in';
  end if;
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);

  for r in
    select * from (values
      ('V1006032', date '2026-10-01'),
      ('V1039602', date '2026-10-01'),
      ('V1041928', date '2026-10-15'),
      ('V1037990', date '2026-10-22'),
      -- This one the other way round: the payment row had the warrant's day
      -- and the authorization's summary of it had the day it was entered.
      -- Found by the assertion at the foot of this file rather than by the
      -- reconciliation, which compares the payment rows.
      ('V991038',  date '2026-10-01')
    ) as t(number, paid_on)
  loop
    if not exists (select 1 from public.authorizations a
                    where a.number = r.number and a.paid_on is distinct from r.paid_on) then
      raise notice 'note  % is already dated %', r.number, r.paid_on;
      continue;
    end if;

    perform public.correct_payment_date(
      (select id from public.authorizations where number = r.number),
      r.paid_on,
      format('Phase 2 of the warrant reconciliation, on the owner''s ruling of 6 November 2026. '
             || 'The warrant pays this on %s; the record carried the day it was entered. '
             || 'The warrant is the truth on a date.', to_char(r.paid_on, 'FMDD FMMonth YYYY')));

    update public.payments p
       set warrant_date = r.paid_on
      from public.authorizations a
     where a.number = r.number and p.auth_id = a.id and p.warrant_date is distinct from r.paid_on;

    v_n := v_n + 1;
  end loop;
  raise notice 'ok  % payment date(s) brought to the day the state paid them', v_n;

  -- The voucher the warrant gives and the record did not have. Filling a
  -- blank is recording what the paperwork says, which is why the correction
  -- log does not demand a reason for it.
  update public.payments p
     set voucher = '27AW00000095502'
    from public.authorizations a
   where a.number = 'V1043881' and p.auth_id = a.id
     and coalesce(btrim(p.voucher), '') = '';
  if found then
    raise notice 'ok  V1043881 carries the voucher the warrant gives it';
  end if;

  perform set_config('request.jwt.claims', '', true);
end $$;

-- ── the ledger is the index, and the one row nobody ruled on ──
do $$
declare v_count integer; v_total numeric; v_dates integer;
begin
  select count(*), coalesce(sum(amount), 0) into v_count, v_total from public.payments;
  if v_count <> 157 or v_total <> 160562.50 then
    raise exception 'the ledger moved: % payments, %', v_count, to_char(v_total, 'FM999999.00');
  end if;

  -- Every payment's own date agrees with its authorization's paid_on, which
  -- is the thing that was out of step on the four corrected above.
  select count(*) into v_dates
    from public.payments p join public.authorizations a on a.id = p.auth_id
   where a.status = 'Paid'
     and (select count(*) from public.payments q where q.auth_id = a.id) = 1
     and p.warrant_date is distinct from a.paid_on;
  if v_dates <> 0 then
    raise exception '% payment(s) are dated differently from the authorization they are on', v_dates;
  end if;
  raise notice 'ok  157 payments, 160562.50, and every single-payment authorization agrees with its own payment on the day';
end $$;

commit;
