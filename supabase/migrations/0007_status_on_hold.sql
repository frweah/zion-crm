-- Zion Vocational Rehab CRM — 0007 client status "On hold"
--
-- The prototype's client drawer offers Active / On hold / Closed. 0001 only
-- allowed Active and Closed, because the migrated workbook contains only those
-- two — but the prototype is the approved spec, and a client who pauses
-- services is a real case that should not have to be closed and reopened.

alter table public.clients drop constraint if exists clients_status_check;
alter table public.clients add constraint clients_status_check
  check (status in ('Active', 'On hold', 'Closed'));
