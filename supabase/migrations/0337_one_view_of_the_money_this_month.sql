-- Zion Vocational Rehab CRM — one view of the money this month
--
-- "Billing overview as the Billing landing page: This month — Submitted,
-- Paid, To bill (Due), Overdue count; four lists; the Home Billing tile reads
-- the same view."
--
-- Four figures and four counts, answered once. The figures were each
-- obtainable before and none of them was anywhere: the Billing tab opened on
-- a list of authorizations, Invoices had its own three totals at the foot of
-- a filtered table, and the money roll-ups were on Admin's Money screen,
-- which is a different question asked over a different period.
--
-- What makes this worth a function rather than four queries on a page is the
-- last sentence of the ruling. The Home tile reads the same view, so the
-- number on the dashboard and the number on the screen it opens cannot
-- disagree — which is the fault that has cost this practice the most: the
-- same question answered twice, slightly differently, in two places.
--
-- "To bill" and "Overdue" are the owner's ruling of the same morning:
-- delivered and not invoiced is the work to bill, and fourteen days of that
-- is the only thing the practice chases. A bill-by date that has gone by with
-- nothing delivered is neither.

begin;

create or replace function public.billing_overview(p_today date DEFAULT NULL::date)
returns table(
  month_start date,
  submitted_this_month numeric,
  submitted_count integer,
  paid_this_month numeric,
  paid_count integer,
  to_bill numeric,
  to_bill_count integer,
  overdue_count integer,
  outstanding numeric,
  outstanding_count integer,
  needs_attention integer
)
language sql
stable
security definer
set search_path to 'public'
as $$
  select * from (
    with me as (select coalesce(p_today, public.practice_today()) as today),
    month as (
      select date_trunc('month', (select today from me))::date as from_day,
             (date_trunc('month', (select today from me)) + interval '1 month')::date as to_day
    ),
    -- What went out this month, from the invoice ledger: the record of what
    -- was actually sent, which is what Phase 3 made the ledger for.
    sent as (
      select coalesce(sum(i.amount), 0) as amount, count(*)::int as n
        from public.invoices i, month
       where i.submitted_on >= month.from_day and i.submitted_on < month.to_day
    ),
    -- And what came back, from the payments, by the day the warrant is
    -- dated rather than the day somebody typed it in.
    received as (
      select coalesce(sum(y.amount), 0) as amount, count(*)::int as n
        from public.payments y, month
       where coalesce(y.warrant_date, y.created_at::date) >= month.from_day
         and coalesce(y.warrant_date, y.created_at::date) < month.to_day
    ),
    -- Still with USOR: sent, and not paid in full. Not "everything but
    -- Paid" - a rejected invoice is not money owed, it is an invoice to
    -- raise again.
    open_invoices as (
      select coalesce(sum(i.amount - coalesce(i.amount_paid, 0)), 0) as amount,
             count(*)::int as n
        from public.invoices i
       where i.status in ('Submitted', 'Short-paid')
    ),
    -- The work to bill: delivered, and no invoice raised for it.
    work as (
      select coalesce(sum(w.amount), 0) as amount,
             count(*)::int as n,
             count(*) filter (
               where w.delivered_on is not null
                 and (select today from me) - w.delivered_on >= 14)::int as late
        from public.billing_worklist(p_today) w
       where w.delivered_on is not null and not w.invoiced
    )
    select (select from_day from month),
           sent.amount, sent.n,
           received.amount, received.n,
           work.amount, work.n, work.late,
           open_invoices.amount, open_invoices.n,
           public.billing_needs_action(p_today)
      from sent, received, work, open_invoices
  ) as rows_for_staff
   where public.reader_may_answer();
$$;

comment on function public.billing_overview is
  'The month in six figures and five counts: what was invoiced, what came '
  'back, what is still with USOR, what is delivered and not yet invoiced, '
  'how much of that has waited a fortnight, and how many rows need '
  'something. The Billing landing page and the Home tile both read it.';

revoke all on function public.billing_overview(date) from public, anon;
grant execute on function public.billing_overview(date) to authenticated, service_role;

commit;
