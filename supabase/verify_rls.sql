-- Zion Vocational Rehab CRM — row-level security verification
--
-- Creates four throwaway staff members, signs in as each by setting the JWT
-- claim that auth.uid() reads, and checks what each can actually see. This is
-- the test that matters: the restricted tier is a claim about the database,
-- not about the interface, so it has to be proved at the database.
--
-- Everything runs inside a transaction that is rolled back.

begin;

do $$
declare
  admin_id  uuid := gen_random_uuid();
  mine_id   uuid := gen_random_uuid();
  other_id  uuid := gen_random_uuid();
  bill_id   uuid := gen_random_uuid();
  v_client  uuid;
  v_staff   uuid;

  procedure_note text;
begin
  -- Staff rows must exist before the auth users: migration 0005 refuses to
  -- create a login for an address with no staff account. That it works here is
  -- itself a check on the invite-only rule.
  insert into public.staff (name, email, role, active) values
    ('ZZ Admin',    'zz-admin@example.test', 'Admin',      true),
    ('ZZ Assigned', 'zz-mine@example.test',  'Job Search', true),
    ('ZZ Other',    'zz-other@example.test', 'Job Search', true),
    ('ZZ Billing',  'zz-bill@example.test',  'Billing',    true);

  insert into auth.users (instance_id, id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at)
  values
    ('00000000-0000-0000-0000-000000000000', admin_id, 'authenticated', 'authenticated',
     'zz-admin@example.test', '', now(), now(), now()),
    ('00000000-0000-0000-0000-000000000000', mine_id,  'authenticated', 'authenticated',
     'zz-mine@example.test',  '', now(), now(), now()),
    ('00000000-0000-0000-0000-000000000000', other_id, 'authenticated', 'authenticated',
     'zz-other@example.test', '', now(), now(), now()),
    ('00000000-0000-0000-0000-000000000000', bill_id,  'authenticated', 'authenticated',
     'zz-bill@example.test',  '', now(), now(), now());

  select id into v_staff from public.staff where email = 'zz-mine@example.test';

  insert into public.clients (name, assigned_staff_id) values ('ZZ RLS Client', v_staff)
    returning id into v_client;

  insert into public.client_private (client_id, dob, address)
    values (v_client, '1990-01-01', '1 Test Street');

  insert into public.intakes (client_id, consent_signed, accommodations)
    values (v_client, true, 'Test accommodation');

  insert into public.forms (template_id, client_id, status) values ('wsa', v_client, 'Draft');
  insert into public.forms (template_id, client_id, status) values ('usor96', v_client, 'Draft');

  insert into public.notes (client_id, text, visible_roles)
    values (v_client, 'Billing-only note', array['Admin','Billing']);

  -- Attachments, and the stored objects behind them.
  insert into public.attachments (client_id, storage_path, filename, category, restricted, uploaded_by)
  values
    (v_client, 'clients/' || v_client || '/zz-restricted.pdf', 'zz-restricted.pdf',
     'Signed intake', true, v_staff),
    (v_client, 'clients/' || v_client || '/zz-open.pdf', 'zz-open.pdf',
     'Work schedule', false, v_staff);

  insert into storage.objects (bucket_id, name)
  values
    ('client-files', 'clients/' || v_client || '/zz-restricted.pdf'),
    ('client-files', 'clients/' || v_client || '/zz-open.pdf');

  procedure_note := 'checked';
  raise notice 'fixtures created (client, restricted row, intake, USOR 94, USOR 96, note, 2 files)';
end $$;

-- ─────────────────────────────────────────────────────────────
-- What each role can see
-- ─────────────────────────────────────────────────────────────
do $$
declare
  r            record;
  v_private    int;
  v_intakes    int;
  v_sensitive  int;
  v_openform   int;
  v_notes      int;
  v_clients    int;
  v_files      int;
  v_openfile   int;
  v_object     int;
  failures     text[] := '{}';
