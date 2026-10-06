-- Zion Vocational Rehab CRM — the cash forecast waits for the books (E2)
--
-- The books open on 1 January 2027, so for the next three months there are no
-- postings at all. Every report handles that correctly by being empty - except
-- the cash forecast, which would read "no postings" as "no money" and show the
-- practice running to nothing. Worse, the cash-floor alert would then fire
-- every night, in red, about a balance that is simply not being kept yet.
--
-- An alert that is wrong three months running is an alert nobody reads on the
-- day it is right. So the forecast says nothing until there is a balance to
-- forecast from, and the screen says why in one sentence.
--
-- The revenue and cost forecasts are left alone, and that is deliberate: they
-- are built from billing items and authorizations, which are real today, so
-- they are worth reading before the ledger exists. Only the cash side needs a
-- starting balance, and only the cash side waits.

create or replace function public.ledger_cash_forecast(p_days integer default 90)
returns table (
  week date, opening numeric, expected_in numeric, expected_out numeric, closing numeric
) language sql stable set search_path = public as $$
  with open_books as (
    select bool_or(s.books_start <= public.practice_today()) as yes
      from public.ledger_settings s
     where s.entity_id in (select public.my_entities())
  ),
  start as (
    select coalesce(sum(l.debit) - sum(l.credit), 0) as cash
      from public.journal_lines l
     where l.account_id in (select public.ledger_cash_accounts())
  ),
  weeks as (
    select (date_trunc('week', public.practice_today()) + (n || ' weeks')::interval)::date as week
      from generate_series(0, greatest(1, (p_days / 7)::int)) n
     where (select yes from open_books)
  ),
  lag as (select public.ledger_payment_lag() as days),
  receivable as (
    select date_trunc('week', i.submitted_at::date + (select days from lag))::date as week,
           sum(coalesce(i.amount, i.hours * i.rate)) as amount
      from public.billing_items i
     where i.status in ('Submitted', 'Pending')
       and i.submitted_at is not null
     group by 1
  ),
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
  'Cash by week for the next ninety days (0146), and nothing at all until the books open (0153) - because no postings is not the same as no money.';

revoke all on function public.ledger_cash_forecast(integer) from anon, authenticated;
grant execute on function public.ledger_cash_forecast(integer) to authenticated;
