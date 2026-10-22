-- 0226 — The CRM holds USOR vocational rehab work, and nothing funded by Medicaid.
--
-- 21 Oct 2026, the owner. Zion Healing Academy LLC is now a Medicaid / DSPD
-- waiver provider, which makes it a HIPAA covered entity. It is to be a
-- hybrid entity: the waiver and personal care services are the covered
-- component, and their records live in CareSmartz360, under a business
-- associate agreement. This CRM is the USOR side, outside that component.
--
-- That only holds while no waiver client's record is kept here. "HCBS
-- Medicaid" was offered as a funding source and never used (every client and
-- authorization on this date is Utah VR); it goes from the list on screen,
-- and these checks make sure nothing puts it back by another door.
--
-- Private pay and Other stay: vocational rehab paid for privately is not a
-- health care service.

alter table public.clients drop constraint if exists clients_funding_source_check;
alter table public.clients add constraint clients_funding_source_check
  check (funding_source in ('Utah VR', 'Private Pay', 'Other'));

alter table public.authorizations drop constraint if exists authorizations_funding_source_check;
alter table public.authorizations add constraint authorizations_funding_source_check
  check (funding_source in ('Utah VR', 'Private Pay', 'Other'));

alter table public.rate_schedule drop constraint if exists rate_schedule_funding_source_check;
alter table public.rate_schedule add constraint rate_schedule_funding_source_check
  check (funding_source in ('Utah VR', 'Private Pay', 'Other'));
