-- Zion Vocational Rehab CRM — budget and forecast (ERP brief, E2)
--
-- A budget is a number somebody typed and a forecast is a number the CRM
-- worked out, and the two must never be allowed to look alike. So the budget
-- is a table and the forecast is a function: nothing about a forecast is
-- stored, it is recomputed every time it is asked for, and it carries on its
-- face which of three things each figure is.
--
--   Committed      work already in the pipeline: a billing item that exists
--                  and has not been submitted yet. The practice knows the
--                  amount and roughly the month.
--   Authorized     money USOR has authorized and the practice has not yet
--                  earned, where no item covers it. Real, less certain.
--   From the trend referrals that have not been authorized at all. An
--                  estimate from the last six months, and said to be one.
--
-- A forecast that mixes those three is a forecast nobody trusts, and a
-- forecast nobody trusts is a report that gets ignored on exactly the month
-- it mattered. They are separate rows on every report here.

-- ── what somebody budgeted ─────────────────────────────────
create table if not exists public.ledger_budgets (
  entity_id uuid not null references public.ledger_entities(id) on delete cascade,
  account_id uuid not null references public.ledger_accounts(id) on delete cascade,
  month date not null,
  amount numeric(14, 2) not null,
  note text not null default '',
  updated_at timestamptz not null default now(),
  updated_by uuid references public.staff(id) on delete set null,
  primary key (entity_id, account_id, month),
  constraint ledger_budgets_is_a_month check (date_trunc('month', month)::date = month)
);

comment on table public.ledger_budgets is
  'What the practice meant to earn and spend, by account and month (0146). Typed by a person; actuals come from the ledger.';

drop trigger if exists ledger_budgets_updated_at on public.ledger_budgets;
create trigger ledger_budgets_updated_at before update on public.ledger_budgets
  for each row execute function public.set_updated_at();

alter table public.ledger_budgets enable row level security;

drop policy if exists ledger_budgets_read on public.ledger_budgets;
create policy ledger_budgets_read on public.ledger_budgets for select to authenticated
  using ((select public.may_read_books()));

drop policy if exists ledger_budgets_write on public.ledger_budgets;
create policy ledger_budgets_write on public.ledger_budgets for all to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));

grant select, insert, update, delete on public.ledger_budgets to authenticated;

-- ── the floor the owner sets ───────────────────────────────
alter table public.ledger_settings
  add column if not exists cash_floor numeric(14, 2),
  add column if not exists budget_tolerance numeric(5, 2) not null default 10;

comment on column public.ledger_settings.cash_floor is
  'The balance the owner wants to be warned before the forecast drops below (0146). Null means do not warn.';
comment on column public.ledger_settings.budget_tolerance is
  'How far over budget an account goes before it is worth saying, as a percentage (0146). A budget nobody set is never over.';

-- ─────────────────────────────────────────────────────────────
-- Budget against actual
-- ─────────────────────────────────────────────────────────────
create or replace function public.ledger_budget_variance(p_from date, p_to date)
returns table (
  account_id uuid, code text, name text, kind text,
  budget numeric, actual numeric, variance numeric, over boolean
) language sql stable set search_path = public as $$
  with months as (
    select generate_series(date_trunc('month', p_from), date_trunc('month', p_to), interval '1 month')::date as month
  ),
  budgeted as (
    select b.account_id, sum(b.amount) as amount
      from public.ledger_budgets b
      join months m on m.month = b.month
     group by b.account_id
  ),
  actual as (
    select l.account_id,
           case when a.kind = 'Revenue'
                then sum(l.credit) - sum(l.debit)
                else sum(l.debit) - sum(l.credit) end as amount
      from public.journal_lines l
      join public.journals j on j.id = l.journal_id
      join public.ledger_accounts a on a.id = l.account_id
     where a.kind in ('Revenue', 'Expense')
       and j.entry_date between p_from and p_to
     group by l.account_id, a.kind
  )
  select a.id, a.code, a.name, a.kind,
         coalesce(b.amount, 0), coalesce(x.amount, 0),
         -- Positive is good either way: revenue above budget, cost below it.
         case when a.kind = 'Revenue'
              then coalesce(x.amount, 0) - coalesce(b.amount, 0)
              else coalesce(b.amount, 0) - coalesce(x.amount, 0) end,
         -- "Over budget" means over on cost. An account nobody budgeted is
         -- never over: a zero somebody never typed is not a promise.
         a.kind = 'Expense' and b.amount is not null and coalesce(x.amount, 0) > b.amount
    from public.ledger_accounts a
    left join budgeted b on b.account_id = a.id
    left join actual x on x.account_id = a.id
   where a.kind in ('Revenue', 'Expense')
     and (b.amount is not null or x.amount is not null)
   order by a.code;
