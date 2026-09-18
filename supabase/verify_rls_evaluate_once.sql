-- Zion Vocational Rehab CRM — no rule asks who you are once per row
--
-- What has to hold: every row-level rule that asks about the person reading
-- (is_admin, is_active_staff, current_staff_role, current_staff_id,
-- portal_session_account_id, staff_has_area with fixed arguments) asks it
-- wrapped in a sub-select, so Postgres works it out once per query (0095).
-- A policy written later the bare way passes every other check and quietly
-- makes its table ten times slower to read; this is the check that catches it.
--
-- What each rule allows is held by the rest of the suite; this holds only how
-- it is asked.
--
-- Read-only.

begin;

do $$
declare
  v_bare  text;
begin
  select string_agg(format('%s.%s', tablename, policyname), ', ' order by tablename, policyname)
    into v_bare
    from pg_policies
   where schemaname = 'public'
     and (coalesce(qual, '') || ' ' || coalesce(with_check, '')) ~
         '(?<!SELECT )\m(is_admin|is_active_staff|current_staff_role|current_staff_id|portal_session_account_id)\(\)|(?<!SELECT )\mstaff_has_area\(''[a-z]+''::text, ''[a-z]+''::text\)';

  if v_bare is not null then
    raise exception 'FAILED: these rules ask who you are once per row - wrap the call as (select public.is_admin()): %', v_bare;
  end if;
  raise notice 'ok  every rule asks who you are once per query, not once per row';
  raise notice '--- RLS EVALUATE-ONCE VERIFIED ---';
end $$;

rollback;
