-- Zion Vocational Rehab CRM — nothing a verification built is still here
--
-- Named to sort last, so it runs after every other script in the suite has
-- built its fixtures and rolled them back. If one of them leaked - a forgotten
-- rollback, a statement after it, a query somebody ran by hand against
-- production - this is what says so.
--
-- The fixtures all say what they are: a client is "ZZ Something", a counselor
-- "ZQ Something", an address at example.test or example.invalid. That naming
-- convention is what makes this checkable, which is the reason for it.
--
-- Written out table by table rather than looped over information_schema with
-- dynamic SQL. The looped version reported two columns that, asked directly in
-- three other ways, hold nothing - and a detector that cries wolf is worse than
-- none, because the next person to see it will assume it is lying again. These
-- are the tables the verification scripts actually write to, taken from the
-- scripts themselves.
--
-- scripts/check-verify-scripts.mjs is the other half: it stops a script that
-- could leak from being written at all.

do $$
declare
  found text[] := '{}';
  v_n   bigint;
begin
  select count(*) into v_n from public.clients where name like 'ZZ %' or name like 'ZQ %';
  if v_n > 0 then found := found || format('clients (%s)', v_n); end if;

  select count(*) into v_n from public.counselors
   where name like 'ZZ %' or name like 'ZQ %' or email like '%example.invalid%' or email like '%example.test%';
  if v_n > 0 then found := found || format('counselors (%s)', v_n); end if;

  select count(*) into v_n from public.staff
   where name like 'ZZ %' or name like 'ZQ %' or email like '%example.test%' or email like '%example.invalid%';
  if v_n > 0 then found := found || format('staff (%s)', v_n); end if;

  select count(*) into v_n from public.authorizations
   where number like 'ZZ%' or number like 'ZQ%' or note like 'ZZ %';
  if v_n > 0 then found := found || format('authorizations (%s)', v_n); end if;

  select count(*) into v_n from public.service_entries where notes like 'ZZ %' or notes like 'ZQ %';
  if v_n > 0 then found := found || format('service_entries (%s)', v_n); end if;

  select count(*) into v_n from public.attachments where filename like 'zz%' or storage_path like '%zz-proof%';
  if v_n > 0 then found := found || format('attachments (%s)', v_n); end if;

  select count(*) into v_n from public.inbox_documents where folder_name like 'ZZ %' or filename like 'zz%';
  if v_n > 0 then found := found || format('inbox_documents (%s)', v_n); end if;

  select count(*) into v_n from public.notes where text like 'ZZ %';
  if v_n > 0 then found := found || format('notes (%s)', v_n); end if;

  select count(*) into v_n from public.contact_log where topic like 'ZZ %' or outcome like 'ZZ %';
  if v_n > 0 then found := found || format('contact_log (%s)', v_n); end if;

  select count(*) into v_n from public.tasks where title like 'ZZ %';
  if v_n > 0 then found := found || format('tasks (%s)', v_n); end if;

  select count(*) into v_n from public.work_sessions where description like 'ZZ %';
  if v_n > 0 then found := found || format('work_sessions (%s)', v_n); end if;

  select count(*) into v_n from public.vendors where name like 'ZZ %' or name like 'ZQ %';
  if v_n > 0 then found := found || format('vendors (%s)', v_n); end if;

  -- The logins, which are how a fixture staff member would still be able to
  -- sign in, and which live in another schema.
  select count(*) into v_n from auth.users
   where email like '%example.test%' or email like '%example.invalid%'
      or email like 'zz-%' or email like 'zq-%';
  if v_n > 0 then found := found || format('auth.users (%s)', v_n); end if;

  if array_length(found, 1) > 0 then
    raise exception E'FAILED: a verification''s fixtures are still in the database: %',
      array_to_string(found, ', ');
  end if;

  raise notice 'ok  nothing a verification built is still in the database';
  raise notice '';
  raise notice '--- NO FIXTURES LEFT BEHIND ---';
end $$;