$$;

comment on function public.ledger_budget_variance is
  'Budget and actual side by side for a period, with the sign the same way round for revenue and cost (0146).';

-- ─────────────────────────────────────────────────────────────
-- What is expected to come in
--
-- Three bands, never summed into one number by this function. The screen
-- adds them up where it says it is doing so.
-- ─────────────────────────────────────────────────────────────
create or replace function public.ledger_revenue_forecast(p_months integer default 3)
returns table (month date, band text, amount numeric, note text)
language sql stable set search_path = public as $$
  with horizon as (
    select date_trunc('month', public.practice_today())::date as first_month,
           (date_trunc('month', public.practice_today()) + (p_months || ' months')::interval)::date as last_month
  ),
  /**
   * Committed: an item that exists and has not been billed.
   *
   * The month it is expected in comes from the service's own rule, which is
   * the practice's rule and not the software's: a monthly service bills the
   * month it covers, a one-time one bills when the service finishes, and Job
   * Placement bills a fixed number of weeks after the client's first day of
   * work.
   */
  committed as (
    select greatest(
             date_trunc('month', coalesce(
               case r.ready_rule
                 when 'month complete' then i.period
                 when 'weeks after first work day'
                   then i.first_work_day + (coalesce(r.ready_weeks, 4) * 7)
                 else coalesce(i.service_end, i.service_start)
               end,
               public.practice_today()))::date,
             (select first_month from horizon)) as month,
           coalesce(i.amount, round(coalesce(i.hours, 0) * coalesce(i.rate, 0), 2)) as amount,
           i.auth_id
      from public.billing_items i
      join public.billing_service_rules r on r.service = i.service
     where i.status not in ('Submitted', 'Pending', 'Paid', 'Closed')
       and coalesce(i.amount, coalesce(i.hours, 0) * coalesce(i.rate, 0)) > 0
  ),
  /**
   * Authorized and not covered: what USOR has authorized, less what has been
   * earned, less whatever the committed items above already account for.
   * Spread evenly to the authorization's end date, because nothing in the
   * record says which month it will actually be worked.
   */
  uncovered as (
    select e.auth_id,
           greatest(
             e.authorized - e.earned - coalesce((select sum(c.amount) from committed c where c.auth_id = e.auth_id), 0),
             0) as amount,
           greatest(
             1,
             least(
               p_months + 1,
               case when e.end_date is null then 3
                    else greatest(1, (extract(year from e.end_date) * 12 + extract(month from e.end_date))::int
                                     - (extract(year from public.practice_today()) * 12
                                        + extract(month from public.practice_today()))::int + 1)
               end))::int as spread
      from public.authorization_economics e
     where e.status = 'Open'
  ),
  /**
   * The referral trend: people who have been referred and have no
   * authorization yet, valued at what a client has been worth on average
   * over the last six months. An estimate, shown as one, and placed two
   * months out because that is roughly how long referral to authorization
   * has taken.
   */
  per_client as (
    select coalesce(avg(total), 0) as amount
      from (
        select i.client_id, sum(coalesce(i.amount, i.hours * i.rate)) as total
          from public.billing_items i
         where i.created_at >= public.practice_today() - 180
         group by i.client_id
      ) t
  ),
  referred as (
    select count(*)::numeric as clients
      from public.clients c
     where c.status = 'Active'
       and c.stage in ('Referral', 'Intake')
       and not exists (select 1 from public.authorizations a where a.client_id = c.id)
  )
  select c.month, 'Committed', sum(c.amount),
         'Items in the pipeline, in the month their service bills'
    from committed c
   where c.month <= (select last_month from horizon)
   group by c.month

  union all

  select m.month, 'Authorized', sum(round(u.amount / u.spread, 2)),
         'Authorized and not yet earned, spread to the authorization''s end date'
    from uncovered u
    cross join lateral (
      select (date_trunc('month', public.practice_today()) + (n || ' months')::interval)::date as month
        from generate_series(0, u.spread - 1) n
    ) m
   where u.amount > 0
     and m.month <= (select last_month from horizon)
   group by m.month

  union all

  select (date_trunc('month', public.practice_today()) + interval '2 months')::date, 'From the trend',
         round((select clients from referred) * (select amount from per_client), 2),
         (select clients from referred)::text || ' referred and not yet authorized, at the average of the last six months'
   where (select clients from referred) > 0
     and (select amount from per_client) > 0
     and (date_trunc('month', public.practice_today()) + interval '2 months')::date
         <= (select last_month from horizon)

   order by 1, 2;
