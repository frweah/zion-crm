-- Zion Vocational Rehab CRM — the reports (E1)
--
-- Seven reports and a tie-out, all from one ledger. None of them stores a
-- figure: every number here is a sum of postings, so a report cannot drift
-- away from the books and there is no "rebuild the totals" job to forget to
-- run. The cost is that a report is a query; the practice has hundreds of
-- clients, not millions, and the honest trade is the right way round.
--
-- All of these read the ledger as whoever is asking - no security definer -
-- so the database's own rule about who may see the books is the only rule
-- there is. A second copy of it inside each function is a second thing to
-- get wrong.
--
-- Cash and accrual, from one set of postings
--
--   Accrual is the plain reading: revenue when the item was submitted, cost
--   when the statement was approved. Sum the revenue and expense accounts.
--
--   Cash is harder and matters more here, because USOR pays on warrant and
--   the owner's question all year is what came in. A payment credits
--   Accounts receivable, not revenue, so cash revenue cannot be read off the
--   accounts - which is why every posting that moves cash carries the
--   revenue or expense account it belongs to. Cash basis is then: for each
--   posting, what it did to a cash account, classified by what it was for.
--   A deposit moves money between two cash accounts and nets to nothing,
--   which is correct: banking a warrant is not income twice.

-- ── what counts as cash ────────────────────────────────────
create or replace function public.ledger_cash_accounts()
returns setof uuid language sql stable set search_path = public as $$
  select a.id
    from public.ledger_accounts a
    join public.ledger_entities e on e.id = a.entity_id and e.is_default
   where a.role in ('bank', 'undeposited');
$$;

comment on function public.ledger_cash_accounts is
  'The accounts that are money the practice has (0144): at the bank, and in hand and not yet banked.';

-- ── trial balance ──────────────────────────────────────────
create or replace function public.ledger_trial_balance(p_as_of date)
returns table (
  code text, name text, kind text,
  debits numeric, credits numeric, balance numeric
) language sql stable set search_path = public as $$
  select a.code, a.name, a.kind,
         coalesce(sum(l.debit), 0),
         coalesce(sum(l.credit), 0),
         -- Signed the way the account reads: an asset or expense is positive
         -- when it has been debited, a liability, equity or revenue when it
         -- has been credited. A trial balance with half its lines negative
         -- is a trial balance nobody can check by eye.
         case when a.kind in ('Asset', 'Expense')
              then coalesce(sum(l.debit), 0) - coalesce(sum(l.credit), 0)
              else coalesce(sum(l.credit), 0) - coalesce(sum(l.debit), 0) end
    from public.ledger_accounts a
    left join public.journal_lines l on l.account_id = a.id
    left join public.journals j on j.id = l.journal_id and j.entry_date <= p_as_of
   where l.id is null or j.id is not null
   group by a.id, a.code, a.name, a.kind
  having coalesce(sum(l.debit), 0) <> 0 or coalesce(sum(l.credit), 0) <> 0
   order by a.code;
$$;

comment on function public.ledger_trial_balance is
  'Every account with a posting, as of a day, signed the way the account reads (0144).';

