-- Zion Vocational Rehab CRM — the rules ask who you are once per query, not once per row
--
-- Nearly every row-level rule asks something about the person reading:
-- is_active_staff(), is_admin(), current_staff_role(), current_staff_id(),
-- staff_has_area('billing', 'edit'). Written bare, Postgres asks again for
-- every row it considers - each a lookup of the staff table - because it
-- cannot assume a security-definer function gives the same answer twice.
-- Wrapped as (select is_admin()), it asks once per query and reuses the answer.
--
-- Measured on 18 Sept 2026: reading every note went from 9.8 ms to 0.7 ms,
-- and "last activity" on the Clients list from 27 ms to 17 ms. The answer is
-- the same by construction - none of these depends on the row, only on who is
-- asking - and the full verify suite, which tries every rule from both sides,
-- is what holds that.
--
-- Only calls with no argument from the row are rewritten. can_see_restricted
-- (client_id), for instance, is asked per row because its answer is per row.
--
-- Written as a rewrite of every live policy rather than a list, so nothing is
-- missed, and so it is safe to run again: a call already wrapped is left as is.
-- verify_rls_evaluate_once.sql fails if a policy added later asks bare.

do $$
declare
  p          record;
  v_qual     text;
  v_check    text;
  v_sql      text;
  v_changed  integer := 0;
  -- Deparsed policy text shows these unqualified, and a wrapped one as
  -- "( SELECT is_admin() AS is_admin)" - which the look-behind skips.
  bare       constant text := '(?<!SELECT )\m(is_admin|is_active_staff|current_staff_role|current_staff_id|portal_session_account_id)\(\)';
  area       constant text := '(?<!SELECT )\mstaff_has_area\((''[a-z]+''::text, ''[a-z]+''::text)\)';
begin
  for p in
    select tablename, policyname, qual, with_check
      from pg_policies
     where schemaname = 'public'
       and (coalesce(qual, '') || ' ' || coalesce(with_check, '')) ~ ('(' || bare || '|' || area || ')')
  loop
    v_qual  := regexp_replace(regexp_replace(p.qual, bare, '(select public.\1())', 'g'), area, '(select public.staff_has_area(\1))', 'g');
    v_check := regexp_replace(regexp_replace(p.with_check, bare, '(select public.\1())', 'g'), area, '(select public.staff_has_area(\1))', 'g');

    v_sql := format('alter policy %I on public.%I', p.policyname, p.tablename);
    if p.qual is not null then
      v_sql := v_sql || format(' using (%s)', v_qual);
    end if;
    if p.with_check is not null then
      v_sql := v_sql || format(' with check (%s)', v_check);
    end if;
    execute v_sql;
    v_changed := v_changed + 1;
  end loop;

  raise notice 'policies rewritten to ask once per query: %', v_changed;

  if exists (
    select 1 from pg_policies
     where schemaname = 'public'
       and (coalesce(qual, '') || ' ' || coalesce(with_check, '')) ~ ('(' || bare || '|' || area || ')')
  ) then
    raise exception 'A policy still asks who you are once per row';
  end if;
end $$;
