-- Zion Vocational Rehab CRM — the ledger posts from the authorization
-- (Billing Simplification Brief §1, carrying ERP E1 and E2 across)
--
-- The ERP went live on 6 October and posts from the billing item: revenue
-- when the item is submitted, cash when it is paid. §1 removes the billing
-- item, so the postings move to the authorization - and this is the one part
-- of the brief where getting the order wrong loses money quietly rather than
-- loudly. If the trigger were dropped before the new one existed, a month of
-- revenue would simply never be posted and the trial balance would still
-- balance.
--
-- So: the new trigger is created, the old one is dropped in the same
-- migration, and every event name is carried over unchanged. A journal whose
-- source was 'Billing item' keeps that source; new ones say
-- 'Authorization'. Nothing is rewritten in the ledger, because the ledger is
-- append-only and history is not something this brief gets to edit.
--
-- The books open on 1 January 2027, so today every one of these posts
-- nothing at all - post_journal returns null before the start date. That is
-- what makes this safe to deploy in October: the wiring is proven by the
-- verify script against a temporary start date, and the real postings begin
-- when the practice says they begin.

alter table public.journals drop constraint if exists journals_source_kind_check;
alter table public.journals add constraint journals_source_kind_check
  check (source_kind in (
    -- 'Billing item' stays legal: the ledger is append-only, so a posting
    -- made under the old name keeps it.
    'Billing item', 'Authorization',
    'Contractor statement', 'Contractor payment',
    'Expense claim', 'Bank transaction', 'Vendor bill',
    'Depreciation', 'Asset disposal', 'Inter-entity transfer',
    'Manual', 'Opening balance', 'Reversal'));

-- ─────────────────────────────────────────────────────────────
-- What an authorization comes to
--
-- One place, because §11 says so and because the checklist (§12.3), the
-- worklist, the posting and the report all have to agree on it. A flat fee
-- is the rate; hourly is the hours actually logged against this record at
-- the rate on it.
-- ─────────────────────────────────────────────────────────────
create or replace function public.authorization_amount(p_auth uuid)
returns numeric language sql stable set search_path = public as $$
  select case
           when a.rate_type = 'Flat Fee' then round(coalesce(a.rate, 0), 2)
           else round(coalesce((
             select sum(e.hours) from public.service_entries e
              where e.auth_id = a.id and not e.non_billable), 0) * coalesce(a.rate, 0), 2)
         end
    from public.authorizations a where a.id = p_auth;
$$;

comment on function public.authorization_amount is
  'What an authorization comes to: the flat fee, or the hours logged against it at its rate. One place, so the checklist, the list, the posting and the report cannot disagree.';

revoke all on function public.authorization_amount(uuid) from anon, authenticated;
grant execute on function public.authorization_amount(uuid) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- Revenue when it is submitted, cash when it is paid
--
-- The shape is 0142's, corrected by 0154: closing something that was paid
-- does not reverse the money, because closing is an ending and not a
-- correction. That lesson is carried over here rather than relearned.
-- ─────────────────────────────────────────────────────────────
create or replace function public.post_authorization()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_amount  numeric;
  v_revenue uuid;
  v_client  public.clients;
  v_office  text;
  v_live    uuid;
  v_label   text;
