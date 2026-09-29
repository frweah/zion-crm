-- Zion Vocational Rehab CRM — the year that has already been billed, as items
-- (Billing Lifecycle Brief §9)
--
-- Reported before it was applied (owner, 29 Sept 2026). What it does:
--
--   Every invoice becomes the item it was for: same authorization, same
--   money, Paid, with its warrant and payment date. All 139 are Paid, so
--   nothing lands in Submitted or Pending - there was no other state to
--   carry across.
--
--   The service comes from the authorization, never from the invoice. An
--   invoice's service_type is a description somebody typed - "Job Placement
--   (SBT)", "2x $560 services (e.g., Job Dev + Rural)" - and no authorization
--   is for a service by that name. The item's service has to be its
--   authorization's or the item refuses to exist, which is the rule doing its
--   job rather than getting in the way.
--
--   Open authorizations that were never invoiced get their item: a month at a
--   time for Job Coaching, one otherwise.
--
-- What it deliberately does not do:
--
--   It does not fill in service dates. Nothing in the records says when the
--   work actually happened - only when the authorization ran and when the
--   invoice was written - and the one rule this whole thing rests on is that
--   those are different questions (her §4). A blank the gate can see is worth
--   more than a date that looks like an answer.
--
--   It does not invent hours. The service log has never been used: it holds
--   no rows at all. Hourly items carry the amount that was actually paid and
--   no hours, rather than hours divided out of it.
--
--   It does not date the twenty open Job Coaching authorizations that have no
--   start or end date. They produce no months here; they come out on the
--   review list below, and their months open once somebody dates them.

-- ── first, a rule that was one word too wide ───────────────
-- "Submitted has a date and a recipient" is about the send action: nothing
-- reaches Submitted, Pending or Correction needed except by being sent from
-- here, and the send records both. Paid was in that list too, and it should
-- not have been: a payment can arrive for work that was sent long before this
-- system existed, which is exactly what the whole of last year is. Requiring
-- a submission record for those would have meant inventing one - a date we do
-- not know, and a recipient we would be guessing at.
--
-- What still holds: anything sent from here passes through Submitted, and
-- carries its date and recipient onwards.
alter table public.billing_items drop constraint if exists billing_items_submitted_has_both;
alter table public.billing_items add constraint billing_items_submitted_has_both
  check (
    status not in ('Submitted', 'Pending', 'Correction needed')
    or (submitted_at is not null and recipient is not null)
  );

-- ── what was billed ────────────────────────────────────────
insert into public.billing_items (
  client_id, auth_id, service, period, status,
  billing_type, amount, invoice_id, paid_on, paid_amount, warrant,
  assigned_staff_id, notes
)
select a.client_id,
       a.id,
       a.service_type,
       case when sr.recurrence = 'Monthly' then date_trunc('month', i.date)::date end,
       'Paid',
       sr.billing_type,
       i.amount,
       i.id,
       i.paid_date,
       i.amount,
       i.warrant,
       c.billing_staff_id,
       'Carried across from invoice ' || coalesce(i.number, '(no number)') || ' (0127).'
  from public.invoices i
  join public.authorizations a on a.id = i.auth_id
  join public.clients c on c.id = a.client_id
  join public.billing_service_rules sr on sr.service = a.service_type
 where i.paid_date is not null
on conflict (client_id, service, period, auth_id) do nothing;

-- ── what is authorized and not yet billed ──────────────────
insert into public.billing_items (
  client_id, auth_id, service, period, status,
  billing_type, rate, assigned_staff_id, zero_hours_flagged, notes
)
select a.client_id,
       a.id,
       a.service_type,
       m.period,
       case
         -- A month that has ended is a month to look at; this one is still
         -- being worked.
         when m.period is null then 'Authorization received'
         when m.period >= date_trunc('month', public.practice_today())::date then 'Service in progress'
         else 'Service period complete'
       end,
       sr.billing_type,
       a.rate,
       c.billing_staff_id,
       -- A past month with nothing logged is a question, not a fact.
       m.period is not null
         and m.period < date_trunc('month', public.practice_today())::date
         and coalesce((select sum(se.hours) from public.service_entries se
                        where se.auth_id = a.id and not se.non_billable
                          and se.date >= m.period
                          and se.date < (m.period + interval '1 month')::date), 0) = 0,
       'Opened from an authorization with no invoice (0127).'
  from public.authorizations a
  join public.clients c on c.id = a.client_id
  join public.billing_service_rules sr on sr.service = a.service_type
  cross join lateral (
    select g::date as period
      from generate_series(
        date_trunc('month', a.start_date),
        date_trunc('month', least(coalesce(a.end_date, public.practice_today()), public.practice_today())),
        interval '1 month') g
     where sr.recurrence = 'Monthly'
    union all
    select null::date where sr.recurrence = 'One-time'
  ) m
 where a.status = 'Open'
   and c.merged_into is null
   and not exists (select 1 from public.invoices i where i.auth_id = a.id)
on conflict (client_id, service, period, auth_id) do nothing;

-- ── what nobody could carry across ─────────────────────────
-- An open authorization with no dates cannot say which months it covers.
-- Rather than guess, it is listed: this view is the review list, and it
-- empties itself as the dates are filled in.
create or replace view public.billing_items_undated
with (security_invoker = true) as
  select a.id as auth_id,
         a.number,
         a.client_id,
         c.name as client_name,
         a.service_type,
         a.rate_type,
         a.rate,
         a.total_hours,
         c.billing_staff_id
    from public.authorizations a
    join public.clients c on c.id = a.client_id
    join public.billing_service_rules sr on sr.service = a.service_type
   where a.status = 'Open'
     and c.merged_into is null
     and sr.recurrence = 'Monthly'
     and (a.start_date is null or a.end_date is null)
     and not exists (select 1 from public.billing_items i where i.auth_id = a.id);

grant select on public.billing_items_undated to authenticated;

comment on view public.billing_items_undated is
  'Open recurring authorizations with no dates, so no months could be opened for them (0127). It empties itself as the dates are filled in.';
