-- Zion Vocational Rehab CRM — a second system account, so the deploy check
-- can see Billing's screens
--
-- The deploy check has been Job Search since 0120, on the reasoning that an
-- account which is not a person should be the least a signed-in account can
-- be. That reasoning is still right, and it had a consequence nobody had
-- named: every Billing-only screen is invisible to the check. Invoices,
-- Authorizations, the Service log, Export - and now Overview and Items - have
-- never been opened by it, on any deploy. The one crash this whole mechanism
-- exists to catch (Clients > Jobs, 21 Sept) would have gone just as unnoticed
-- on any of them.
--
-- So a system account may also be Billing. What does not change is everything
-- that makes a system account safe:
--
--   It still writes nothing. The restrictive rules from 0120 refuse every
--   insert, update and delete made as a system account, on every table, and
--   they do not consult its role.
--
--   It is still given nothing beyond its role: the trigger on grants refuses
--   a system account whatever it is.
--
--   Its reads are still logged like anybody's.
--
--   It still cannot be Admin. Admin is the role that can change what roles
--   may do, and an account nobody signs into should never hold it.
--
-- Two accounts rather than one role that can see everything: each opens the
-- screens its own role reaches, which is also a check that the navigation
-- shows each role what it should.

alter table public.staff drop constraint if exists staff_system_is_job_search;
alter table public.staff add constraint staff_system_is_job_search
  check (not is_system or role in ('Job Search', 'Billing'));

comment on constraint staff_system_is_job_search on public.staff is
  'A system account is Job Search or Billing (0129), never Admin or Intake & Reports. It writes nothing whichever it is.';