begin
  if new.status = old.status then
    return new;
  end if;

  -- A coaching parent is never billed; its months are.
  if exists (select 1 from public.authorizations c where c.parent_id = new.id) then
    return new;
  end if;

  select * into v_client from public.clients where id = new.client_id;
  v_office := coalesce(
    nullif((select office from public.counselors where id = v_client.counselor_id), ''),
    v_client.referring_office, '');
  v_revenue := public.ledger_revenue_account(new.service_type);
  v_label := v_client.name || ' - ' || new.service_type
             || case when new.period is not null
                     then ', ' || to_char(new.period, 'FMMon YYYY') else '' end;

  -- ── submitted: it is owed to the practice now ──
  if new.status = 'Submitted' and old.status <> 'Submitted' then
    v_amount := public.authorization_amount(new.id);
    if v_amount > 0 and public.ledger_live_posting('Authorization', new.id, 'Submitted') is null then
      perform public.post_journal(
        coalesce(new.submitted_on, public.practice_today()),
        v_label || ' submitted',
        'Authorization', new.id,
        public.ledger_next_event('Authorization', new.id, 'Submitted'),
        jsonb_build_array(
          jsonb_build_object('account', public.ledger_account('ar'), 'debit', v_amount,
                             'client_id', new.client_id, 'service', new.service_type,
                             'counselor_id', v_client.counselor_id, 'office', v_office),
          jsonb_build_object('account', v_revenue, 'credit', v_amount,
                             'client_id', new.client_id, 'service', new.service_type,
                             'counselor_id', v_client.counselor_id, 'office', v_office)
        ),
        null, '', null, new.submitted_by,
        coalesce((select name from public.staff where id = new.submitted_by), '')
      );
    end if;
  end if;

  -- ── paid: a warrant in hand, not yet at the bank ──
  if new.status = 'Paid' and old.status <> 'Paid' then
    if coalesce(new.paid_amount, 0) > 0
       and public.ledger_live_posting('Authorization', new.id, 'Paid') is null then
      perform public.post_journal(
        coalesce(new.paid_on, public.practice_today()),
        v_label || ' paid'
          || case when coalesce(new.warrant, '') <> '' then ', warrant ' || new.warrant else '' end,
        'Authorization', new.id,
        public.ledger_next_event('Authorization', new.id, 'Paid'),
        jsonb_build_array(
          jsonb_build_object('account', public.ledger_account('undeposited'), 'debit', new.paid_amount,
                             'client_id', new.client_id, 'service', new.service_type,
                             'counselor_id', v_client.counselor_id, 'office', v_office),
          jsonb_build_object('account', public.ledger_account('ar'), 'credit', new.paid_amount,
                             'client_id', new.client_id, 'service', new.service_type,
                             'counselor_id', v_client.counselor_id, 'office', v_office)
        ),
        v_revenue
      );
    end if;
  end if;

  -- ── the receivable stops standing ──
  -- Closed is here: an authorization submitted and then closed has been
  -- refused or abandoned, and what was owed is not owed any more.
  if old.status = 'Submitted' and new.status in ('Due', 'Authorized', 'Closed') then
    v_live := public.ledger_live_posting('Authorization', new.id, 'Submitted');
    if v_live is not null then
      perform public.reverse_journal(v_live, format('Went back to %s', new.status));
    end if;
  end if;

  -- ── the payment stops standing ──
  -- Closed is deliberately not here (0154): closing something that was paid
  -- does not un-pay it, and reversing would take real money off the books.
  if old.status = 'Paid' and new.status in ('Submitted', 'Due', 'Authorized') then
    v_live := public.ledger_live_posting('Authorization', new.id, 'Paid');
    if v_live is not null then
      perform public.reverse_journal(v_live, format('Payment undone: now %s', new.status));
    end if;
  end if;

  return new;
end;
$$;

comment on function public.post_authorization is
  'Revenue when an authorization is submitted, cash when it is paid, a reversal only where one of those came undone. Replaces post_billing_item (§1).';

drop trigger if exists authorizations_post on public.authorizations;
create trigger authorizations_post after update of status on public.authorizations
  for each row execute function public.post_authorization();

-- The billing item no longer posts. Dropped here, in the same migration
-- that created its replacement, so there is no deploy where neither exists.
drop trigger if exists billing_items_post on public.billing_items;

-- ─────────────────────────────────────────────────────────────
-- E2's forecast reads authorizations
-- ─────────────────────────────────────────────────────────────
create or replace function public.ledger_payment_lag()
returns integer language sql stable set search_path = public as $$
  select coalesce(
    (select percentile_cont(0.5) within group (order by (a.paid_on - a.submitted_on))::integer
       from public.authorizations a
      where a.paid_on is not null and a.submitted_on is not null
        and a.paid_on >= a.submitted_on
        and a.submitted_on >= public.practice_today() - 365),
    30);
$$;

comment on function public.ledger_payment_lag is
  'How long submitting to being paid has actually taken, in days. Thirty when there is no history - and the workbook rows have no submission date, which is why they are excluded rather than assumed.';

