-- Zion Vocational Rehab CRM — budget and forecast (0146, 0147)
--
-- What has to hold, each tried from the direction that would break it:
--
--   A budget and an actual are compared with the sign the same way round for
--   revenue and for cost: above budget on revenue and below it on cost are
--   both good, and a report that showed one as positive and the other as
--   negative would be read wrong by everybody, every month.
--
--   An account nobody budgeted is never over budget. A zero somebody never
--   typed is not a promise.
--
--   The forecast keeps its three bands apart. Committed work, authorized and
--   unearned, and an estimate from the referral trend are three different
--   degrees of certainty, and a single number that blends them is a number
--   nobody can act on.
--
--   The same money is not counted twice: an item in the pipeline and the
--   authorization behind it are one expectation, not two.
--
--   The two alerts fire when the owner asked them to and not before: past
--   the tolerance, below the floor, and nothing at all while either is unset.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_entity  uuid;
  v_client  uuid;
  v_auth    uuid;
  v_item    uuid;
  v_staff   uuid;
  v_rent    uuid;
  v_rev     uuid;
  v_ar      uuid;
  v_bank    uuid;
  v_month   date := date_trunc('month', public.practice_today())::date;
  v_n       integer;
  v_amount  numeric;
  v_over    boolean;
  v_text    text;
  -- The practice has its own open authorizations, so what this script proves
  -- is what its own data changed, not what the totals happen to be.
  v_before_committed  numeric;
  v_before_authorized numeric;
  v_before_owed       numeric;
  failures  text[] := '{}';
