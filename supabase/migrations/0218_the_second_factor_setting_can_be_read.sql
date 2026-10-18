-- Zion Vocational Rehab CRM — the second factor setting can be read
-- (owner, 18 Oct 2026)
--
-- 0217 added org_settings.require_two_factor and granted nothing on it, so
-- the column existed and nobody could read or write it. verify_columns.sql
-- caught it on the first run of the suite after it was added - which is what
-- that script is for, and the third time this month a new column has arrived
-- without its grant.
--
-- Reading it is everybody's: the screen that asks somebody to set up a second
-- factor has to know whether one is required, and that is not a secret from
-- the person being asked. Writing it is Admin's, and the RLS policy on
-- org_settings is what says so - the grant only decides which columns are in
-- scope at all.

grant select (require_two_factor) on public.org_settings to authenticated;
grant update (require_two_factor) on public.org_settings to authenticated;

do $$
declare v_n integer;
begin
  select count(*) into v_n
    from information_schema.column_privileges
   where table_schema = 'public' and table_name = 'org_settings'
     and column_name = 'require_two_factor' and grantee = 'authenticated';
  if v_n < 2 then
    raise exception 'The setting still cannot be read and written (% privileges).', v_n;
  end if;
  raise notice 'ok  the second-factor setting can be read by everybody and set by Admin';
end $$;