$$;

comment on function public.ledger_revenue_forecast is
  'What is expected to come in, in three bands that are never summed together here (0146).';

-- ─────────────────────────────────────────────────────────────
-- What is expected to go out
-- ─────────────────────────────────────────────────────────────
create or replace function public.ledger_cost_forecast(p_months integer default 3)
returns table (month date, band text, amount numeric, note text)
language sql stable set search_path = public as $$
  with recent as (
    select date_trunc('month', j.entry_date)::date as month,
           a.role = 'contractor_cost' as is_contractor,
           sum(l.debit) - sum(l.credit) as amount
      from public.journals j
      join public.journal_lines l on l.journal_id = j.id
      join public.ledger_accounts a on a.id = l.account_id
     where a.kind = 'Expense'
       and j.entry_date >= (date_trunc('month', public.practice_today()) - interval '3 months')::date
       and j.entry_date < date_trunc('month', public.practice_today())::date
     group by 1, 2
  ),
  -- The average of the last three finished months, which is the only honest
  -- thing to say about a cost nobody has committed to yet.
  averages as (
    select is_contractor, coalesce(avg(amount), 0) as amount
      from recent group by is_contractor
  ),
  months as (
    select (date_trunc('month', public.practice_today()) + (n || ' months')::interval)::date as month
      from generate_series(0, greatest(p_months, 0)) n
  ),
  -- What is already owed and not yet paid out: not a trend, a fact.
  owed as (
    select coalesce(sum(l.credit) - sum(l.debit), 0) as amount
      from public.journal_lines l
      join public.ledger_accounts a on a.id = l.account_id
     where a.role in ('contractor_payable', 'ap')
  )
  select m.month, 'Owed now', (select amount from owed),
         'Approved statements and claims not yet paid out'
    from months m
   where m.month = date_trunc('month', public.practice_today())::date
     and (select amount from owed) > 0

  union all

  select m.month,
         case when av.is_contractor then 'Contractor cost' else 'Running costs' end,
         round(av.amount, 2),
         'The average of the last three finished months'
    from months m
    cross join averages av
   where av.amount > 0

   order by 1, 2;
$$;

comment on function public.ledger_cost_forecast is
  'What is expected to go out: what is already owed, and the average of the last three finished months (0146).';