begin
  for r in
    select s.role, s.name, u.id as uid,
           (s.email = 'zz-mine@example.test') as is_assigned
      from public.staff s join auth.users u on u.id = s.user_id
     where s.email like 'zz-%@example.test'
     order by s.name
  loop
    -- Become that user for the duration of these queries.
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims',
                       json_build_object('sub', r.uid, 'role', 'authenticated')::text, true);

    -- Scoped to the throwaway client. Counting whole tables would pass or fail
    -- depending on how much real data happens to be loaded.
    select count(*) into v_clients   from public.clients where name = 'ZZ RLS Client';

    select count(*) into v_private
      from public.client_private cp
      join public.clients c on c.id = cp.client_id
     where c.name = 'ZZ RLS Client';

    select count(*) into v_intakes
      from public.intakes i
      join public.clients c on c.id = i.client_id
     where c.name = 'ZZ RLS Client';

    select count(*) into v_sensitive
      from public.forms f
      join public.clients c on c.id = f.client_id
     where c.name = 'ZZ RLS Client' and f.template_id = 'wsa';

    select count(*) into v_openform
      from public.forms f
      join public.clients c on c.id = f.client_id
     where c.name = 'ZZ RLS Client' and f.template_id = 'usor96';

    select count(*) into v_notes      from public.notes where text = 'Billing-only note';
    select count(*) into v_files      from public.attachments where filename = 'zz-restricted.pdf';
    select count(*) into v_openfile   from public.attachments where filename = 'zz-open.pdf';
    -- The bytes, not just the row: this is what a signed URL depends on.
    select count(*) into v_object     from storage.objects
      where bucket_id = 'client-files' and name like '%zz-restricted.pdf';

    perform set_config('role', 'postgres', true);
    perform set_config('request.jwt.claims', '', true);

    raise notice '% (%): client=% private=% intake=% usor94=% usor96=% note=% file=% object=%',
      r.name, r.role, v_clients, v_private, v_intakes, v_sensitive, v_openform, v_notes,
      v_files, v_object;

    -- Everyone sees every client. That is the design.
    if v_clients <> 1 then
      failures := failures || format('%s cannot see the client', r.name);
    end if;

    -- Non-sensitive forms are open to all active staff.
    if v_openform <> 1 then
      failures := failures || format('%s cannot see the USOR 96', r.name);
    end if;

    -- Every active staff member can reach an ordinary document.
    if v_openfile <> 1 then
      failures := failures || format('%s cannot see the unrestricted file', r.name);
    end if;

    if r.role = 'Admin' or r.role = 'Reports' or r.is_assigned then
      if v_private <> 1 then failures := failures || format('%s should see the restricted row', r.name); end if;
      if v_intakes <> 1 then failures := failures || format('%s should see the intake', r.name); end if;
      if v_sensitive <> 1 then failures := failures || format('%s should see the USOR 94', r.name); end if;
      if v_files <> 1 then failures := failures || format('%s should see the restricted file', r.name); end if;
      if v_object <> 1 then failures := failures || format('%s should be able to fetch the restricted file', r.name); end if;
    else
      if v_private <> 0 then failures := failures || format('LEAK: %s can see the restricted row', r.name); end if;
      if v_intakes <> 0 then failures := failures || format('LEAK: %s can see the intake', r.name); end if;
      if v_sensitive <> 0 then failures := failures || format('LEAK: %s can see the USOR 94', r.name); end if;
      if v_files <> 0 then failures := failures || format('LEAK: %s can see the restricted file', r.name); end if;
      if v_object <> 0 then failures := failures || format('LEAK: %s can fetch the bytes of the restricted file', r.name); end if;
    end if;

    -- The note is tagged Admin + Billing only.
    if r.role in ('Admin', 'Billing') then
      if v_notes <> 1 then failures := failures || format('%s should see the note', r.name); end if;
    else
      if v_notes <> 0 then failures := failures || format('LEAK: %s can see the Billing-only note', r.name); end if;
    end if;
  end loop;

  if array_length(failures, 1) is not null then
    raise exception E'RLS FAILURES:\n  %', array_to_string(failures, E'\n  ');
  end if;

  raise notice '--- RLS VERIFIED ---';
end $$;

-- ─────────────────────────────────────────────────────────────
-- Deactivation removes access on the next query
-- ─────────────────────────────────────────────────────────────
do $$
declare
  uid      uuid;
  n_before int;
  n_after  int;
begin
  select u.id into uid
    from public.staff s join auth.users u on u.id = s.user_id
   where s.email = 'zz-mine@example.test';

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', uid, 'role', 'authenticated')::text, true);
  select count(*) into n_before from public.clients where name = 'ZZ RLS Client';
  perform set_config('role', 'postgres', true);

  update public.staff set active = false where email = 'zz-mine@example.test';

  perform set_config('role', 'authenticated', true);
  select count(*) into n_after from public.clients where name = 'ZZ RLS Client';
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  raise notice 'assigned staff sees % client(s) while active, % after deactivation',
    n_before, n_after;

  if n_before <> 1 or n_after <> 0 then
    raise exception 'FAILED: deactivation did not remove access immediately';
  end if;

  raise notice '--- OFFBOARDING VERIFIED ---';
end $$;

rollback;
