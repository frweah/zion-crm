-- Zion Vocational Rehab CRM — 0256 past, current and upcoming
--
-- The client's Billing tab showed the working list and, folded underneath it,
-- "History (N paid or closed)". Two lists, one of them hidden, and nothing
-- for an authorization that has not started yet - which simply did not appear
-- (owner, 26 Oct 2026).
--
-- Three groups instead, and a record is in exactly one of them:
--
--   **Past**      paid or closed. The work and the money are both done with.
--   **Current**   authorized, due or submitted, and its period takes in today.
--   **Upcoming**  it starts after today.
--
-- The rule lives here rather than in the screen because "a paid authorization
-- never shows in Current" is a thing to be able to assert, and a filter
-- written in a component can only be read. The screen picks groups; it does
-- not decide what they mean.
--
-- An authorization that is neither paid nor future and whose dates have run
-- out is still Current: it is money owed and nobody is finished with it. The
-- alternative - calling it Past because its end date has gone by - would hide
-- exactly the records the practice most needs to chase.

-- Dropped rather than replaced: `create or replace view` can only add columns
-- at the end, and these are in the order the record itself has them.
drop view if exists public.client_authorizations;

create view public.client_authorizations as
  select a.id,
         a.client_id,
         a.number,
         a.has_usor_number,
         a.service_type,
         a.status,
         a.period,
         a.start_date,
         a.end_date,
         a.received_on,
         a.paid_on,
         a.paid_amount,
         a.warrant,
         a.closed_reason,
         a.rate_type,
         a.rate,
         a.total_hours,
         a.is_placeholder,
         a.parent_id,
         -- The rest of the editable record, so a row on this list can open
         -- the same edit form the authorization's own page uses rather than a
         -- second, shorter one that drifts from it.
         a.funding_source,
         a.bill_by,
         a.service_start,
         a.service_end,
         a.recipient,
         a.requires_forms,
         a.note,
         public.authorization_amount(a.id) as amount,
         case
           when a.status in ('Paid', 'Closed') then 'Past'
           when a.start_date is not null and a.start_date > public.practice_today() then 'Upcoming'
           else 'Current'
         end as bucket
    from public.authorizations a
   where (select public.reader_may_answer());

alter view public.client_authorizations set (security_invoker = true);
grant select on public.client_authorizations to authenticated;

comment on view public.client_authorizations is
  'A client''s authorizations with the group each falls in - Past, Current or Upcoming - decided in one place (0256).';