revoke all on function public.ledger_payment_lag() from anon, authenticated;
grant execute on function public.ledger_payment_lag() to authenticated;

create or replace function public.ledger_revenue_forecast(p_months integer default 3)
returns table (month date, band text, amount numeric, note text)
language sql stable set search_path = public as $$
  with horizon as (
    select date_trunc('month', public.practice_today())::date as first_month,
           (date_trunc('month', public.practice_today()) + (p_months || ' months')::interval)::date as last_month
  ),
  /**
   * Committed: an authorization that exists and has not been billed.
   *
   * The month it is expected in is its own bill-by, which is now a column
   * rather than a rule to re-derive - §3 put it on the record, so the
   * forecast reads it instead of recomputing what the screen already shows.
   */
  committed as (
    select greatest(date_trunc('month', coalesce(a.bill_by, public.practice_today()))::date,
                    (select first_month from horizon)) as month,
           public.authorization_amount(a.id) as amount,
           a.id
      from public.authorizations a
     where a.status in ('Authorized', 'Due')
       and a.id not in (select parent_id from public.authorizations where parent_id is not null)
  ),
  /**
   * Authorized and not yet earned: the hours a coaching parent still has,
   * and flat-fee work not yet billed. Spread to the stale date, because
   * nothing in the record says which month it will actually be worked.
   */
  uncovered as (
    select a.id,
           greatest(
             coalesce(a.total_hours, 0) * coalesce(a.rate, 0)
               - coalesce((select sum(e.hours) from public.service_entries e
                            join public.authorizations c on c.id = e.auth_id
                           where (c.id = a.id or c.parent_id = a.id) and not e.non_billable), 0)
                 * coalesce(a.rate, 0),
             0) as amount,
           greatest(1, least(p_months + 1,
             case when a.stale_date is null then 3
                  else greatest(1, (extract(year from a.stale_date) * 12 + extract(month from a.stale_date))::int
                                   - (extract(year from public.practice_today()) * 12
                                      + extract(month from public.practice_today()))::int + 1)
             end))::int as spread
      from public.authorizations a
     where a.status in ('Authorized', 'Due')
       and a.rate_type = 'Hourly'
       and coalesce(a.total_hours, 0) > 0
  ),
  per_client as (
    select coalesce(avg(total), 0) as amount
      from (
        select a.client_id, sum(public.authorization_amount(a.id)) as total
          from public.authorizations a
         where a.created_at >= public.practice_today() - 180
         group by a.client_id
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
         'Authorizations not yet billed, in the month their bill-by falls'
    from committed c
   where c.month <= (select last_month from horizon) and c.amount > 0
   group by c.month

  union all

  select m.month, 'Authorized', sum(round(u.amount / u.spread, 2)),
         'Hours authorized and not yet worked, spread to the stale date'
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
  'What is expected to come in, in three bands never summed together here. Reads authorizations and their bill-by dates (§1, §3).';

revoke all on function public.ledger_revenue_forecast(integer) from anon, authenticated;
grant execute on function public.ledger_revenue_forecast(integer) to authenticated;

-- The cash forecast's receivable leg: what is submitted and unpaid.
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
    select date_trunc('week', a.submitted_on + (select days from lag))::date as week,
           sum(public.authorization_amount(a.id)) as amount
      from public.authorizations a
     where a.status = 'Submitted' and a.submitted_on is not null
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
  'Cash by week for the next ninety days, and nothing at all until the books open. Reads authorizations (§1).';

revoke all on function public.ledger_cash_forecast(integer) from anon, authenticated;
grant execute on function public.ledger_cash_forecast(integer) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- What the practice has earned and is owed
--
-- The view read the invoice for invoiced, received and outstanding. §10
-- removes the invoice and §11 says a fact lives in one place: the
-- authorization now carries its own submission and payment, so the view
-- reads those.
--
-- Only the `billed` part changes. The other twenty-one columns are the live
-- definition, dumped and left byte-for-byte alone, because two views
-- (billing_position, staff_capacity) and three functions select from this
-- one and a column list that shifted would break them silently. CREATE OR
-- REPLACE also refuses to change a view's columns, which is the database
-- making the same point.
-- ─────────────────────────────────────────────────────────────
create or replace view public.authorization_economics as
 WITH used AS (
         SELECT a_1.id,
            COALESCE(a_1.carried_used, 0::numeric) + COALESCE(( SELECT sum(se.hours) AS sum
                   FROM service_entries se
                  WHERE se.auth_id = a_1.id AND NOT se.non_billable), 0::numeric) AS hours_used,
            ( SELECT min(se.date) AS min
                   FROM service_entries se
                  WHERE se.auth_id = a_1.id) AS first_entry_on,
            ( SELECT max(se.date) AS max
                   FROM service_entries se
                  WHERE se.auth_id = a_1.id) AS last_entry_on,
            ( SELECT count(*) AS count
                   FROM service_entries se
                  WHERE se.auth_id = a_1.id) AS entry_count
           FROM authorizations a_1
        ), billed AS (
         SELECT a_1.id,
            CASE WHEN a_1.status = ANY (ARRAY['Submitted'::text, 'Paid'::text])
                 THEN public.authorization_amount(a_1.id) ELSE 0::numeric END AS invoiced,
            COALESCE(a_1.paid_amount, 0::numeric) AS received,
            CASE WHEN a_1.status = 'Submitted'::text
                 THEN public.authorization_amount(a_1.id) ELSE 0::numeric END AS outstanding,
            a_1.submitted_on AS last_invoice_on
           FROM authorizations a_1
        ), done AS (
         SELECT a_1.id,
            ( SELECT max(c.completion) AS max
                   FROM completions c
                  WHERE c.auth_id = a_1.id AND c.completion IS NOT NULL) AS completed_on
           FROM authorizations a_1
        )
 SELECT a.id AS auth_id,
    a.client_id,
    a.number AS auth_number,
    a.service_type,
    a.funding_source,
    a.status,
    a.rate_type,
    a.rate,
    a.total_hours,
    a.start_date,
    a.end_date,
    u.hours_used,
        CASE
            WHEN a.total_hours IS NULL THEN NULL::numeric
            ELSE GREATEST(a.total_hours - u.hours_used, 0::numeric)
        END AS hours_left,
    u.first_entry_on,
    u.last_entry_on,
    u.entry_count,
    d.completed_on,
        CASE
            WHEN a.rate_type = 'Hourly'::text THEN COALESCE(a.total_hours, 0::numeric) * a.rate
            ELSE a.rate
        END AS authorized,
        CASE
            WHEN a.rate_type = 'Hourly'::text THEN u.hours_used * a.rate
            WHEN d.completed_on IS NOT NULL THEN a.rate
            ELSE 0::numeric
        END AS earned,
    b.invoiced,
    b.received,
    b.outstanding,
    b.last_invoice_on,
        CASE
            WHEN a.status <> 'Open'::text THEN 0::numeric
            ELSE GREATEST(
            CASE
                WHEN a.rate_type = 'Hourly'::text THEN u.hours_used * a.rate
                WHEN d.completed_on IS NOT NULL THEN a.rate
                ELSE 0::numeric
            END - b.invoiced, 0::numeric)
        END AS unbilled,
        CASE
            WHEN a.status <> 'Open'::text THEN 0::numeric
            ELSE GREATEST(
            CASE
                WHEN a.rate_type = 'Hourly'::text THEN COALESCE(a.total_hours, 0::numeric) * a.rate
                ELSE a.rate
            END -
            CASE
                WHEN a.rate_type = 'Hourly'::text THEN u.hours_used * a.rate
                WHEN d.completed_on IS NOT NULL THEN a.rate
                ELSE 0::numeric
            END, 0::numeric)
        END AS committed
   FROM authorizations a
     JOIN used u ON u.id = a.id
     JOIN billed b ON b.id = a.id
     JOIN done d ON d.id = a.id;

alter view public.authorization_economics set (security_invoker = true);
grant select on public.authorization_economics to authenticated;

comment on view public.authorization_economics is
  'What each authorization was authorized for, has earned, has billed and has been paid - all from the authorization itself, with no invoice in it (§1, §10, §11).';