-- ── profit and loss ────────────────────────────────────────
create or replace function public.ledger_profit_and_loss(
  p_from date, p_to date, p_basis text default null
)
returns table (
  code text, name text, kind text, amount numeric
) language sql stable set search_path = public as $$
  with basis as (
    select coalesce(
      nullif(p_basis, ''),
      (select s.basis from public.ledger_settings s
         join public.ledger_entities e on e.id = s.entity_id and e.is_default)) as b
  ),
  -- Accrual: the revenue and expense accounts, as posted.
  accrual as (
    select a.id as account_id,
           case when a.kind = 'Revenue'
                then coalesce(sum(l.credit), 0) - coalesce(sum(l.debit), 0)
                else coalesce(sum(l.debit), 0) - coalesce(sum(l.credit), 0) end as amount
      from public.ledger_accounts a
      join public.journal_lines l on l.account_id = a.id
      join public.journals j on j.id = l.journal_id
     where a.kind in ('Revenue', 'Expense')
       and j.entry_date between p_from and p_to
     group by a.id, a.kind
  ),
  -- Cash: what each posting did to the money, under the heading it was for.
  moved as (
    select j.cash_class_account_id as account_id,
           sum(case when l.account_id in (select public.ledger_cash_accounts())
                    then l.debit - l.credit else 0 end) as cash
      from public.journals j
      join public.journal_lines l on l.journal_id = j.id
     where j.cash_class_account_id is not null
       and j.entry_date between p_from and p_to
     group by j.id, j.cash_class_account_id
  ),
  cash as (
    select m.account_id,
           sum(case when a.kind = 'Revenue' then m.cash else -m.cash end) as amount
      from moved m
      join public.ledger_accounts a on a.id = m.account_id
     where m.cash <> 0
     group by m.account_id
  )
  select a.code, a.name, a.kind, r.amount
    from (
      select account_id, amount from accrual where (select b from basis) = 'Accrual'
      union all
      select account_id, amount from cash where (select b from basis) = 'Cash'
    ) r
    join public.ledger_accounts a on a.id = r.account_id
   where r.amount <> 0
   order by a.code;
$$;

comment on function public.ledger_profit_and_loss is
  'Revenue and cost for a period, on the practice''s basis or whichever is asked for (0144).';

-- ── balance sheet ──────────────────────────────────────────
create or replace function public.ledger_balance_sheet(p_as_of date)
returns table (
  code text, name text, kind text, balance numeric
) language sql stable set search_path = public as $$
  select t.code, t.name, t.kind, t.balance
    from public.ledger_trial_balance(p_as_of) t
   where t.kind in ('Asset', 'Liability', 'Equity')
  union all
  -- What the practice has earned and kept. Not an account anybody posts to:
  -- it is the revenue and cost of every year to date, which is the one line
  -- that makes a balance sheet balance.
  select '3999', 'Earnings to date', 'Equity',
         coalesce((select sum(case when t.kind = 'Revenue' then t.balance else -t.balance end)
                     from public.ledger_trial_balance(p_as_of) t
                    where t.kind in ('Revenue', 'Expense')), 0)
   order by 1;
$$;

comment on function public.ledger_balance_sheet is
  'What the practice has, owes and is worth on a day, with earnings to date as the line that balances it (0144).';

-- ── cash flow ──────────────────────────────────────────────
create or replace function public.ledger_cash_flow(p_from date, p_to date)
returns table (
  month date, money_in numeric, money_out numeric, net numeric, closing numeric
) language sql stable set search_path = public as $$
  with movement as (
    select date_trunc('month', j.entry_date)::date as month,
           sum(l.debit) as in_, sum(l.credit) as out_
      from public.journals j
      join public.journal_lines l on l.journal_id = j.id
     where l.account_id in (select public.ledger_cash_accounts())
       and j.entry_date between p_from and p_to
     group by 1
  ),
  -- The balance brought forward, so the first month reads as a statement
  -- does rather than starting from nothing.
  opening as (
    select coalesce(sum(l.debit) - sum(l.credit), 0) as balance
      from public.journals j
      join public.journal_lines l on l.journal_id = j.id
     where l.account_id in (select public.ledger_cash_accounts())
       and j.entry_date < p_from
  )
  select m.month, m.in_, m.out_, m.in_ - m.out_,
         (select balance from opening)
           + sum(m.in_ - m.out_) over (order by m.month rows between unbounded preceding and current row)
    from movement m
   order by m.month;
$$;

comment on function public.ledger_cash_flow is
  'Money in, out and left, month by month, carrying the balance forward (0144).';

