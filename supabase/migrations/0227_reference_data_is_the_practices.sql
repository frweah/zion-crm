-- Zion Vocational Rehab CRM — 0227 reference data is the practice's
--
-- Two reference tables answered anybody signed in, which since a client with
-- a portal login signs in as `authenticated` means they answered clients:
--
--   billing_service_rules - what the practice bills for each service, and
--   how often. Thirteen rows of the price list.
--
--   practice_forms - the form templates. Three rows a client has no use for
--   and no business reading.
--
-- Neither was a mistake anybody made twice: `using (true)` was written when
-- `authenticated` meant staff, and that stopped being true when the portal
-- arrived. Both now ask the same question everything else asks - whether the
-- caller is a member of staff - and the portal's own check reads them empty.

-- Wrapped as (select ...) so it is worked out once for the query rather than
-- once per row, which is the rule verify_rls_evaluate_once holds every policy
-- to and which this got wrong on the first pass.
alter policy billing_service_rules_select on public.billing_service_rules
  using ((select public.is_active_staff()));

alter policy practice_forms_select on public.practice_forms
  using (
    (select public.is_active_staff())
    and active
    and (cardinality(roles) = 0
         or (select public.current_staff_role()) = any (roles)
         or (select public.current_staff_role()) = 'Admin')
  );
