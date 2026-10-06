-- Zion Vocational Rehab CRM — the ledger (0141, 0142, 0144)
--
-- What has to hold, each tried from the direction that would break it:
--
--   Debits equal credits. Not usually: always, through every route, and a
--   one-sided entry is not a posting.
--
--   The books are append-only. A posted entry cannot be edited or deleted,
--   and a correction is a mirror of it with a reason.
--
--   Nothing posts before the day the books open, which is what lets the
--   whole module ship months ahead of 1 January 2027 without touching the
--   operational year that is still running.
--
--   Every source event posts exactly once. A billing item submitted twice
--   is not revenue twice.
--
--   A closed month refuses a journal somebody writes and moves one the CRM
--   makes for itself, saying so on its face - because breaking the action
--   that caused it would be worse, and losing it would be worse still.
--
--   The money follows the event: submitted is receivable, paid is cash in
--   hand, a statement approved is owed to a contractor, a payout clears it.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_entity   uuid;
  v_client   uuid;
  v_staff    uuid;
  v_auth     uuid;
  v_item     uuid;
  v_stmt     uuid;
  v_ar       uuid;
  v_rev      uuid;
  v_und      uuid;
  v_bank     uuid;
  v_cost     uuid;
  v_payable  uuid;
  v_mileage  uuid;
  v_j        uuid;
  v_j2       uuid;
  v_exp      uuid;
  v_n        integer;
  v_amount   numeric;
  v_date     date;
  failures   text[] := '{}';