-- ── what is owed to contractors, and how old it is ─────────
create or replace function public.ledger_ap_aging(p_as_of date)
returns table (
  staff_id uuid, person text, bucket text, amount numeric
) language sql stable set search_path = public as $$
  with owed as (
    select l.staff_id,
           j.entry_date,
           sum(l.credit) - sum(l.debit) as amount
      from public.journals j
      join public.journal_lines l on l.journal_id = j.id
     where l.account_id in (
             select a.id from public.ledger_accounts a
              join public.ledger_entities e on e.id = a.entity_id and e.is_default
              where a.role in ('contractor_payable', 'ap'))
       and j.entry_date <= p_as_of
     group by l.staff_id, j.entry_date
  ),
  /**
   * A payout clears the oldest thing owed first, which is what actually
   * happens and is the only assumption that makes an aging report mean
   * anything: without it, paying this month's statement would leave last
   * month's looking unpaid.
   */
  running as (
    select o.staff_id, o.entry_date, o.amount,
           sum(o.amount) over (partition by o.staff_id order by o.entry_date, o.amount) as cumulative,
           sum(o.amount) over (partition by o.staff_id) as net
      from owed o
  )
  select r.staff_id,
         coalesce(s.name, 'Not against a person'),
         case
           when p_as_of - r.entry_date <= 30 then 'Current'
           when p_as_of - r.entry_date <= 60 then '31 to 60 days'
           when p_as_of - r.entry_date <= 90 then '61 to 90 days'
           else 'Over 90 days'
         end,
         -- Only the part still outstanding: everything older than the amount
         -- already paid is settled.
         greatest(least(r.amount, r.net - (r.cumulative - r.amount)), 0)
    from running r
    left join public.staff s on s.id = r.staff_id
   where r.net > 0
     and greatest(least(r.amount, r.net - (r.cumulative - r.amount)), 0) > 0
   order by 2, r.entry_date;
$$;

comment on function public.ledger_ap_aging is
  'What the practice still owes each contractor, by how long it has been owed (0144). Payouts clear the oldest first.';

-- ── one account, line by line ──────────────────────────────
create or replace function public.ledger_general_ledger(
  p_account uuid, p_from date, p_to date
)
returns table (
  journal_id uuid, entry_date date, memo text, source_kind text, source_id uuid,
  debit numeric, credit numeric, running numeric, client text, person text
) language sql stable set search_path = public as $$
  with opening as (
    select coalesce(sum(l.debit) - sum(l.credit), 0) as balance
      from public.journals j
      join public.journal_lines l on l.journal_id = j.id
     where l.account_id = p_account and j.entry_date < p_from
  )
  select j.id, j.entry_date, j.memo, j.source_kind, j.source_id,
         l.debit, l.credit,
         (select balance from opening)
           + sum(l.debit - l.credit) over (order by j.entry_date, j.created_at, l.id
                                           rows between unbounded preceding and current row),
         coalesce(c.name, ''), coalesce(s.name, '')
    from public.journals j
    join public.journal_lines l on l.journal_id = j.id
    left join public.clients c on c.id = l.client_id
    left join public.staff s on s.id = l.staff_id
   where l.account_id = p_account
     and j.entry_date between p_from and p_to
   order by j.entry_date, j.created_at, l.id;
$$;

comment on function public.ledger_general_ledger is
  'Every posting to one account in a period, with the balance running through it (0144).';

-- ── revenue, cut three ways ────────────────────────────────
create or replace function public.ledger_revenue_by(
  p_from date, p_to date, p_dimension text default 'service'
)
returns table (label text, amount numeric) language sql stable set search_path = public as $$
  select case p_dimension
           when 'office'    then coalesce(nullif(l.office, ''), 'No office on the record')
           when 'counselor' then coalesce(k.name, 'No counselor on the record')
           else coalesce(nullif(l.service, ''), 'No service named')
         end,
         sum(l.credit) - sum(l.debit)
    from public.journals j
    join public.journal_lines l on l.journal_id = j.id
    join public.ledger_accounts a on a.id = l.account_id and a.kind = 'Revenue'
    left join public.counselors k on k.id = l.counselor_id
   where j.entry_date between p_from and p_to
   group by 1
  having sum(l.credit) - sum(l.debit) <> 0
   order by 2 desc;
