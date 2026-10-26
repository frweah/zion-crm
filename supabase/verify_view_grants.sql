-- Zion Vocational Rehab CRM — what a view lets somebody do (0257)
--
-- Supabase's default privileges hand `authenticated` INSERT, UPDATE, DELETE
-- and TRUNCATE on everything created in schema `public`, views included, so a
-- view written to be read arrives writable without anybody granting a thing.
-- 0257 took those back on the nine views that read `authorizations`. What has
-- to hold afterwards is both halves of that:
--
--   nobody can write through one of them;
--   every role still reads everything it read before.
--
-- Then the rule underneath, stated as the hazard rather than as a list of
-- names: a view `authenticated` can write through has to send the write back
-- to the base table to be checked as the person, which is what
-- `security_invoker` does. Without it the write runs as the view's owner and
-- neither the table's privileges nor its policies are consulted.
--
-- And `client_documents`, which is the one view in `public` with no
-- `security_invoker` and keeps it that way deliberately. It reads
-- `attachments` with the view owner's rights so that a restricted document
-- comes back as a row with its category, filename, note and path blanked and
-- `can_open` false - the practice shows that a document exists and that this
-- person may not open it. `attachments`'s own read policy stops at
-- `not restricted or can_see_restricted(client_id)`, so reading as the
-- invoker would not blank those rows, it would delete them from the screen:
-- measured on 26 Oct 2026, Billing and Case Manager each lose 109 of 776 and
-- Job Search 42. What makes it safe is not `security_invoker` but having no
-- way in at all - SELECT and nothing else - and that is what is asserted here,
-- so the day somebody grants a write on it this fails.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_views text[] := array[
    'authorization_economics', 'authorization_record', 'billed_work',
    'billing_position', 'client_activity', 'client_authorizations',
    'client_last_activity', 'client_paperwork', 'client_pipeline',
    'staff_capacity'];
  v_name     text;
  v_priv     text;
  v_n        integer;
  v_rows     integer;
  v_blanked  integer;
  v_person   record;
  v_mark     integer;
  failures   text[] := '{}';