begin
  select id into v_entity from public.ledger_entities where is_default;
  v_ar      := public.ledger_account('ar');
  v_und     := public.ledger_account('undeposited');
  v_bank    := public.ledger_account('bank');
  v_cost    := public.ledger_account('contractor_cost');
  v_payable := public.ledger_account('contractor_payable');
  v_rev     := public.ledger_revenue_account('Job Coaching');
  select account_id into v_mileage from public.ledger_expense_map where category = 'mileage';

  if v_ar is null or v_und is null or v_bank is null or v_cost is null
     or v_payable is null or v_rev is null or v_mileage is null then
    raise exception 'FAILED: the chart is missing an account the CRM posts to';
  end if;
  raise notice 'ok  every account the CRM posts to itself is in the chart';

  -- ── nothing posts before the books open ───────────────────
  update public.ledger_settings set books_start = date '2027-01-01' where entity_id = v_entity;
  v_j := public.post_journal(date '2026-06-01', 'ZZ too early', 'Manual', null, '',
    jsonb_build_array(
      jsonb_build_object('account', v_bank, 'debit', 10),
      jsonb_build_object('account', v_ar, 'credit', 10)));
  if v_j is not null then
    failures := failures || 'FAILED: something posted before the books opened'::text;
  else
    raise notice 'ok  nothing posts before the day the books open';
  end if;

  -- From here the books are open, so the rules can be tried.
  update public.ledger_settings set books_start = date '2020-01-01' where entity_id = v_entity;

  -- ── debits equal credits ──────────────────────────────────
  begin
    insert into public.journals (entity_id, entry_date, memo, source_kind)
    values (v_entity, date '2026-03-02', 'ZZ one-sided', 'Manual') returning id into v_j;
    insert into public.journal_lines (journal_id, account_id, debit) values (v_j, v_ar, 100);
    set constraints all immediate;
    failures := failures || 'FAILED: a one-sided posting was accepted'::text;
  exception when others then
    raise notice 'ok  a posting with only one side cannot be committed';
  end;
  set constraints all deferred;

  begin
    insert into public.journals (entity_id, entry_date, memo, source_kind)
    values (v_entity, date '2026-03-02', 'ZZ unbalanced', 'Manual') returning id into v_j;
    insert into public.journal_lines (journal_id, account_id, debit) values (v_j, v_ar, 100);
    insert into public.journal_lines (journal_id, account_id, credit) values (v_j, v_rev, 90);
    set constraints all immediate;
    failures := failures || 'FAILED: an unbalanced posting was accepted'::text;
  exception when others then
    raise notice 'ok  debits and credits that are not equal cannot be committed';
  end;
  set constraints all deferred;

  -- ── append-only ───────────────────────────────────────────
  v_j := public.post_journal(date '2026-03-03', 'ZZ good entry', 'Manual', null, '',
    jsonb_build_array(
      jsonb_build_object('account', v_ar, 'debit', 100),
      jsonb_build_object('account', v_rev, 'credit', 100)));
  if v_j is null then
    raise exception 'FAILED: a balanced posting was refused';
  end if;

  begin
    update public.journals set memo = 'ZZ changed' where id = v_j;
    failures := failures || 'FAILED: a posting was edited after the fact'::text;
  exception when others then
    raise notice 'ok  a posting cannot be edited';
  end;

  begin
    delete from public.journals where id = v_j;
    failures := failures || 'FAILED: a posting was deleted'::text;
  exception when others then
    raise notice 'ok  a posting cannot be deleted';
  end;

  begin
    update public.journal_lines set debit = 1 where journal_id = v_j;
    failures := failures || 'FAILED: a line of a posting was edited'::text;
  exception when others then
    raise notice 'ok  a line of a posting cannot be edited either';
  end;

  -- ── a correction is a mirror with a reason ────────────────
  begin
    perform public.reverse_journal(v_j, '');
    failures := failures || 'FAILED: a reversal was accepted with no reason'::text;
  exception when others then null;
  end;

  v_j2 := public.reverse_journal(v_j, 'ZZ wrong client');
  select coalesce(sum(l.credit), 0) into v_amount
    from public.journal_lines l where l.journal_id = v_j2 and l.account_id = v_ar;
  if v_amount <> 100 then
    failures := failures || format('FAILED: a reversal did not mirror the entry (%s credited where 100 was debited)', v_amount)::text;
  else
    raise notice 'ok  a correction is the mirror of the entry, with a reason';
  end if;

  begin
    perform public.reverse_journal(v_j, 'ZZ again');
    failures := failures || 'FAILED: the same posting was reversed twice'::text;
  exception when others then
    raise notice 'ok  a posting is reversed once';
  end;

  -- ── a billing item: submitted, then paid ──────────────────
  insert into public.staff (name, email, role, active)
  values ('ZZ Ledger Contractor', 'zz-ledger@example.test', 'Job Search', true) returning id into v_staff;
  insert into public.clients (name, stage, status) values ('ZZ Ledger Client', 'Placement', 'Active')
  returning id into v_client;
  insert into public.authorizations (client_id, service_type, rate_type, rate, total_hours)
  values (v_client, 'Job Coaching', 'Hourly', 40, 20) returning id into v_auth;

  insert into public.billing_items (client_id, auth_id, service, period, status, billing_type, hours, rate, amount)
  values (v_client, v_auth, 'Job Coaching', date '2026-03-01', 'Ready for billing', 'Hourly', 10, 40, 400)
  returning id into v_item;

  update public.billing_items
     set status = 'Submitted', submitted_at = timestamptz '2026-03-10 12:00+00', recipient = 'ZZ USOR'
   where id = v_item;

  select coalesce(sum(l.debit), 0) into v_amount
    from public.journal_lines l
    join public.journals j on j.id = l.journal_id
   where j.source_kind = 'Billing item' and j.source_id = v_item and l.account_id = v_ar;
  if v_amount <> 400 then
    failures := failures || format('FAILED: submitting an item put %s into receivables, not 400', v_amount)::text;
  end if;
  select coalesce(sum(l.credit), 0) into v_amount
    from public.journal_lines l
    join public.journals j on j.id = l.journal_id
   where j.source_kind = 'Billing item' and j.source_id = v_item and l.account_id = v_rev;
  if v_amount <> 400 then
    failures := failures || format('FAILED: submitting an item credited %s to its service, not 400', v_amount)::text;
  else
    raise notice 'ok  an item submitted is owed to the practice, against the revenue for its service';
  end if;

  -- The same event again is the same event.
  update public.billing_items set notes = 'ZZ touched again' where id = v_item;
  update public.billing_items set status = 'Submitted' where id = v_item;
  select count(*) into v_n from public.journals
   where source_kind = 'Billing item' and source_id = v_item and source_event like 'Submitted%';
  if v_n <> 1 then
    failures := failures || format('FAILED: submitting posted %s times', v_n)::text;
  else
    raise notice 'ok  a source event posts exactly once';
  end if;

  update public.billing_items
     set status = 'Paid', paid_on = date '2026-04-02', paid_amount = 400, warrant = 'ZZ-W-1'
   where id = v_item;

  select coalesce(sum(l.debit), 0) into v_amount
    from public.journal_lines l
    join public.journals j on j.id = l.journal_id
   where j.source_kind = 'Billing item' and j.source_id = v_item and l.account_id = v_und;
  if v_amount <> 400 then
    failures := failures || format('FAILED: a warrant paid put %s into undeposited funds, not 400', v_amount)::text;
  else
    raise notice 'ok  a warrant paid is money in hand, not money at the bank';
  end if;

  select count(*) into v_n from public.journals
   where source_kind = 'Billing item' and source_id = v_item
     and source_event like 'Paid%' and cash_class_account_id = v_rev;
  if v_n <> 1 then
    failures := failures || 'FAILED: a payment did not carry the revenue it was for'::text;
  else
    raise notice 'ok  a payment says what it was for, so a cash-basis report need not guess';
  end if;

  -- Receivables are back to nothing: billed 400, paid 400.
  select coalesce(sum(l.debit) - sum(l.credit), 0) into v_amount
    from public.journal_lines l
    join public.journals j on j.id = l.journal_id
   where l.account_id = v_ar and j.source_kind = 'Billing item' and j.source_id = v_item;
  if v_amount <> 0 then
    failures := failures || format('FAILED: receivables stand at %s after an item was billed and paid in full', v_amount)::text;
  else
    raise notice 'ok  billed and paid in full leaves nothing owed';
  end if;

  -- ── and if the payment is undone, so is the posting ───────
  update public.billing_items set status = 'Correction needed', correction_note = 'ZZ wrong warrant' where id = v_item;
  select count(*) into v_n from public.journals j
   where j.source_kind = 'Reversal'
     and j.reverses_id in (select id from public.journals
                            where source_kind = 'Billing item' and source_id = v_item
                              and source_event like 'Paid%');
  if v_n <> 1 then
    failures := failures || 'FAILED: undoing a payment left the cash posted'::text;
  else
    raise notice 'ok  a payment undone is reversed, not erased';
  end if;

  -- ── but closing a paid item is not undoing it ─────────────
  --
  -- Closed is an ending, not a correction. An item that was paid and is then
  -- closed off has still been paid, and reversing it would take real money
  -- off the books with a reversal nobody would read until the month would
  -- not reconcile.
  update public.billing_items
     set status = 'Paid', paid_on = date '2026-04-20', paid_amount = 400 where id = v_item;
  select count(*) into v_n from public.journals j
   where j.source_kind = 'Reversal'
     and j.reverses_id in (select id from public.journals
                            where source_kind = 'Billing item' and source_id = v_item
                              and source_event like 'Paid%');
  update public.billing_items
     set status = 'Closed', closed_reason = 'ZZ finished with' where id = v_item;
  select count(*) - v_n into v_n from public.journals j
   where j.source_kind = 'Reversal'
     and j.reverses_id in (select id from public.journals
                            where source_kind = 'Billing item' and source_id = v_item
                              and source_event like 'Paid%');
  if v_n <> 0 then
    failures := failures || 'FAILED: closing a paid item reversed the money it had been paid'::text;
  else
    raise notice 'ok  closing a paid item leaves the money where it is';
  end if;

  -- ── a statement approved, and the claims on it ────────────
  insert into public.mileage_rates (effective_from, cents_per_mile)
  values (date '2026-01-01', 67) on conflict do nothing;

  insert into public.contractor_statements (staff_id, period_start, period_end, status, adjustment, adjustment_note)
  values (v_staff, date '2026-03-01', date '2026-03-31', 'Submitted', 500, 'ZZ agreed flat month')
  returning id into v_stmt;

  insert into public.expenses (staff_id, incurred_on, category, description, miles, statement_id, created_by)
  values (v_staff, date '2026-03-12', 'mileage', 'ZZ to a worksite', 100, v_stmt, v_staff)
  returning id into v_exp;

  update public.contractor_statements set status = 'Approved', decided_at = now() where id = v_stmt;

  select coalesce(sum(l.debit), 0) into v_amount
    from public.journal_lines l
    join public.journals j on j.id = l.journal_id
   where j.source_kind = 'Contractor statement' and j.source_id = v_stmt and l.account_id = v_cost;
  if v_amount <> 500 then
    failures := failures || format('FAILED: approving a statement cost %s, not 500', v_amount)::text;
  else
    raise notice 'ok  a statement approved is a cost the practice has taken on';
  end if;

  select coalesce(sum(l.debit), 0) into v_amount
    from public.journal_lines l
    join public.journals j on j.id = l.journal_id
   where j.source_kind = 'Expense claim' and j.source_id = v_exp and l.account_id = v_mileage;
  if v_amount <> 67 then
    failures := failures || format('FAILED: 100 miles at 67 cents posted %s, not 67.00', v_amount)::text;
  else
    raise notice 'ok  mileage posts at the rate on the day it was driven';
  end if;

  select coalesce(sum(l.credit) - sum(l.debit), 0) into v_amount
    from public.journal_lines l where l.account_id = v_payable and l.staff_id = v_staff;
  if v_amount <> 567 then
    failures := failures || format('FAILED: %s is owed to the contractor, not 567.00', v_amount)::text;
  else
    raise notice 'ok  the work and the claims on a statement are both owed to the person who earned them';
  end if;

  -- ── and the payout clears it ──────────────────────────────
  insert into public.contractor_payments (staff_id, statement_id, paid_on, amount, method, created_by)
  values (v_staff, v_stmt, date '2026-04-05', 567, 'ACH', v_staff);

  select coalesce(sum(l.credit) - sum(l.debit), 0) into v_amount
    from public.journal_lines l where l.account_id = v_payable and l.staff_id = v_staff;
  if v_amount <> 0 then
    failures := failures || format('FAILED: %s is still owed after the contractor was paid in full', v_amount)::text;
  else
    raise notice 'ok  a payout clears what was owed and leaves the bank';
  end if;

  -- ── a closed month ────────────────────────────────────────
  insert into public.ledger_periods (entity_id, month) values (v_entity, date '2026-05-01');

  v_j := public.post_journal(date '2026-05-10', 'ZZ into a shut month', 'Manual', null, '',
    jsonb_build_array(
      jsonb_build_object('account', v_bank, 'debit', 25),
      jsonb_build_object('account', v_ar, 'credit', 25)));
  select entry_date into v_date from public.journals where id = v_j;
  if v_date is null or date_trunc('month', v_date)::date <> date '2026-06-01' then
    failures := failures || format('FAILED: a posting into a closed month landed on %s', v_date)::text;
  else
    raise notice 'ok  a posting the CRM makes for itself moves to the next open month, and says so';
  end if;
  select count(*) into v_n from public.journals
   where id = v_j and memo like '%2026-05-10%' and memo like '%closed%';
  if v_n <> 1 then
    failures := failures || 'FAILED: a shifted posting did not say what day it happened'::text;
  end if;

  begin
    insert into public.journals (entity_id, entry_date, memo, source_kind)
    values (v_entity, date '2026-05-11', 'ZZ straight in', 'Manual');
    failures := failures || 'FAILED: a posting went straight into a closed month'::text;
  exception when others then
    raise notice 'ok  a closed month refuses a posting';
  end;

  -- ── the books balance ─────────────────────────────────────
  select coalesce(sum(l.debit) - sum(l.credit), 0) into v_amount from public.journal_lines l;
  if v_amount <> 0 then
    failures := failures || format('FAILED: the ledger as a whole is out by %s', v_amount)::text;
  else
    raise notice 'ok  every debit in the ledger has its credit';
  end if;

  select coalesce(sum(case when t.kind in ('Asset', 'Expense') then t.balance else -t.balance end), 0)
    into v_amount from public.ledger_trial_balance(date '2026-12-31') t;
  if v_amount <> 0 then
    failures := failures || format('FAILED: the trial balance does not balance (out by %s)', v_amount)::text;
  else
    raise notice 'ok  the trial balance balances';
  end if;

  -- ── an account with postings is retired, not deleted ──────
  begin
    delete from public.ledger_accounts where id = v_ar;
    failures := failures || 'FAILED: an account holding postings was deleted'::text;
  exception when others then
    raise notice 'ok  an account that holds postings cannot be deleted';
  end;

  -- ── a journal by hand needs Admin and a reason ────────────
  begin
    perform public.post_manual_journal(date '2026-06-02', 'ZZ no reason', '',
      jsonb_build_array(
        jsonb_build_object('account', v_bank, 'debit', 5),
        jsonb_build_object('account', v_ar, 'credit', 5)));
    failures := failures || 'FAILED: a journal entry was written with no reason'::text;
  exception when others then
    raise notice 'ok  a journal entry written by hand needs a reason';
  end;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