begin
  select id into v_entity from public.ledger_entities where is_default;
  update public.ledger_settings set books_start = date '2020-01-01' where entity_id = v_entity;

  select id into v_rent from public.ledger_accounts where code = '5400' and entity_id = v_entity;
  v_rev  := public.ledger_revenue_account('Job Coaching');
  v_ar   := public.ledger_account('ar');
  v_bank := public.ledger_account('bank');

  -- ── budget against actual, both ways round ────────────────
  insert into public.ledger_budgets (entity_id, account_id, month, amount)
  values (v_entity, v_rent, v_month, 1000);
  perform public.post_journal(v_month, 'ZZ rent', 'Manual', null, '',
    jsonb_build_array(
      jsonb_build_object('account', v_rent, 'debit', 1200),
      jsonb_build_object('account', v_bank, 'credit', 1200)));

  select v.variance, v.over into v_amount, v_over
    from public.ledger_budget_variance(v_month, (v_month + interval '1 month - 1 day')::date) v
   where v.account_id = v_rent;
  if v_amount is distinct from -200 or v_over is not true then
    failures := failures || format('FAILED: 1200 spent against a 1000 budget read as %s, over=%s', v_amount, v_over)::text;
  else
    raise notice 'ok  cost over budget is a negative variance, and is flagged';
  end if;

  insert into public.ledger_budgets (entity_id, account_id, month, amount)
  values (v_entity, v_rev, v_month, 1000);
  perform public.post_journal(v_month, 'ZZ revenue', 'Manual', null, '',
    jsonb_build_array(
      jsonb_build_object('account', v_ar, 'debit', 1200),
      jsonb_build_object('account', v_rev, 'credit', 1200)));

  select v.variance, v.over into v_amount, v_over
    from public.ledger_budget_variance(v_month, (v_month + interval '1 month - 1 day')::date) v
   where v.account_id = v_rev;
  if v_amount is distinct from 200 or v_over is not false then
    failures := failures || format('FAILED: 1200 earned against a 1000 budget read as %s, over=%s', v_amount, v_over)::text;
  else
    raise notice 'ok  revenue above budget is a positive variance, and is not "over budget"';
  end if;

  -- ── an account nobody budgeted ────────────────────────────
  perform public.post_journal(v_month, 'ZZ unbudgeted', 'Manual', null, '',
    jsonb_build_array(
      jsonb_build_object('account', public.ledger_account('expense_other'), 'debit', 500),
      jsonb_build_object('account', v_bank, 'credit', 500)));
  select v.over into v_over
    from public.ledger_budget_variance(v_month, (v_month + interval '1 month - 1 day')::date) v
   where v.account_id = public.ledger_account('expense_other');
  if v_over is not false then
    failures := failures || 'FAILED: an account nobody budgeted was called over budget'::text;
  else
    raise notice 'ok  an account nobody budgeted is never over budget';
  end if;

  -- ── the forecast keeps its bands apart ────────────────────
  select coalesce(sum(f.amount), 0) into v_before_committed
    from public.ledger_revenue_forecast(3) f where f.band = 'Committed';
  select coalesce(sum(f.amount), 0) into v_before_authorized
    from public.ledger_revenue_forecast(3) f where f.band = 'Authorized';

  insert into public.clients (name, stage, status) values ('ZZ Forecast Client', 'Placement', 'Active')
  returning id into v_client;
  insert into public.authorizations (client_id, service_type, rate_type, rate, total_hours, status, end_date)
  values (v_client, 'Job Coaching', 'Hourly', 50, 40, 'Open',
          (public.practice_today() + 60)) returning id into v_auth;
  insert into public.billing_items (client_id, auth_id, service, period, status, billing_type, hours, rate, amount)
  values (v_client, v_auth, 'Job Coaching', v_month, 'Service in progress', 'Hourly', 10, 50, 500)
  returning id into v_item;

  select coalesce(sum(f.amount), 0) - v_before_committed into v_amount
    from public.ledger_revenue_forecast(3) f where f.band = 'Committed';
  if v_amount is distinct from 500 then
    failures := failures || format('FAILED: a 500 item in the pipeline added %s to committed revenue', v_amount)::text;
  else
    raise notice 'ok  an item in the pipeline is committed revenue, in the month its service bills';
  end if;

  -- Authorized 2000, committed 500: the other 1500 is the authorized band,
  -- and the 500 is not in it twice.
  select coalesce(sum(f.amount), 0) - v_before_authorized into v_amount
    from public.ledger_revenue_forecast(3) f where f.band = 'Authorized';
  if v_amount > 1500 + 0.05 then
    failures := failures || format('FAILED: %s is authorized-and-unearned where 1500 is uncovered - the item was counted twice', v_amount)::text;
  else
    raise notice 'ok  an item and the authorization behind it are one expectation, not two';
  end if;

  select count(distinct f.band) into v_n from public.ledger_revenue_forecast(3) f;
  if v_n < 2 then
    failures := failures || 'FAILED: the forecast came back as one undifferentiated number'::text;
  else
    raise notice 'ok  the forecast says which of its figures is committed and which is not';
  end if;

  -- ── what is owed is a fact, not a trend ───────────────────
  select coalesce(sum(f.amount), 0) into v_before_owed
    from public.ledger_cost_forecast(3) f where f.band = 'Owed now';
  insert into public.staff (name, email, role, active)
  values ('ZZ Forecast Contractor', 'zz-forecast@example.test', 'Job Search', true) returning id into v_staff;
  perform public.post_journal(v_month, 'ZZ owed', 'Manual', null, '',
    jsonb_build_array(
      jsonb_build_object('account', public.ledger_account('contractor_cost'), 'debit', 900, 'staff_id', v_staff),
      jsonb_build_object('account', public.ledger_account('contractor_payable'), 'credit', 900, 'staff_id', v_staff)));

  select coalesce(sum(f.amount), 0) - v_before_owed into v_amount
    from public.ledger_cost_forecast(3) f where f.band = 'Owed now';
  if v_amount is distinct from 900 then
    failures := failures || format('FAILED: 900 newly owed moved the forecast by %s', v_amount)::text;
  else
    raise notice 'ok  what is already owed is forecast as owed, not as an average';
  end if;

  -- ── and says nothing before the books open ────────────────
  --
  -- No postings is not the same as no money. Reading it as no money would
  -- show the practice running to nothing all through the autumn, and the
  -- cash-floor alert would fire nightly, in red, about a balance nobody is
  -- keeping yet.
  update public.ledger_settings set books_start = date '2027-01-01' where entity_id = v_entity;
  select count(*) into v_n from public.ledger_cash_forecast(90);
  if v_n <> 0 then
    failures := failures || format('FAILED: %s weeks of cash forecast before the books open', v_n)::text;
  else
    raise notice 'ok  the cash forecast says nothing until there is a balance to forecast from';
  end if;
  update public.ledger_settings set books_start = date '2020-01-01' where entity_id = v_entity;

  -- ── cash carries forward ──────────────────────────────────
  select f.closing into v_amount from public.ledger_cash_forecast(90) f order by f.week limit 1;
  if v_amount is null then
    failures := failures || 'FAILED: the cash forecast came back empty'::text;
  else
    select count(*) into v_n
      from (select f.week, f.opening, f.closing,
                   lag(f.closing) over (order by f.week) as previous
              from public.ledger_cash_forecast(90) f) t
     where t.previous is not null and t.opening <> t.previous;
    if v_n > 0 then
      failures := failures || format('FAILED: %s week(s) of the cash forecast do not open where the last one closed', v_n)::text;
    else
      raise notice 'ok  each week of the cash forecast opens where the last one closed';
    end if;
  end if;

  -- ── the payment lag is measured, not assumed ──────────────
  update public.billing_items
     set status = 'Paid', service_end = public.practice_today() - 55,
         submitted_at = (public.practice_today() - 50)::timestamptz,
         recipient = 'ZZ USOR', paid_on = public.practice_today() - 30, paid_amount = 500
   where id = v_item;
  if public.ledger_payment_lag() <> 20 then
    failures := failures || format('FAILED: twenty days from sent to paid measured as %s', public.ledger_payment_lag())::text;
  else
    raise notice 'ok  how long USOR takes to pay is measured from what it has actually done';
  end if;

  -- ── the alerts, when the owner asked for them ─────────────
  update public.ledger_settings set budget_tolerance = 50, cash_floor = null where entity_id = v_entity;
  perform public.generate_notifications_on(public.practice_today());
  select count(*) into v_n from public.notifications
   where kind = 'budget_over' and resolved_at is null;
  if v_n <> 0 then
    failures := failures || 'FAILED: an account 20% over budget was reported at a 50% tolerance'::text;
  else
    raise notice 'ok  an account inside the owner''s tolerance is not reported';
  end if;

  update public.ledger_settings set budget_tolerance = 10 where entity_id = v_entity;
  perform public.generate_notifications_on(public.practice_today());
  select count(*), max(text) into v_n, v_text from public.notifications
   where kind = 'budget_over' and resolved_at is null;
  if v_n <> 1 then
    failures := failures || format('FAILED: %s budget alerts where one account is over', v_n)::text;
  elsif v_text not like '%over its budget%' then
    failures := failures || format('FAILED: the budget alert says "%s"', v_text)::text;
  else
    raise notice 'ok  an account past the tolerance is reported, once, saying by how much';
  end if;

  select count(*) into v_n from public.notifications where kind = 'cash_floor' and resolved_at is null;
  if v_n <> 0 then
    failures := failures || 'FAILED: a cash alert was raised with no floor set'::text;
  else
    raise notice 'ok  no floor means the owner has not asked to be warned';
  end if;

  -- A floor above anything the forecast reaches: one alert, not thirteen.
  update public.ledger_settings set cash_floor = 100000000 where entity_id = v_entity;
  perform public.generate_notifications_on(public.practice_today());
  select count(*) into v_n from public.notifications where kind = 'cash_floor' and resolved_at is null;
  if v_n <> 1 then
    failures := failures || format('FAILED: %s cash alerts for one forecast that dips below the floor', v_n)::text;
  else
    raise notice 'ok  the cash forecast dipping below the floor is said once, naming the week';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