-- ─────────────────────────────────────────────────────────────
-- Cash, ninety days out
--
-- Money the practice has, plus what is expected in, less what is expected
-- out, by week. Receipts carry the lag the practice actually experiences:
-- the median days from submitting an item to being paid for it, measured
-- from its own history rather than assumed.
-- ─────────────────────────────────────────────────────────────
create or replace function public.ledger_payment_lag()
returns integer language sql stable set search_path = public as $$
  select coalesce(
    (select percentile_cont(0.5) within group (order by (i.paid_on - i.submitted_at::date))::integer
       from public.billing_items i
      where i.paid_on is not null and i.submitted_at is not null
        and i.paid_on >= i.submitted_at::date
        and i.submitted_at >= public.practice_today() - 365),
    30);
$$;

comment on function public.ledger_payment_lag is
  'How long submitting an item to being paid for it has actually taken, in days (0146). Thirty when there is no history.';

create or replace function public.ledger_cash_forecast(p_days integer default 90)
returns table (
  week date, opening numeric, expected_in numeric, expected_out numeric, closing numeric
) language sql stable set search_path = public as $$
  with start as (
    select coalesce(sum(l.debit) - sum(l.credit), 0) as cash
      from public.journal_lines l
     where l.account_id in (select public.ledger_cash_accounts())
  ),
  weeks as (
    select (date_trunc('week', public.practice_today()) + (n || ' weeks')::interval)::date as week
      from generate_series(0, greatest(1, (p_days / 7)::int)) n
  ),
  lag as (select public.ledger_payment_lag() as days),
  -- Billed, unpaid, and expected the usual number of days after it was sent.
  receivable as (
    select date_trunc('week', i.submitted_at::date + (select days from lag))::date as week,
           sum(coalesce(i.amount, i.hours * i.rate)) as amount
      from public.billing_items i
     where i.status in ('Submitted', 'Pending')
       and i.submitted_at is not null
     group by 1
  ),
  -- The forecast months, spread across their weeks, so a month's expectation
  -- does not all land on the first.
  coming as (
    select f.month, sum(f.amount) as amount
      from public.ledger_revenue_forecast(greatest(1, (p_days / 30)::int)) f
     group by f.month
  ),
  going as (
    select f.month, sum(f.amount) as amount
      from public.ledger_cost_forecast(greatest(1, (p_days / 30)::int)) f
     group by f.month
  ),
  flow as (
    select w.week,
           coalesce((select amount from receivable r where r.week = w.week), 0)
             + coalesce((select round(c.amount / 4.0, 2) from coming c
                          where c.month = date_trunc('month', w.week)::date), 0) as in_,
           coalesce((select round(g.amount / 4.0, 2) from going g
                      where g.month = date_trunc('month', w.week)::date), 0) as out_
      from weeks w
  )
  select f.week,
         (select cash from start)
           + coalesce(sum(f.in_ - f.out_) over (order by f.week
               rows between unbounded preceding and 1 preceding), 0),
         f.in_, f.out_,
         (select cash from start)
           + sum(f.in_ - f.out_) over (order by f.week
               rows between unbounded preceding and current row)
    from flow f
   order by f.week;
$$;

comment on function public.ledger_cash_forecast is
  'Cash by week for the next ninety days: what is there, what is expected in, what is expected out (0146).';

-- ── who may run them ───────────────────────────────────────
do $$
declare f text;
begin
  foreach f in array array[
    'ledger_budget_variance(date, date)',
    'ledger_revenue_forecast(integer)',
    'ledger_cost_forecast(integer)',
    'ledger_payment_lag()',
    'ledger_cash_forecast(integer)'
  ] loop
    execute format('revoke all on function public.%s from anon, authenticated', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

-- The new tables refuse writes from the automated accounts, like every other.
do $$
declare r record;
begin
  for r in
    select c.oid::regclass as t
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity
  loop
    perform public.apply_system_read_only(r.t);
  end loop;
end $$;
