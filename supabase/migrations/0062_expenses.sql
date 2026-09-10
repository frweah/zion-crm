-- ─────────────────────────────────────────────────────────────
-- 12.1 — expenses and mileage
--
-- Contractors drive to clients and buy things, and both are currently
-- settled by text message and memory. They belong on the statement that
-- already exists: one period, one submission, one approval, one payment.
--
-- Mileage is not an expense with a number typed into it. It is miles at the
-- rate that applied on the day, and the rate changes every January. So the
-- rate is a dated record like a pay rate, and — the part that matters — a
-- claim cannot be priced at a rate nobody has entered. That rule is the same
-- one the 1099 run already has about the federal threshold, for the same
-- reason: a figure invented to make a screen work is worse than a blank.
-- ─────────────────────────────────────────────────────────────

create table if not exists public.expense_categories (
  key         text primary key,
  label       text not null,
  detail      text not null default '',
  -- The one that is priced from miles rather than from an amount.
  is_mileage  boolean not null default false,
  -- Whether a receipt is expected. Mileage has none; a meal does.
  needs_receipt boolean not null default true,
  sort_order  integer not null default 100,
  active      boolean not null default true
);

alter table public.expense_categories enable row level security;

drop policy if exists expense_categories_read on public.expense_categories;
drop policy if exists expense_categories_write on public.expense_categories;

create policy expense_categories_read on public.expense_categories
  for select to authenticated using (public.is_active_staff());
create policy expense_categories_write on public.expense_categories
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

insert into public.expense_categories (key, label, detail, is_mileage, needs_receipt, sort_order) values
  ('mileage',  'Mileage',  'Miles driven for a client, at the rate on the day.', true,  false, 10),
  ('parking',  'Parking',  'Including meters, where a receipt exists.',          false, true,  20),
  ('tolls',    'Tolls',    '',                                                   false, true,  30),
  ('supplies', 'Supplies', 'Anything bought for a client or the practice.',       false, true,  40),
  ('training', 'Training', 'Course fees, where the practice agreed to them.',     false, true,  50),
  ('phone',    'Phone',    'An agreed share of a bill.',                          false, true,  60),
  ('other',    'Other',    'Say what it was.',                                    false, true,  99)
on conflict (key) do update set
  label = excluded.label, detail = excluded.detail, is_mileage = excluded.is_mileage,
  needs_receipt = excluded.needs_receipt, sort_order = excluded.sort_order;

-- ─────────────────────────────────────────────────────────────
-- The mileage rate, as a dated record
--
-- Set by the owner, from the IRS figure for the year. Nothing here guesses
-- one: a claim on a day no rate covers is reported as miles with no amount,
-- the same way an hour on a day no pay rate covers is reported as unpriced.
-- ─────────────────────────────────────────────────────────────
create table if not exists public.mileage_rates (
  effective_from date primary key,
  cents_per_mile numeric(6,2) not null check (cents_per_mile > 0),
  note           text not null default '',
  set_by         uuid references public.staff(id) on delete set null,
  set_at         timestamptz not null default now()
);

alter table public.mileage_rates enable row level security;

drop policy if exists mileage_rates_read on public.mileage_rates;
drop policy if exists mileage_rates_write on public.mileage_rates;

create policy mileage_rates_read on public.mileage_rates
  for select to authenticated using (public.is_active_staff());
create policy mileage_rates_write on public.mileage_rates
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

create or replace function public.mileage_rate_on(p_date date)
returns numeric language sql stable as $$
  select cents_per_mile
    from public.mileage_rates
   where effective_from <= p_date
   order by effective_from desc
   limit 1;
$$;

comment on function public.mileage_rate_on is
  'Cents per mile on a given day, or null if no rate covers it. Null means unpriced, never zero.';

-- ─────────────────────────────────────────────────────────────
-- The claims
-- ─────────────────────────────────────────────────────────────
create table if not exists public.expenses (
  id           uuid primary key default gen_random_uuid(),
  staff_id     uuid not null references public.staff(id) on delete cascade,
  incurred_on  date not null,
  category     text not null references public.expense_categories(key),
  description  text not null default '',

  -- One of these, decided by the category. A mileage claim has miles and no
  -- amount; everything else has an amount and no miles.
  amount       numeric(10,2) check (amount is null or amount > 0),
  miles        numeric(8,2)  check (miles is null or miles > 0),
  from_place   text not null default '',
  to_place     text not null default '',

  client_id    uuid references public.clients(id) on delete set null,
  receipt_id   uuid references public.staff_files(id) on delete set null,

  statement_id uuid references public.contractor_statements(id) on delete set null,

  created_at   timestamptz not null default now(),
  created_by   uuid references public.staff(id) on delete set null,

  constraint expenses_one_kind check (
    (amount is not null and miles is null) or
    (miles is not null and amount is null)
  )
);

create index if not exists expenses_staff_idx on public.expenses (staff_id, incurred_on desc);
create index if not exists expenses_statement_idx on public.expenses (statement_id);

alter table public.expenses enable row level security;

drop policy if exists expenses_read on public.expenses;
drop policy if exists expenses_write on public.expenses;
drop policy if exists expenses_update on public.expenses;
drop policy if exists expenses_delete on public.expenses;

create policy expenses_read on public.expenses
  for select to authenticated
  using (public.is_admin() or staff_id = public.current_staff_id());

create policy expenses_write on public.expenses
  for insert to authenticated
  with check (
    (public.is_admin() or staff_id = public.current_staff_id())
    and created_by is not distinct from public.current_staff_id()
    and statement_id is null
  );