begin
  -- ── 1. read, and nothing else ─────────────────────────────
  v_mark := coalesce(array_length(failures, 1), 0);
  foreach v_name in array v_views loop
    if not has_table_privilege('authenticated', 'public.' || v_name, 'select') then
      failures := failures || format('FAILED: authenticated cannot read %s', v_name)::text;
    end if;
    foreach v_priv in array array['insert', 'update', 'delete', 'truncate', 'references', 'trigger'] loop
      if has_table_privilege('authenticated', 'public.' || v_name, v_priv) then
        failures := failures || format('FAILED: authenticated has %s on %s', upper(v_priv), v_name)::text;
      end if;
      if has_table_privilege('anon', 'public.' || v_name, v_priv) then
        failures := failures || format('FAILED: anon has %s on %s', upper(v_priv), v_name)::text;
      end if;
    end loop;
    if has_table_privilege('anon', 'public.' || v_name, 'select') then
      failures := failures || format('FAILED: anon can read %s', v_name)::text;
    end if;
  end loop;
  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice 'ok  each of the % views onto authorizations gives authenticated SELECT and nothing else', array_length(v_views, 1);
  end if;

  -- ── 2. and every role still reads all of them ─────────────
  --
  -- The point of the change was to take away what nobody used. This is the
  -- half that says nothing anybody did use went with it: each person on the
  -- practice, each view, counted as them.
  v_mark := coalesce(array_length(failures, 1), 0);
  for v_person in
    select s.role, s.user_id
      from public.staff s
     where s.active and s.user_id is not null and not coalesce(s.is_system, false)
     order by s.role
  loop
    foreach v_name in array v_views loop
      perform set_config('role', 'authenticated', true);
      perform set_config('request.jwt.claims',
        json_build_object('sub', v_person.user_id::text, 'role', 'authenticated')::text, true);
      begin
        execute format('select count(*) from public.%I', v_name) into v_n;
      exception when insufficient_privilege then
        v_n := -1;
      end;
      perform set_config('role', 'postgres', true);
      perform set_config('request.jwt.claims', '', true);

      if v_n < 0 then
        failures := failures || format('FAILED: %s can no longer read %s', v_person.role, v_name)::text;
      end if;
    end loop;
  end loop;
  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice 'ok  and every role on the practice still reads every one of them';
  end if;

  -- ── 3. a writable view sends the write back to the table ──
  select count(*) into v_n
    from pg_class c
    join pg_namespace ns on ns.oid = c.relnamespace
    join information_schema.views v
      on v.table_schema = 'public' and v.table_name = c.relname
   where ns.nspname = 'public' and c.relkind = 'v'
     and v.is_insertable_into = 'YES'
     and (has_table_privilege('authenticated', c.oid, 'insert')
       or has_table_privilege('authenticated', c.oid, 'update')
       or has_table_privilege('authenticated', c.oid, 'delete'))
     and not coalesce(c.reloptions::text like '%security_invoker=true%', false);
  if v_n <> 0 then
    failures := failures ||
      format('FAILED: %s view(s) can be written to without the base table being consulted', v_n)::text;
  else
    raise notice 'ok  no view authenticated can write through decides the write for itself';
  end if;

  -- The check is reading something. Put a view of that exact shape in and it
  -- has to be found, or the clause above is a question nothing can fail.
  create view public.zz_fault_door as select id, status from public.authorizations;
  grant insert on public.zz_fault_door to authenticated;
  select count(*) into v_n
    from pg_class c
    join pg_namespace ns on ns.oid = c.relnamespace
    join information_schema.views v
      on v.table_schema = 'public' and v.table_name = c.relname
   where ns.nspname = 'public' and c.relkind = 'v'
     and v.is_insertable_into = 'YES'
     and (has_table_privilege('authenticated', c.oid, 'insert')
       or has_table_privilege('authenticated', c.oid, 'update')
       or has_table_privilege('authenticated', c.oid, 'delete'))
     and not coalesce(c.reloptions::text like '%security_invoker=true%', false);
  if v_n <> 1 then
    failures := failures ||
      'FAILED: a view granted INSERT with no security_invoker was not noticed'::text;
  else
    raise notice 'ok  and one put in on purpose is noticed';
  end if;
  drop view public.zz_fault_door;

  -- ── 4. client_documents, and why it has no invoker ────────
  if coalesce((select c.reloptions::text like '%security_invoker=true%'
                 from pg_class c where c.oid = 'public.client_documents'::regclass), false) then
    failures := failures ||
      'FAILED: client_documents reads as the invoker, which drops every restricted document instead of blanking it'::text;
  else
    raise notice 'ok  client_documents still reads with the owner rights that let it blank a restricted document';
  end if;

  v_mark := coalesce(array_length(failures, 1), 0);
  foreach v_priv in array array['insert', 'update', 'delete', 'truncate'] loop
    if has_table_privilege('authenticated', 'public.client_documents', v_priv) then
      failures := failures ||
        format('FAILED: authenticated has %s on client_documents, which reads as its owner', upper(v_priv))::text;
    end if;
  end loop;
  if has_table_privilege('anon', 'public.client_documents', 'select') then
    failures := failures || 'FAILED: anon can read client_documents'::text;
  end if;
  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice 'ok  and it is SELECT and nothing else, which is what keeps that safe';
  end if;

  -- And the blanking it exists for is really happening. Billing is not the
  -- assigned worker on these clients and holds no restricted grant, so a
  -- restricted document has to come back as a row that says it cannot be
  -- opened - not as no row.
  select s.role, s.user_id into v_person
    from public.staff s
   where s.active and s.user_id is not null and s.role = 'Billing'
     and not coalesce(s.is_system, false)
   order by s.created_at limit 1;
  if v_person.user_id is not null then
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_person.user_id::text, 'role', 'authenticated')::text, true);
    select count(*) into v_rows from public.client_documents;
    select count(*) into v_blanked from public.client_documents where not can_open;
    perform set_config('role', 'postgres', true);
    perform set_config('request.jwt.claims', '', true);

    if v_blanked = 0 then
      failures := failures ||
        'FAILED: Billing sees no blanked document at all, so either there are none restricted or the rows are being hidden'::text;
    else
      raise notice 'ok  Billing sees all % documents, % of them blanked rather than missing', v_rows, v_blanked;
    end if;
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- VIEW GRANTS VERIFIED ---';
end $$;

rollback;
