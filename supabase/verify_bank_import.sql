-- Zion Vocational Rehab CRM — bank statements and reconciliation (0143)
--
-- What has to hold, each tried from the direction that would break it:
--
--   Importing the same statement twice adds nothing. Somebody will do it.
--
--   A statement line is matched to a posting that moved the same money, or
--   it is not matched at all. Matching two different numbers is how a
--   reconciliation comes out right and means nothing.
--
--   A line is set aside with a reason, and a line already accounted for
--   cannot also be set aside.
--
--   A statement cannot be reconciled while anything is unsettled, while its
--   own lines do not add up to the balance on its face, or while the ledger
--   and the bank differ by a penny. Refused, not warned about.
--
--   A reconciled statement is a closed question.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_entity  uuid;
  v_admin   uuid;
  v_uid     uuid := gen_random_uuid();
  v_zzbank  uuid;
  v_account uuid;
  v_und     uuid;
  v_rev     uuid;
  v_stmt    uuid;
  v_tx      uuid;
  v_other   uuid;
  v_journal uuid;
  v_n       integer;
  v_amount  numeric;
  v_kind    text;
  failures  text[] := '{}';
begin
  select id into v_entity from public.ledger_entities where is_default;
  update public.ledger_settings set books_start = date '2020-01-01' where entity_id = v_entity;
  v_und := public.ledger_account('undeposited');
  v_rev := public.ledger_revenue_account('Job Coaching');

  -- A bank account of its own, so what is asserted below is this test's
  -- money and not the practice's.
  insert into public.ledger_accounts (entity_id, code, name, kind)
  values (v_entity, 'ZZ01', 'ZZ test bank', 'Asset') returning id into v_account;
  insert into public.bank_accounts (entity_id, account_id, name, last4)
  values (v_entity, v_account, 'ZZ test account', '0000') returning id into v_zzbank;

  insert into public.staff (name, email, role, active)
  values ('ZZ Bank Admin', 'zz-bank@example.test', 'Admin', true) returning id into v_admin;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-bank@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_uid where id = v_admin;

  -- Warrants paid and not yet banked: what a deposit on a statement is.
  perform public.post_journal(date '2026-04-01', 'ZZ warrant in hand', 'Manual', null, '',
    jsonb_build_array(
      jsonb_build_object('account', v_und, 'debit', 400),
      jsonb_build_object('account', v_rev, 'credit', 400)));

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);

  -- ── importing, and importing again ────────────────────────
  v_stmt := public.import_bank_statement(v_zzbank, date '2026-04-01', date '2026-04-30', 0, 400,
    jsonb_build_array(
      jsonb_build_object('posted_on', '2026-04-03', 'description', 'ZZ DEPOSIT', 'amount', 400, 'external_id', 'ZZ-1')));
  select count(*) into v_n from public.bank_transactions where statement_id = v_stmt;
  if v_n <> 1 then
    failures := failures || format('FAILED: importing one line gave %s', v_n)::text;
  end if;

  perform public.import_bank_statement(v_zzbank, date '2026-04-01', date '2026-04-30', 0, 400,
    jsonb_build_array(
      jsonb_build_object('posted_on', '2026-04-03', 'description', 'ZZ DEPOSIT', 'amount', 400, 'external_id', 'ZZ-1')));
  select count(*) into v_n from public.bank_transactions where statement_id = v_stmt;
  if v_n <> 1 then
    failures := failures || format('FAILED: importing the same statement twice gave %s lines', v_n)::text;
  else
    raise notice 'ok  importing the same statement twice adds nothing';
  end if;

  select id into v_tx from public.bank_transactions where statement_id = v_stmt;

  -- ── what the line probably is ─────────────────────────────
  select kind into v_kind from public.bank_suggestions(v_stmt) where transaction_id = v_tx;
  if v_kind is distinct from 'Deposit' then
    failures := failures || format('FAILED: money in against warrants in hand was suggested as %s', coalesce(v_kind, 'nothing'))::text;
  else
    raise notice 'ok  money in, with warrants paid and not yet banked, is suggested as a deposit';
  end if;

  -- ── it cannot be reconciled while a line is unsettled ─────
  begin
    perform public.reconcile_bank_statement(v_stmt);
    failures := failures || 'FAILED: a statement was reconciled with a line nobody had settled'::text;
  exception when others then
    raise notice 'ok  a statement with an unsettled line cannot be reconciled';
  end;

  -- ── settling it ───────────────────────────────────────────
  v_journal := public.post_bank_transaction(v_tx, v_und, 'ZZ banked the warrant');
  select coalesce(sum(l.debit) - sum(l.credit), 0) into v_amount
    from public.journal_lines l where l.account_id = v_account;
  if v_amount <> 400 then
    failures := failures || format('FAILED: banking a warrant put %s in the bank, not 400', v_amount)::text;
  end if;
  select coalesce(sum(l.debit) - sum(l.credit), 0) into v_amount
    from public.journal_lines l where l.account_id = v_und;
  if v_amount <> 0 then
    failures := failures || format('FAILED: %s is still in hand after it was banked', v_amount)::text;
  else
    raise notice 'ok  banking a warrant moves it from in hand to at the bank, and nets to nothing';
  end if;

  -- ── a matched line is accounted for ───────────────────────
  begin
    perform public.ignore_bank_transaction(v_tx, 'ZZ changed my mind');
    failures := failures || 'FAILED: a line matched to a posting was also set aside'::text;
  exception when others then
    raise notice 'ok  a line already accounted for cannot also be set aside';
  end;

  -- ── and it reconciles ─────────────────────────────────────
  perform public.reconcile_bank_statement(v_stmt);
  if (select reconciled_at from public.bank_statements where id = v_stmt) is null then
    failures := failures || 'FAILED: a statement that agrees with the ledger was not reconciled'::text;
  else
    raise notice 'ok  a statement that agrees with the ledger reconciles';
  end if;

  begin
    perform public.import_bank_statement(v_zzbank, date '2026-04-01', date '2026-04-30', 0, 400, '[]'::jsonb);
    failures := failures || 'FAILED: a reconciled statement took another import'::text;
  exception when others then
    raise notice 'ok  a reconciled statement is a closed question';
  end;

  -- ── a statement that does not agree ───────────────────────
  v_stmt := public.import_bank_statement(v_zzbank, date '2026-05-01', date '2026-05-31', 400, 900,
    jsonb_build_array(
      jsonb_build_object('posted_on', '2026-05-04', 'description', 'ZZ SOMETHING', 'amount', 500, 'external_id', 'ZZ-2')));
  select id into v_other from public.bank_transactions where statement_id = v_stmt;

  -- Matched to a posting that moved a different amount: refused.
  begin
    perform public.match_bank_transaction(v_other, v_journal);
    failures := failures || 'FAILED: a line was matched to a posting for a different amount'::text;
  exception when others then
    raise notice 'ok  a line is not matched to a posting that moved different money';
  end;

  -- Set aside for no stated reason: refused.
  begin
    perform public.ignore_bank_transaction(v_other, '  ');
    failures := failures || 'FAILED: a line was set aside with no reason'::text;
  exception when others then
    raise notice 'ok  setting a line aside means saying why';
  end;

  perform public.ignore_bank_transaction(v_other, 'ZZ belongs to the other account');
  begin
    perform public.reconcile_bank_statement(v_stmt);
    failures := failures || 'FAILED: a statement whose lines do not add up was reconciled'::text;
  exception when others then
    raise notice 'ok  a statement whose own lines do not reach its closing balance is refused';
  end;

  perform set_config('role', 'postgres', true);

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