-- Editable until it is claimed, and not after.
--
-- Different from an hour, deliberately. A time record is evidence in itself,
-- so it is append-only from the moment it is written. An expense is a
-- description of a receipt, and the receipt is the evidence — correcting
-- "parking" to "parking at the DWS office" before claiming it is tidying a
-- label, not rewriting a record. Once it is on a statement it is part of a
-- payment and stops moving.
create policy expenses_update on public.expenses
  for update to authenticated
  using (staff_id = public.current_staff_id() and statement_id is null)
  with check (staff_id = public.current_staff_id() and statement_id is null);

create policy expenses_delete on public.expenses
  for delete to authenticated
  using (staff_id = public.current_staff_id() and statement_id is null);

create or replace function public.expenses_freeze_when_claimed()
returns trigger language plpgsql as $$
begin
  -- Attaching to a statement is the one field that may change afterwards, and
  -- only the submit does that. Everything else is fixed once claimed.
  if old.statement_id is not null
     and (new.incurred_on   is distinct from old.incurred_on
       or new.category      is distinct from old.category
       or new.amount        is distinct from old.amount
       or new.miles         is distinct from old.miles
       or new.description   is distinct from old.description
       or new.staff_id      is distinct from old.staff_id) then
    raise exception
      'That expense is on a statement. Ask for the statement to be returned if it needs changing.'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

drop trigger if exists expenses_frozen on public.expenses;
create trigger expenses_frozen before update on public.expenses
  for each row execute function public.expenses_freeze_when_claimed();

-- ─────────────────────────────────────────────────────────────
-- What each claim comes to
--
-- Mileage is priced at the rate on the day it was driven, not the rate today
-- — a claim submitted in February for December is a December claim.
-- ─────────────────────────────────────────────────────────────
create or replace view public.expense_values as
select e.id,
       e.staff_id,
       e.incurred_on,
       e.category,
       c.label                                   as category_label,
       c.is_mileage,
       e.description,
       e.client_id,
       e.miles,
       e.from_place,
       e.to_place,
       e.receipt_id,
       e.statement_id,
       e.created_at,
       public.mileage_rate_on(e.incurred_on)     as rate_used,
       case
         when not c.is_mileage then e.amount
         when public.mileage_rate_on(e.incurred_on) is null then null
         else round(e.miles * public.mileage_rate_on(e.incurred_on) / 100.0, 2)
       end                                       as amount,
       -- Said out loud rather than folded in at zero: miles on a day no rate
       -- covers are real miles and an unknown amount.
       (c.is_mileage and public.mileage_rate_on(e.incurred_on) is null)
                                                 as unpriced
  from public.expenses e
  join public.expense_categories c on c.key = e.category;

alter view public.expense_values set (security_invoker = true);
grant select on public.expense_values to authenticated;

comment on view public.expense_values is
  'Each claim with what it comes to. Mileage is priced at the rate on the day it was driven; miles on a day no rate covers are reported as unpriced rather than as zero.';

-- ─────────────────────────────────────────────────────────────
-- The statement learns about expenses
--
-- Restated from 0047, which restated it from 0027. Hours and expenses are
-- kept apart in the figures all the way to the total, because they are paid
-- for different reasons and an approver should see which is which.
-- ─────────────────────────────────────────────────────────────
-- Dropped rather than replaced: the new columns land in the middle, and a
-- replace can only add them at the end. Nothing else reads this view — the
-- Hours screen and the contractor statements both query it by name and are
-- rebuilt below by the same migration run.
drop view if exists public.contractor_statement_totals cascade;
create view public.contractor_statement_totals as
select st.id                                   as statement_id,
       st.staff_id,
       st.period_start,
       st.period_end,
       st.status,
       st.adjustment,
       st.adjustment_note,
       coalesce(sum(v.hours), 0)               as hours,
       coalesce(sum(v.hours) filter (where v.amount is null), 0) as unpriced_hours,
       pr.rate_unit,
       pr.pay_rate                             as period_rate,

       coalesce(ex.expense_total, 0)           as expenses,
       coalesce(ex.mileage_miles, 0)           as mileage_miles,
       coalesce(ex.unpriced_miles, 0)          as unpriced_miles,

       case
         when pr.rate_unit = 'Flat' then coalesce(pr.pay_rate, 0)
         else coalesce(sum(v.amount), 0)
       end + st.adjustment + coalesce(ex.expense_total, 0)  as computed_amount,

       st.approved_hours,
       st.approved_amount,
       coalesce(st.approved_hours, coalesce(sum(v.hours), 0))    as total_hours,
       coalesce(st.approved_amount,
                case
                  when pr.rate_unit = 'Flat' then coalesce(pr.pay_rate, 0)
                  else coalesce(sum(v.amount), 0)
                end + st.adjustment + coalesce(ex.expense_total, 0)) as total_amount
  from public.contractor_statements st
  left join public.work_session_values v on v.statement_id = st.id
  left join lateral public.pay_rate_on(st.staff_id, st.period_end) pr on true
  left join lateral (
    select coalesce(sum(e.amount), 0)                                as expense_total,
           coalesce(sum(e.miles) filter (where e.is_mileage), 0)     as mileage_miles,
           coalesce(sum(e.miles) filter (where e.unpriced), 0)       as unpriced_miles
      from public.expense_values e
     where e.statement_id = st.id
  ) ex on true
 group by st.id, st.staff_id, st.period_start, st.period_end, st.status,
          st.adjustment, st.adjustment_note, st.approved_hours, st.approved_amount,
          pr.rate_unit, pr.pay_rate,
          ex.expense_total, ex.mileage_miles, ex.unpriced_miles;

alter view public.contractor_statement_totals set (security_invoker = true);
grant select on public.contractor_statement_totals to authenticated;
