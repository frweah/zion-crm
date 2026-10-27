-- Zion Vocational Rehab CRM — what a view lets somebody do (0257, 0259)
--
-- Supabase's default privileges hand `authenticated` INSERT, UPDATE, DELETE,
-- TRUNCATE, REFERENCES and TRIGGER on everything created in schema `public`,
-- views included, so a view written to be read arrives writable without
-- anybody granting a thing. 0257 took those back on the nine views that read
-- `authorizations`; 0259 took them off the remaining twenty-four. What has to
-- hold afterwards is both halves of that:
--
--   nobody can write through a view in `public`;
--   every role still reads everything it read before.
--
-- The first half is asked of the catalogue rather than of a list of names.
-- A list is what let this happen in the first place: `check-quick-add` named
-- six kinds and went stale the month three more arrived, and a list of views
-- here would go stale the day somebody adds one. So the question is whether
-- any view in `public` gives anybody more than SELECT, and a view created
-- tomorrow is judged by it without being added to anything.
--
-- Then the rule underneath, which is narrower and worse: a view
-- `authenticated` can write through has to send the write back to the base
-- table to be checked as the person, which is what `security_invoker` does.
-- Without it the write runs as the view's owner and neither the table's
-- privileges nor its policies are consulted. That one is kept even though the
-- clause above rules it out today, because the day a view is deliberately
-- made writable it is the condition that still has to hold.
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
  -- Every view in `public`, read from the catalogue each time this runs.
  v_views text[] := (select array_agg(c.relname order by c.relname)
                       from pg_class c
                       join pg_namespace ns on ns.oid = c.relnamespace
                      where ns.nspname = 'public' and c.relkind = 'v');
  -- The offending (role, privilege, view) triples, counted and named. Held as
  -- text because it is asked twice: once of the schema as it stands, once
  -- with a write put back on purpose.
  v_sql text := $q$
    select count(*),
           coalesce(string_agg(format('%s has %s on %s', who, upper(priv), relname),
                               ', ' order by relname, priv), '')
      from (
        select c.relname, p.priv, w.who
          from pg_class c
          join pg_namespace ns on ns.oid = c.relnamespace
          cross join unnest(array['insert','update','delete','truncate','references','trigger']) as p(priv)
          cross join unnest(array['anon','authenticated']) as w(who)
         where ns.nspname = 'public' and c.relkind = 'v'
           and has_table_privilege(w.who, c.oid, p.priv)
      ) t
  $q$;
  v_name     text;
  v_detail   text;
  v_n        integer;
  v_rows     integer;
  v_blanked  integer;
  v_person   record;
  v_mark     integer;
  failures   text[] := '{}';
begin
  if coalesce(array_length(v_views, 1), 0) = 0 then
    raise exception 'no views found in public, so this suite is asking nothing';
  end if;

  -- ── 1. a view is a way to read, and nothing else ──────────
  execute v_sql into v_n, v_detail;
  if v_n <> 0 then
    failures := failures || format('FAILED: %s', v_detail)::text;
  else
    raise notice 'ok  none of the % views in public gives anybody more than SELECT', array_length(v_views, 1);

    -- Put one back and it has to be found and named, or the clause above is a
    -- question nothing can fail. Only worth asking when the schema is clean:
    -- from a dirty one the extra grant proves nothing, and saying so would
    -- bury the grants that are really there under a complaint about this one.
    grant update on public.updates_for_me to authenticated;
    execute v_sql into v_n, v_detail;
    if v_n <> 1 or v_detail not like '%UPDATE on updates_for_me%' then
      failures := failures ||
        format('FAILED: a write granted on a view on purpose was not noticed (%s found: %s)', v_n, v_detail)::text;
    else
      raise notice 'ok  and one granted on purpose is named';
    end if;
    revoke update on public.updates_for_me from authenticated;
  end if;

  v_mark := coalesce(array_length(failures, 1), 0);
  foreach v_name in array v_views loop
    if not has_table_privilege('authenticated', 'public.' || v_name, 'select') then
      failures := failures || format('FAILED: authenticated cannot read %s', v_name)::text;
    end if;
    if has_table_privilege('anon', 'public.' || v_name, 'select') then
      failures := failures || format('FAILED: anon can read %s', v_name)::text;
    end if;
  end loop;
  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice 'ok  authenticated reads every one of them and anon reads none';
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
