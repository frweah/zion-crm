-- ─────────────────────────────────────────────────────────────
-- 0027 — what a statement comes to.
--
-- Until now a statement showed hours and no money, so the instruction that a
-- contractor should see their own statement total had never been met.
--
-- Hourly work is priced session by session at the rate in force on the day it
-- was done, so a rate that changes mid-period splits the period correctly
-- without anybody having to think about it.
--
-- A flat rate is a fixed amount for the period, once, with no pro-rating. That
-- was the owner's decision. Some day has to decide which flat rate applies
-- when the rate changes mid-period, and it is the period's last day: that is
-- the rate in force when the period closed. Where that is not what was agreed,
-- the adjustment below is the way to say so.
--
-- An approved statement keeps the figures it was approved with. Otherwise a
-- back-dated rate — which is a legitimate thing to record — would silently
-- restate what somebody has already been paid, and the statement in their
-- hands would stop matching the one here with nothing to show which was right.
-- ─────────────────────────────────────────────────────────────

alter table public.contractor_statements
  add column if not exists adjustment      numeric(10,2) not null default 0,
  add column if not exists adjustment_note text not null default '',
  add column if not exists approved_hours  numeric(10,2),
  add column if not exists approved_amount numeric(10,2);

comment on column public.contractor_statements.adjustment is
  'A one-off correction for this period, plus or minus. Needs a reason.';
comment on column public.contractor_statements.approved_amount is
  'What the statement came to when it was approved. Set once, by trigger.';

-- An adjustment without a reason is an unexplained number on a pay record.
alter table public.contractor_statements
  drop constraint if exists contractor_statements_adjustment_needs_note;
alter table public.contractor_statements
  add constraint contractor_statements_adjustment_needs_note
  check (adjustment = 0 or adjustment_note <> '');

-- ─────────────────────────────────────────────────────────────
-- What each session is worth.
-- ─────────────────────────────────────────────────────────────
create or replace view public.work_session_values as
select w.id,
       w.staff_id,
       w.worked_on,
       w.hours,
       w.description,
       w.client_id,
       w.statement_id,
       r.pay_rate,
       r.rate_unit,
       case when r.rate_unit = 'Hourly' then round(w.hours * r.pay_rate, 2) end as amount
  from public.work_sessions w
  left join lateral public.pay_rate_on(w.staff_id, w.worked_on) r on true
 where not w.voided;

alter view public.work_session_values set (security_invoker = true);
grant select on public.work_session_values to authenticated;

-- ─────────────────────────────────────────────────────────────
-- What each statement comes to.
--
-- unpriced_hours is the honest answer to hours worked on days no rate covers.
-- Those hours are real and the money is unknown, so they are reported as hours
-- with no amount rather than folded in at zero, which would read as free work.
-- ─────────────────────────────────────────────────────────────
create or replace view public.contractor_statement_totals as
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
       -- What it comes to now, before any snapshot is considered.
       case
         when pr.rate_unit = 'Flat' then coalesce(pr.pay_rate, 0)
         else coalesce(sum(v.amount), 0)
       end + st.adjustment                     as computed_amount,
       st.approved_hours,
       st.approved_amount,
       -- What to show. An approved statement shows what it was approved with.
       coalesce(st.approved_hours, coalesce(sum(v.hours), 0))    as total_hours,
       coalesce(st.approved_amount,
                case
                  when pr.rate_unit = 'Flat' then coalesce(pr.pay_rate, 0)
                  else coalesce(sum(v.amount), 0)
                end + st.adjustment)                             as total_amount
  from public.contractor_statements st
  left join public.work_session_values v on v.statement_id = st.id
  left join lateral public.pay_rate_on(st.staff_id, st.period_end) pr on true
 group by st.id, st.staff_id, st.period_start, st.period_end, st.status,
          st.adjustment, st.adjustment_note, st.approved_hours, st.approved_amount,
          pr.rate_unit, pr.pay_rate;

alter view public.contractor_statement_totals set (security_invoker = true);
grant select on public.contractor_statement_totals to authenticated;

-- ─────────────────────────────────────────────────────────────
-- Approving a statement fixes its figures.
-- ─────────────────────────────────────────────────────────────
create or replace function public.snapshot_statement_on_approval()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_hours  numeric;
  v_amount numeric;
begin
  if new.status <> 'Approved' or old.status = 'Approved' then
    return new;
  end if;

  select coalesce(sum(v.hours), 0),
         case
           when pr.rate_unit = 'Flat' then coalesce(pr.pay_rate, 0)
           else coalesce(sum(v.amount), 0)
         end + new.adjustment
    into v_hours, v_amount
    from public.work_sessions w
    left join lateral public.pay_rate_on(w.staff_id, w.worked_on) r on true
    left join lateral (select w.hours as hours,
                              case when r.rate_unit = 'Hourly'
                                   then round(w.hours * r.pay_rate, 2) end as amount) v on true
    left join lateral public.pay_rate_on(new.staff_id, new.period_end) pr on true
   where w.statement_id = new.id and not w.voided
   group by pr.rate_unit, pr.pay_rate;

  new.approved_hours  := coalesce(v_hours, 0);
  new.approved_amount := coalesce(v_amount, new.adjustment);
  return new;
end;
$$;

drop trigger if exists contractor_statements_snapshot on public.contractor_statements;
create trigger contractor_statements_snapshot before update on public.contractor_statements
  for each row execute function public.snapshot_statement_on_approval();

/**
 * A one-off correction on a statement.
 *
 * Admin only, needs a reason, and refused once the statement is approved —
 * an approved statement is what somebody was paid, and changing it after the
 * fact is what the Returned status is for.
 */
create or replace function public.set_statement_adjustment(
  p_statement_id uuid,
  p_amount       numeric,
  p_note         text
)
returns void
language plpgsql security definer set search_path = public as $$
declare
  st record;
begin
  if not public.is_admin() then
    raise exception 'Only Admin can adjust a statement.' using errcode = 'insufficient_privilege';
  end if;

  select * into st from public.contractor_statements where id = p_statement_id;
  if st is null then
    raise exception 'No such statement.' using errcode = 'check_violation';
  end if;
  if st.status = 'Approved' then
    raise exception
      'That statement is approved. Return it first — an approved statement is what somebody was paid.'
      using errcode = 'check_violation';
  end if;
  if coalesce(p_amount, 0) <> 0 and coalesce(trim(p_note), '') = '' then
    raise exception 'An adjustment needs a reason.' using errcode = 'check_violation';
  end if;

  update public.contractor_statements
     set adjustment = coalesce(p_amount, 0),
         adjustment_note = case when coalesce(p_amount, 0) = 0 then '' else trim(p_note) end
   where id = p_statement_id;
end;
$$;

revoke execute on function public.set_statement_adjustment(uuid, numeric, text) from public;
grant execute on function public.set_statement_adjustment(uuid, numeric, text) to authenticated;
