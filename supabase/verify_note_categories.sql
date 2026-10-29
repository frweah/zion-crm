-- A note says which service it is about, and Personal says nothing to anybody
--
-- The database half of 0266. check-reports asserts the screens and the
-- category list agree; this asserts the database does what the screens assume:
-- fills a missing category from the stage, refuses one off the list, and
-- narrows a Personal note whatever the screen asked for.
--
-- Rollback-wrapped, like every script that writes.

begin;

do $$
declare
  failures  text[] := '{}';
  v_client  uuid;
  v_other   uuid;
  v_cat     text;
  v_roles   text[];
  v_n       int;
  f         text;
begin
  -- ── fixtures ───────────────────────────────────────────────
  insert into public.clients (name, stage, status)
  values ('ZZ Category Testperson', 'Job Coaching', 'Active')
  returning id into v_client;

  insert into public.clients (name, stage, status)
  values ('ZZ Unstaged Testperson', 'Intake', 'Active')
  returning id into v_other;

  -- ── a note with no category gets the one its client implies ──
  insert into public.notes (client_id, text, at, staff_name)
  values (v_client, 'ZQ a note nobody categorised', public.practice_today(), 'ZQ Tester')
  returning category into v_cat;

  if v_cat is distinct from 'Job coaching' then
    failures := failures || format(
      'FAILED: a note on a Job Coaching client was filed as %s rather than Job coaching',
      coalesce(v_cat, 'nothing'))::text;
  else
    raise notice 'ok  a note with no category takes the one the client''s stage implies';
  end if;

  -- Intake is not a service, and a guess that lands in a billed service is a
  -- guess that reaches a counselor. It falls to General progress instead.
  insert into public.notes (client_id, text, at, staff_name)
  values (v_other, 'ZQ a note on a client at intake', public.practice_today(), 'ZQ Tester')
  returning category into v_cat;

  if v_cat is distinct from 'General progress' then
    failures := failures || format(
      'FAILED: a note on an Intake client was filed as %s rather than General progress',
      coalesce(v_cat, 'nothing'))::text;
  else
    raise notice 'ok  a stage that is not a service falls to General progress, not to a billed one';
  end if;

  -- ── the list is the list ───────────────────────────────────
  begin
    insert into public.notes (client_id, text, at, staff_name, category)
    values (v_client, 'ZQ a note about vibes', public.practice_today(), 'ZQ Tester', 'Vibes');
    failures := failures || 'FAILED: a category that is not on the list was accepted'::text;
  exception when check_violation then
    raise notice 'ok  a category off the list is refused rather than stored';
  end;

  -- And every category the screens offer is one the database takes, which is
  -- the other direction of the same question - a list the screens have and the
  -- database does not is a note somebody loses on save.
  foreach f in array array['Job development', 'Job placement', 'Job coaching', 'Job search',
                           'Assessment', 'Life skills', 'General progress', 'Personal']
  loop
    begin
      insert into public.notes (client_id, text, at, staff_name, category)
      values (v_client, format('ZQ a %s note', f), public.practice_today(), 'ZQ Tester', f);
    exception when others then
      failures := failures || format('FAILED: the database refused the category %s', f)::text;
    end;
  end loop;
  if not exists (select 1 from unnest(failures) x where x like '%refused the category%') then
    raise notice 'ok  all eight categories the screens offer are categories the database takes';
  end if;

  -- ── Personal is narrowed whatever was asked for ────────────
  insert into public.notes (client_id, text, at, staff_name, category, visible_roles)
  values (v_client, 'ZQ something personal', public.practice_today(), 'ZQ Tester', 'Personal',
          array['Admin', 'Reports', 'Job Search', 'Billing'])
  returning visible_roles into v_roles;

  if 'Reports' = any (v_roles) or 'Job Search' = any (v_roles) or 'Billing' = any (v_roles) then
    failures := failures || format(
      'FAILED: a Personal note kept the roles the screen asked for: %s', v_roles)::text;
  elsif not ('Admin' = any (v_roles)) then
    failures := failures || 'FAILED: a Personal note is not visible to Admin, who can see everything'::text;
  else
    raise notice 'ok  a Personal note is narrowed to Admin and Case Manager whatever the screen sent';
  end if;

  -- The report roles are the four a monthly report is built for. None of them
  -- may be the whole set on a Personal note, which is what makes the report
  -- withhold its words even if the category filter were ever taken out.
  select count(*) into v_n
    from public.notes
   where client_id = v_client
     and category = 'Personal'
     and visible_roles @> array['Admin', 'Reports', 'Job Search', 'Billing'];
  if v_n > 0 then
    failures := failures || format(
      'FAILED: %s Personal note(s) are visible to all four report roles', v_n)::text;
  else
    raise notice 'ok  no Personal note is open to all four roles a report is built for';
  end if;

  -- ── changing a note to Personal narrows it too ─────────────
  -- The trigger fires on update of the category as well as on insert, because
  -- the usual way a note becomes personal is somebody realising it afterwards.
  update public.notes
     set category = 'Personal'
   where client_id = v_client and text = 'ZQ a Job search note'
  returning visible_roles into v_roles;

  if 'Reports' = any (coalesce(v_roles, '{}')) then
    failures := failures || 'FAILED: a note changed to Personal kept the roles it had'::text;
  else
    raise notice 'ok  a note changed to Personal is narrowed on the way';
  end if;

  -- ── and it cannot be emptied afterwards ────────────────────
  -- The insert trigger fills a missing category, so nothing arrives without
  -- one; this is the other half, and the two are not interchangeable. With
  -- NOT NULL dropped the trigger still fills an insert - so a check that only
  -- inserted would pass - but an update to null goes straight through, and the
  -- callers that do that kind of thing are migrations and scripts holding the
  -- service key, which is most of what writes here.
  begin
    update public.notes set category = null
     where client_id = v_client and text = 'ZQ a note nobody categorised';
    failures := failures || 'FAILED: a note can be left with no category by anything that updates it'::text;
  exception when not_null_violation then
    raise notice 'ok  a category cannot be emptied once the note exists';
  end;

  -- ── the map is one map ─────────────────────────────────────
  if public.category_for_stage('Job Placement') is distinct from 'Job placement' then
    failures := failures || format(
      'FAILED: Job Placement maps to %s rather than to Job placement',
      public.category_for_stage('Job Placement'))::text;
  elsif public.category_for_stage('Job Development') is distinct from 'Job development' then
    failures := failures || 'FAILED: Job Development no longer maps to Job development'::text;
  elsif public.category_for_stage('something nobody has added yet') is distinct from 'General progress' then
    failures := failures || 'FAILED: a stage the map does not know lands somewhere other than General progress'::text;
  else
    raise notice 'ok  the stage map answers for the stages it knows and for the ones it does not';
  end if;

  -- ── report ─────────────────────────────────────────────────
  if array_length(failures, 1) > 0 then
    foreach f in array failures loop raise notice '%', f; end loop;
    raise exception 'verify_note_categories: % failure(s)', array_length(failures, 1);
  end if;
  raise notice '--- NOTE CATEGORIES VERIFIED ---';
end $$;

rollback;
