-- Zion Vocational Rehab CRM — expenses and mileage
--
-- Two things to get right, and the second is the one that will be got wrong
-- elsewhere if it is not got right here.
--
-- A mileage claim is miles, not money. What it comes to is the rate on the
-- day it was driven — so a rate set this January must not change what was
-- claimed last December, and miles driven on a day nobody has set a rate for
-- must come back as unpriced rather than as nothing.
--
-- And a claim stops moving once it is on a statement, because at that point
-- it is part of a payment rather than a note somebody is still writing.
--
-- Runs inside a transaction that is rolled back. Nothing here is left behind.

begin;

do $$
declare
  v_staff   uuid;
  v_uid     uuid;
  v_other   uuid;
  v_oth_uid uuid;
  v_claim   uuid;
  v_stmt    uuid;
  v_amount  numeric;
  v_unpriced boolean;
  v_count   int;
  r         record;
  failures  text[] := '{}';
begin
  select id, user_id into v_staff, v_uid from public.staff
   where active and role <> 'Admin' order by created_at limit 1;
  select id, user_id into v_other, v_oth_uid from public.staff
   where active and id <> v_staff order by created_at limit 1;

  -- Start from no rates at all, so the unpriced case is the first thing
  -- tested rather than an afterthought. Rolled back with everything else.
  delete from public.mileage_rates;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);

  -- ── miles with no rate are miles, not nothing ──────────────
  insert into public.expenses (staff_id, incurred_on, category, miles, description, created_by)
  values (v_staff, public.practice_today(), 'mileage', 40, 'ZZ to Tooele', v_staff)
  returning id into v_claim;

  select amount, unpriced into v_amount, v_unpriced
    from public.expense_values where id = v_claim;

  if v_amount is not null then
    failures := failures || format('FAILED: miles with no rate came to %s', v_amount);
  elsif not v_unpriced then
    failures := failures || 'FAILED: miles with no rate are not reported as unpriced'::text;
  else
    raise notice 'ok  miles driven on a day with no rate are unpriced, not zero';
  end if;

  -- ── the rate on the day, not the rate today ────────────────
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  insert into public.mileage_rates (effective_from, cents_per_mile, note)
  values (public.practice_today() - 400, 65.5, 'ZZ last year'),
         (public.practice_today(), 70.0, 'ZZ this year');

  select amount into v_amount from public.expense_values where id = v_claim;
  if v_amount is distinct from 28.00 then
    failures := failures || format('FAILED: 40 miles at 70c came to %s', v_amount);
  else
    raise notice 'ok  40 miles at 70c is $28.00, worked out by the database and not typed in';
  end if;

  -- A claim from last year keeps last year's rate.
  insert into public.expenses (staff_id, incurred_on, category, miles, description, created_by)
  values (v_staff, public.practice_today() - 200, 'mileage', 100, 'ZZ last year trip', v_staff);

  select amount into v_amount from public.expense_values
   where description = 'ZZ last year trip';
  if v_amount is distinct from 65.50 then
    failures := failures || format('FAILED: 100 miles last year came to %s at this year''s rate', v_amount);
  else
    raise notice 'ok  and a trip from last year keeps last year''s rate';
  end if;

  -- ── one kind of claim or the other ─────────────────────────
  begin
    insert into public.expenses (staff_id, incurred_on, category, miles, amount, created_by)
    values (v_staff, public.practice_today(), 'mileage', 10, 5.00, v_staff);
    failures := failures || 'FAILED: a claim carried both miles and an amount'::text;
  exception when check_violation then
    raise notice 'ok  a claim is miles or an amount, never both — the second would be a second answer';
  end;

  begin
    insert into public.expenses (staff_id, incurred_on, category, created_by)
    values (v_staff, public.practice_today(), 'parking', v_staff);
    failures := failures || 'FAILED: a claim was recorded with neither miles nor an amount'::text;
  exception when check_violation then
    raise notice 'ok  and never neither';
  end;

  -- ── an ordinary expense is its own amount ──────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);

  insert into public.expenses (staff_id, incurred_on, category, amount, description, created_by)
  values (v_staff, public.practice_today(), 'parking', 4.50, 'ZZ meter at DWS', v_staff);

  select amount, unpriced into v_amount, v_unpriced from public.expense_values
   where description = 'ZZ meter at DWS';
  if v_amount is distinct from 4.50 or v_unpriced then
    failures := failures || format('FAILED: a $4.50 parking claim reads as %s', v_amount);
  else
    raise notice 'ok  a parking claim is what it says, and no rate is involved';
  end if;

  -- ── whose claim it is ──────────────────────────────────────
  begin
    insert into public.expenses (staff_id, incurred_on, category, amount, description, created_by)
    values (v_other, public.practice_today(), 'parking', 9.99, 'ZZ theirs', v_staff);
    failures := failures || 'FAILED: somebody claimed an expense against a colleague'::text;
  exception when insufficient_privilege then
    raise notice 'ok  nobody claims an expense against somebody else';
  end;

  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_oth_uid, 'role', 'authenticated')::text, true);
  select count(*) into v_count from public.expenses where staff_id = v_staff;
  if v_count <> 0 and (select role from public.staff where id = v_other) <> 'Admin' then
    failures := failures || format('FAILED: a colleague can see %s of somebody else''s claims', v_count);
  else
    raise notice 'ok  and a colleague cannot see them';
  end if;

  -- ── editable until claimed, and not after ──────────────────
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);

  update public.expenses set description = 'ZZ to Tooele and back' where id = v_claim;
  if (select description from public.expenses where id = v_claim) <> 'ZZ to Tooele and back' then
    failures := failures || 'FAILED: an unclaimed expense could not be corrected'::text;
  else
    raise notice 'ok  an expense can be tidied up before it is claimed — the receipt is the evidence, not the label';
  end if;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  insert into public.contractor_statements (staff_id, period_start, period_end, status)
  values (v_staff, public.practice_today() - 14, public.practice_today(), 'Draft')
  returning id into v_stmt;

  update public.expenses set statement_id = v_stmt where staff_id = v_staff;

  begin
    update public.expenses set miles = 999 where id = v_claim;
    failures := failures || 'FAILED: a claim on a statement was changed'::text;
  exception when check_violation then
    raise notice 'ok  once it is on a statement it stops moving — it is part of a payment now';
  end;

  -- ── the statement adds it up ───────────────────────────────
  insert into public.work_sessions (staff_id, worked_on, hours, description, statement_id, created_by)
  values (v_staff, public.practice_today(), 2, 'ZZ work', v_stmt, v_staff);

  select * into r from public.contractor_statement_totals where statement_id = v_stmt;

  if r.expenses is distinct from (28.00 + 65.50 + 4.50) then
    failures := failures || format('FAILED: the statement totals expenses as %s', r.expenses);
  else
    raise notice 'ok  the statement carries the expenses, added up on their own';
  end if;

  if r.mileage_miles is distinct from 140 then
    failures := failures || format('FAILED: the statement reads %s miles', r.mileage_miles);
  else
    raise notice 'ok  and the miles behind them, so an approver can see what they are paying for';
  end if;

  if r.hours is distinct from 2 then
    failures := failures || format('FAILED: expenses disturbed the hours total (%s)', r.hours);
  else
    raise notice 'ok  hours and expenses stay apart in the figures, because they are paid for different reasons';
  end if;

  if r.total_amount <= r.expenses then
    failures := failures || 'FAILED: the total does not include both the hours and the expenses'::text;
  else
    raise notice 'ok  and the total is both together, which is what gets paid';
  end if;

  -- ── who sets the rate ──────────────────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);

  begin
    insert into public.mileage_rates (effective_from, cents_per_mile)
    values (public.practice_today() + 1, 200);
    failures := failures || 'FAILED: somebody set their own mileage rate'::text;
  exception when insufficient_privilege then
    raise notice 'ok  the rate is Admin''s — a contractor setting what they are paid a mile is not a rate';
  end;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  if failures = '{}' then
    raise notice '';
    raise notice '--- EXPENSES AND MILEAGE VERIFIED ---';
  else
    raise notice '';
    raise notice '%  PROBLEM(S):', array_length(failures, 1);
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
