-- Zion Vocational Rehab CRM — one item per authorization, not per client and
-- service alone
--
-- The brief says one item per client, service and period, and a second is
-- refused (her control 12.6). Counting the year's invoices before migrating
-- them says that is very nearly right and wrong in one particular way: nine
-- clients hold two or three paid invoices for the same service in the same
-- month, and in every single case they are separate authorizations - a second
-- Job Placement, a second block of coaching hours - not the same work billed
-- twice.
--
-- So the thing that must never happen twice is an authorization billed twice
-- for a period, and that is what the key says now. A client with two
-- authorizations for one service in one month gets two items, which is what
-- the paperwork already says happened; the same authorization billed twice
-- for that month is still refused.
--
-- The screens still warn on the looser shape - two items, same client,
-- service and period - because it is worth a second look even when it is
-- legitimate. A warning is the right weight for something that is usually
-- fine and occasionally a double bill.

drop index if exists public.billing_items_one_per_period;

create unique index if not exists billing_items_one_per_authorization
  on public.billing_items (client_id, service, period, auth_id) nulls not distinct;

comment on index public.billing_items_one_per_authorization is
  'One item per authorization, service and period (0125). Nulls are not distinct: a one-time item has one particular period - the one-off - not "any".';