$$;

comment on function public.ledger_revenue_by is
  'Revenue for a period by service, office or counselor (0144).';

create or replace function public.ledger_contractor_cost(p_from date, p_to date)
returns table (staff_id uuid, person text, amount numeric)
language sql stable set search_path = public as $$
  select l.staff_id, coalesce(s.name, 'Not against a person'),
         sum(l.debit) - sum(l.credit)
    from public.journals j
    join public.journal_lines l on l.journal_id = j.id
    join public.ledger_accounts a on a.id = l.account_id
    left join public.staff s on s.id = l.staff_id
   where a.role = 'contractor_cost'
     and j.entry_date between p_from and p_to
   group by l.staff_id, s.name
  having sum(l.debit) - sum(l.credit) <> 0
   order by 3 desc;
$$;

comment on function public.ledger_contractor_cost is
  'What each contractor cost the practice in a period (0144).';

-- ─────────────────────────────────────────────────────────────
-- The 1099 tie-out
--
-- Three numbers that have to be the same: what the practice recorded paying
-- a contractor, what the ledger says left the bank for them, and what their
-- 1099 said. The year-end package is wrong if they differ, and the time to
-- find that out is December, not the following August.
-- ─────────────────────────────────────────────────────────────
create or replace function public.ledger_1099_tie_out(p_year integer)
returns table (
  staff_id uuid, person text,
  recorded numeric, posted numeric, on_the_1099 numeric, difference numeric
) language sql stable set search_path = public as $$
  with recorded as (
    select p.staff_id, sum(p.amount) as amount
      from public.contractor_payments p
     where extract(year from p.paid_on) = p_year
     group by p.staff_id
  ),
  posted as (
    select l.staff_id, sum(l.debit) - sum(l.credit) as amount
      from public.journals j
      join public.journal_lines l on l.journal_id = j.id
      join public.ledger_accounts a on a.id = l.account_id and a.role = 'contractor_payable'
     where extract(year from j.entry_date) = p_year
       and j.source_kind = 'Contractor payment'
     group by l.staff_id
  ),
  -- The latest run for the year, and the correction if one was issued.
  filed as (
    select r.staff_id, r.nonemployee_comp as amount
      from public.form_1099_recipients r
      join public.form_1099_runs u on u.id = r.run_id
     where u.year = p_year
       and r.id = (
         select r2.id from public.form_1099_recipients r2
           join public.form_1099_runs u2 on u2.id = r2.run_id
          where u2.year = p_year and r2.staff_id = r.staff_id
          order by r2.created_at desc limit 1)
  )
  select coalesce(rec.staff_id, pos.staff_id, f.staff_id),
         coalesce(s.name, 'Unknown'),
         coalesce(rec.amount, 0), coalesce(pos.amount, 0), coalesce(f.amount, 0),
         coalesce(rec.amount, 0) - coalesce(pos.amount, 0)
    from recorded rec
    full join posted pos on pos.staff_id = rec.staff_id
    full join filed f on f.staff_id = coalesce(rec.staff_id, pos.staff_id)
    left join public.staff s on s.id = coalesce(rec.staff_id, pos.staff_id, f.staff_id)
   order by 2;
$$;

comment on function public.ledger_1099_tie_out is
  'What was recorded paid, what the ledger posted, and what the 1099 said, per contractor (0144).';

-- ── who may run them ───────────────────────────────────────
do $$
declare f text;
begin
  foreach f in array array[
    'ledger_cash_accounts()',
    'ledger_trial_balance(date)',
    'ledger_profit_and_loss(date, date, text)',
    'ledger_balance_sheet(date)',
    'ledger_cash_flow(date, date)',
    'ledger_ap_aging(date)',
    'ledger_general_ledger(uuid, date, date)',
    'ledger_revenue_by(date, date, text)',
    'ledger_contractor_cost(date, date)',
    'ledger_1099_tie_out(integer)'
  ] loop
    execute format('revoke all on function public.%s from anon, authenticated', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
