-- Zion Vocational Rehab CRM — the other spellings of a client's name (0303)
--
-- What has to hold:
--
--   A document or an email that arrives under a spelling on file finds the
--   client, and says that is what happened rather than claiming it matched
--   the name.
--
--   Somebody who types the spelling they were sent finds the person, and
--   finds them once however many spellings match.
--
--   One spelling means one person. Two clients cannot share one, and a
--   spelling cannot be somebody else's own name - a matcher with two answers
--   has none.
--
--   A spelling on a record that was later merged away finds the record it was
--   merged into, the same way its name does.
--
--   Nobody signed out can read any of it.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_admin uuid; v_admin_uid uuid := gen_random_uuid();
  v_a uuid; v_b uuid; v_old uuid;
  v_found uuid; v_how text; v_n integer;
  failures text[] := '{}';
begin
  insert into public.staff (name, email, role, active)
  values ('ZZ Alias Admin', 'zz-alias-admin@example.test', 'Admin', true) returning id into v_admin;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_admin_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-alias-admin@example.test', '{}', '{}', now(), now());

  insert into public.clients (name, stage, status) values ('ZZ Quenneville', 'Assessment', 'Active') returning id into v_a;
  insert into public.clients (name, stage, status) values ('ZQ Other Person', 'Assessment', 'Active') returning id into v_b;
  insert into public.clients (name, stage, status) values ('ZZ Merged Away', 'Assessment', 'Closed') returning id into v_old;

  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_admin_uid, 'role', 'authenticated')::text, true);

  insert into public.client_aliases (client_id, name, source, added_by, added_by_name)
  values (v_a, 'ZZ Quennville', 'Warrant', v_admin, 'ZZ Alias Admin');

  -- ── an arriving document finds the person ──────────────────
  select client_id, how into v_found, v_how from public.intake_find_client('ZZ Quennville');
  if v_found is distinct from v_a then
    failures := failures || 'FAILED: a document under a spelling on file did not find the client'::text;
  elsif v_how <> 'another spelling of this name' then
    failures := failures || format('FAILED: the match was reported as "%s" rather than as a spelling', v_how)::text;
  else
    raise notice 'ok  a document arriving under another spelling finds the client, and says so';
  end if;

  -- Case and stray spaces are not a different spelling.
  select client_id into v_found from public.intake_find_client('  zz quennVILLE ');
  if v_found is distinct from v_a then
    failures := failures || 'FAILED: the same spelling in another case did not match'::text;
  else
    raise notice 'ok  case and surrounding spaces are not a different name';
  end if;

  -- ── and the search box finds them, once ────────────────────
  select count(*) into v_n from public.search_clients('Quennville', 50) where id = v_a;
  if v_n <> 1 then
    failures := failures || format('FAILED: searching the spelling returned the client %s time(s)', v_n)::text;
  else
    -- Two spellings, still one row: a join that multiplied the client by its
    -- aliases would list them twice and look like two people.
    insert into public.client_aliases (client_id, name, source, added_by, added_by_name)
    values (v_a, 'ZZ Quennevile', 'Email', v_admin, 'ZZ Alias Admin');
    select count(*) into v_n from public.search_clients('Quenne', 50) where id = v_a;
    if v_n <> 1 then
      failures := failures || format('FAILED: a client with two matching spellings was listed %s times', v_n)::text;
    else
      raise notice 'ok  the search box finds the person by a spelling, and lists them once however many match';
    end if;
  end if;

  -- ── one spelling, one person ───────────────────────────────
  begin
    insert into public.client_aliases (client_id, name, source, added_by, added_by_name)
    values (v_b, 'ZZ Quennville', 'Warrant', v_admin, 'ZZ Alias Admin');
    failures := failures || 'FAILED: two clients were given the same spelling'::text;
  exception when unique_violation then
    raise notice 'ok  one spelling cannot belong to two people';
  end;

  begin
    insert into public.client_aliases (client_id, name, source, added_by, added_by_name)
    values (v_a, 'ZQ Other Person', 'Warrant', v_admin, 'ZZ Alias Admin');
    failures := failures || 'FAILED: a spelling that is another client''s own name was allowed'::text;
  exception when unique_violation then
    raise notice 'ok  a spelling cannot be somebody else''s own name';
  end;

  -- And nothing stops a record answering to its own name written differently
  -- by somebody else, which is the whole point.
  begin
    insert into public.client_aliases (client_id, name, source, added_by, added_by_name)
    values (v_a, 'ZZ Quenneville ', 'Staff', v_admin, 'ZZ Alias Admin');
    failures := failures || 'FAILED: a spelling identical to the record''s own name was allowed'::text;
  exception when unique_violation then
    raise notice 'ok  a record''s own name is not also stored as a spelling of itself';
  end;

  -- ── a spelling on a record that was merged away ────────────
  insert into public.client_aliases (client_id, name, source, added_by, added_by_name)
  values (v_old, 'ZZ Mergd Away', 'Warrant', v_admin, 'ZZ Alias Admin');
  perform public.merge_clients(v_old, v_a);

  select client_id into v_found from public.intake_find_client('ZZ Mergd Away');
  if v_found is distinct from v_a then
    failures := failures || 'FAILED: a spelling on a merged-away record does not find the record it went into'::text;
  else
    raise notice 'ok  a spelling on a record that was merged away finds the one it was merged into';
  end if;

  -- ── and none of it is readable signed out ──────────────────
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  if has_table_privilege('anon', 'public.client_aliases', 'select')
     or has_table_privilege('anon', 'public.client_aliases', 'insert') then
    failures := failures || 'FAILED: somebody not signed in can reach the spellings'::text;
  else
    raise notice 'ok  nobody signed out can read or add a spelling';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
