-- ─────────────────────────────────────────────────────────────
-- 0045 — what each authorization is worth, and how much of it is claimed
--
-- The billing screens answer "what did we invoice". Nobody could answer "what
-- have we been authorized to earn, and how much of it have we not earned yet"
-- without adding up a spreadsheet by hand — which is the question that decides
-- whether a month is going to be all right.
--
-- One row per authorization, in money as well as hours:
--
--   authorized  what USOR has agreed to pay for, in full
--   earned      the part of that we have actually done
--   invoiced    the part we have asked for (a Void invoice never counts)
--   received    the part that has been paid
--   unbilled    earned and not yet asked for — only on an open authorization,
--               because a closed one is settled whatever the arithmetic says
--   committed   authorized and not yet earned — the work still to do, which is
--               also the money still to make
--
-- Hourly and flat fee earn differently, and pretending otherwise is how a
-- revenue figure becomes a guess:
--
--   Hourly    earns by the hour. Hours used are what was carried over at
--             migration plus every billable entry since.
--   Flat fee  earns on completion. A flat-fee authorization with no completion
--             recorded has earned nothing, however much time went into it.
-- ─────────────────────────────────────────────────────────────
create or replace view public.authorization_economics as
with used as (
  select a.id,
         coalesce(a.carried_used, 0)
           + coalesce((select sum(se.hours) from public.service_entries se
                        where se.auth_id = a.id and not se.non_billable), 0) as hours_used,
         (select min(se.date) from public.service_entries se where se.auth_id = a.id) as first_entry_on,
         (select max(se.date) from public.service_entries se where se.auth_id = a.id) as last_entry_on,
         (select count(*) from public.service_entries se where se.auth_id = a.id)     as entry_count
    from public.authorizations a
),
billed as (
  select a.id,
         coalesce((select sum(i.amount) from public.invoices i
                    where i.auth_id = a.id and i.status <> 'Void'), 0) as invoiced,
         coalesce((select sum(i.amount) from public.invoices i
                    where i.auth_id = a.id and i.status = 'Paid'), 0)  as received,
         coalesce((select sum(i.amount) from public.invoices i
                    where i.auth_id = a.id and i.status = 'Sent'), 0)  as outstanding,
         (select max(i.date) from public.invoices i where i.auth_id = a.id) as last_invoice_on
    from public.authorizations a
),
done as (
  select a.id,
         (select max(c.completion) from public.completions c
           where c.auth_id = a.id and c.completion is not null) as completed_on
    from public.authorizations a
)
select a.id                                as auth_id,
       a.client_id,
       a.number                            as auth_number,
       a.service_type,
       a.funding_source,
       a.status,
       a.rate_type,
       a.rate,
       a.total_hours,
       a.start_date,
       a.end_date,
       u.hours_used,
       case when a.total_hours is null then null
            else greatest(a.total_hours - u.hours_used, 0) end   as hours_left,
       u.first_entry_on,
       u.last_entry_on,
       u.entry_count,
       d.completed_on,

       -- ── authorized ────────────────────────────────────────
       case when a.rate_type = 'Hourly'
            then coalesce(a.total_hours, 0) * a.rate
            else a.rate
       end                                                       as authorized,

       -- ── earned ────────────────────────────────────────────
       case when a.rate_type = 'Hourly'
            then u.hours_used * a.rate
            when d.completed_on is not null then a.rate
            else 0
       end                                                       as earned,

       b.invoiced,
       b.received,
       b.outstanding,
       b.last_invoice_on,

       -- ── the two gaps that matter ──────────────────────────
       -- A closed authorization is settled: whatever the hours say, nobody is
       -- going to invoice it again, and showing it as owed money would put a
       -- number on the screen that no one can act on.
       case when a.status <> 'Open' then 0
            else greatest(
              (case when a.rate_type = 'Hourly'
                    then u.hours_used * a.rate
                    when d.completed_on is not null then a.rate
                    else 0
               end) - b.invoiced, 0)
       end                                                       as unbilled,

       case when a.status <> 'Open' then 0
            else greatest(
              (case when a.rate_type = 'Hourly'
                    then coalesce(a.total_hours, 0) * a.rate
                    else a.rate
               end)
              - (case when a.rate_type = 'Hourly'
                      then u.hours_used * a.rate
                      when d.completed_on is not null then a.rate
                      else 0
                 end), 0)
       end                                                       as committed

  from public.authorizations a
  join used   u on u.id = a.id
  join billed b on b.id = a.id
  join done   d on d.id = a.id;

alter view public.authorization_economics set (security_invoker = true);
grant select on public.authorization_economics to authenticated;

comment on view public.authorization_economics is
  'Per authorization: authorized, earned, invoiced, received, plus what is earned and not billed and what is authorized and not yet earned. Unbilled and committed are zero on a closed authorization.';
