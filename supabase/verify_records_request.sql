-- Zion Vocational Rehab CRM — answering a records request
--
-- The claim is completeness, and completeness is the hard thing to test:
-- everything held about a person has to be in the bundle, and "everything"
-- grows every time a table is added. So this checks two different things.
--
--   That what is there, is there. A client with something in every corner of
--   the system comes back with all of it.
--
--   That nothing has been added since without being included. Every table in
--   the schema that holds a client_id is either in the bundle or on a written
--   list of the ones that deliberately are not — so the next table somebody
--   adds fails this script rather than quietly going missing from the answer
--   to a legal request.
--
-- And the rest: only Admin, and producing one is logged before a single field
-- is returned.
--
-- Runs inside a transaction that is rolled back.

begin;

do $$
declare
  v_admin    uuid;
  v_adm_uid  uuid;
  v_other    uuid;
  v_oth_uid  uuid;
  v_role     text;
  v_client   uuid;
  v_auth     uuid;
  v_before   bigint;
  v_bundle   jsonb;
  v_count    int;
  v_missing  text[] := '{}';
  v_tbl      text;
  failures   text[] := '{}';

  -- Which section of the bundle each table's rows come out in. The sections
  -- are named for people rather than for tables — work_sessions appear under
  -- "service hours", mail_log under "email" — so the mapping is written down
  -- rather than guessed at. The first version of this check tried to match
  -- the names to each other and reported eight tables missing that were all
  -- present; a heuristic that cries wolf about a legal obligation is worse
  -- than no check.
  covered constant text[] := array[
    'clients=client',
    'client_private=restricted_details',
    'intakes=intake',
    'client_stage_history=stage_history',
    'notes=notes',
    'contact_log=counselor_contacts',
    'tasks=tasks',
    'authorizations=authorizations',
    'invoices=invoices',
    'work_sessions=service_hours',
    'forms=forms',
    'placements=placements',
    'lead_matches=jobs_applied_for',
    'calendar_events=appointments',
    'sms_messages=texts',
    'sms_consent_events=texting_consent',
    'mail_log=email',
    'attachments=files',
    'access_log=who_read_this_record'
  ];

  -- Tables carrying a client_id that are deliberately not in a bundle, each
  -- with the reason. Anything in neither list is a hole.
  skipped constant text[] := array[
    'notifications',         -- our own nagging, not the client's record
    'expenses',              -- a staff member's mileage claim, not their file
    'inbox_documents',       -- plumbing; the filed copy is in attachments
    'inbox_folder_map',      -- a folder name on somebody's PC
    'work_session_timers',   -- a running stopwatch, gone in an hour
    'legal_holds',           -- about the record rather than in it
    'retention_dispositions',
    'records_requests'       -- the request, not the record
  ];
begin
  select id, user_id into v_admin, v_adm_uid from public.staff
   where role = 'Admin' and active order by created_at limit 1;
  select id, user_id, role into v_other, v_oth_uid, v_role from public.staff
   where active and role <> 'Admin' order by created_at limit 1;

  -- ── a client with something in every corner ────────────────
  insert into public.clients (name, stage, status, assigned_staff_id, agency_id)
  values ('ZZ Request Testperson', 'Job Coaching', 'Active', v_admin, 'ZZ-0001')
  returning id into v_client;

  insert into public.client_private (client_id, dob, address)
  values (v_client, date '1988-04-04', '9 ZZ Lane, Provo');

  insert into public.notes (client_id, staff_id, staff_name, text, type, visible_roles)
  values (v_client, v_admin, 'ZZ Admin', 'Ordinary note everybody can see.', 'Meeting',
          array['Admin','Job Search','Reports','Billing']);

  -- The one that matters for review: written for a narrower audience.
  insert into public.notes (client_id, staff_id, staff_name, text, type, visible_roles)
  values (v_client, v_admin, 'ZZ Admin', 'Mentions a third party.', 'General',
          array['Admin']);

  insert into public.authorizations (client_id, number, service_type, total_hours, rate_type, rate, status)
  values (v_client, 'ZZ-AUTH-1', 'Job Coaching', 20, 'Hourly', 45, 'Open')
  returning id into v_auth;

  -- Draft, not Sent: this authorization requires a USOR 93 and 95 and the
  -- database refuses to let an invoice go out without them. The fixture bends
  -- rather than the rule.
  insert into public.invoices (auth_id, number, date, amount, status)
  values (v_auth, 'ZZ-INV-1', public.practice_today(), 900, 'Draft');

  insert into public.placements (client_id, employer, title, start_date)
  values (v_client, 'ZZ Grocery', 'Clerk', public.practice_today());

  insert into public.sms_messages (client_id, direction, phone, body, kind, status)
  values (v_client, 'Incoming', '+13850000000', 'Reminder about tomorrow', 'Reminder', 'Sent');

  insert into public.attachments (client_id, storage_path, filename, mime_type, category, uploaded_by)
  values (v_client, 'x/y.pdf', 'signed-96.pdf', 'application/pdf', 'Signed USOR form', v_admin);

  -- ── produced by Admin, and logged ──────────────────────────
  select count(*) into v_before from public.access_log;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);

  v_bundle := public.records_request_bundle(v_client, 'Asked for by the client');

  if (select count(*) from public.access_log) <> v_before + 1 then
    failures := failures || 'FAILED: gathering a whole record wrote nothing to the access log'::text;
  else
    raise notice 'ok  gathering a record is logged, like any other read of it';
  end if;

  if (select subject from public.access_log order by id desc limit 1) <> 'Records request' then
    failures := failures || 'FAILED: the log does not say a records request is what happened'::text;
  else
    raise notice 'ok  and the log says what it was, not just that something was read';
  end if;

  -- ── everything is in it ────────────────────────────────────
  if v_bundle->'client'->>'name' is distinct from 'ZZ Request Testperson' then
    failures := failures || 'FAILED: the client themselves is not in the bundle'::text;
  elsif v_bundle->'restricted_details'->>'dob' is null then
    failures := failures || 'FAILED: the date of birth was left out of a request for everything'::text;
  else
    raise notice 'ok  the record and the restricted details are both in it';
  end if;

  for v_tbl, v_count in
    select * from (values
      ('notes', jsonb_array_length(v_bundle->'notes')),
      ('authorizations', jsonb_array_length(v_bundle->'authorizations')),
      ('invoices', jsonb_array_length(v_bundle->'invoices')),
      ('placements', jsonb_array_length(v_bundle->'placements')),
      ('texts', jsonb_array_length(v_bundle->'texts')),
      ('files', jsonb_array_length(v_bundle->'files')),
      ('stage_history', jsonb_array_length(v_bundle->'stage_history'))
    ) as t(name, n)
  loop
    if v_count = 0 then
      failures := failures || format('FAILED: %s was empty in the bundle but has rows', v_tbl);
    end if;
  end loop;
  if failures = '{}' then
    raise notice 'ok  notes, authorizations, invoices, placements, texts, files and stage history are all present';
  end if;

  -- The restricted note is in it. A records request answered with only the
  -- notes that were comfortable to hand over is not answered — the judgement
  -- about what may be disclosed belongs to the person reviewing it, and they
  -- cannot make it about something they were never shown.
  if not (v_bundle->'notes')::text like '%Mentions a third party%' then
    failures := failures || 'FAILED: a note visible only to Admin was quietly left out'::text;
  else
    raise notice 'ok  a note written for one role only is included — and carries who could see it';
  end if;

  if not (v_bundle->'notes')::text like '%visible_roles%' then
    failures := failures || 'FAILED: nothing marks which notes were written for a narrow audience'::text;
  else
    raise notice 'ok  — which is what tells the reviewer where to look twice before disclosing';
  end if;

  -- ── nothing has been added and forgotten ───────────────────
  -- The test that will still be working in a year. Every table holding a
  -- client_id must be in the bundle or on the written list of exclusions.
  -- Every mapped section actually exists in what came back. A key renamed in
  -- the function and not here would otherwise leave the list looking complete.
  for v_tbl in select split_part(x, '=', 2) from unnest(covered) x loop
    if not (v_bundle ? v_tbl) then
      failures := failures || format('FAILED: the bundle has no section called "%s"', v_tbl);
    end if;
  end loop;

  -- And every table holding client data is on one list or the other, so the
  -- next one somebody adds fails here rather than quietly going missing from
  -- the answer to a legal request.
  for v_tbl in
    select c.relname from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'r'
       and (exists (select 1 from pg_attribute a
                     where a.attrelid = c.oid and a.attname = 'client_id' and not a.attisdropped)
            or c.relname in ('clients', 'invoices'))
       and not (c.relname = any (skipped))
     order by c.relname
  loop
    if not exists (select 1 from unnest(covered) x where split_part(x, '=', 1) = v_tbl) then
      v_missing := v_missing || v_tbl;
    end if;
  end loop;

  if array_length(v_missing, 1) > 0 then
    failures := failures || format(
      'FAILED: %s hold(s) client data and are in no section of the bundle: %s. Add them, or add them to the skipped list with a reason.',
      array_length(v_missing, 1), array_to_string(v_missing, ', '));
  else
    raise notice 'ok  every table holding client data is either in the bundle or listed as deliberately out';
  end if;

  -- ── who may produce one ────────────────────────────────────
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_oth_uid, 'role', 'authenticated')::text, true);

  begin
    v_bundle := public.records_request_bundle(v_client, 'curiosity');
    failures := failures || format('FAILED: %s produced a complete client record', v_role);
  exception when insufficient_privilege then
    raise notice 'ok  only Admin gathers a record — it is a disclosure decision, not a report';
  end;

  select count(*) into v_count from public.records_requests;
  if v_count <> 0 then
    failures := failures || format('FAILED: %s can read who has asked for records', v_role);
  else
    raise notice 'ok  and only Admin sees who has asked';
  end if;

  -- ── a request that arrived, arrived ────────────────────────
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);

  insert into public.records_requests (client_id, client_name, requested_by, created_by)
  values (v_client, 'ZZ Request Testperson', 'The client', v_admin);

  delete from public.records_requests where client_id = v_client;
  get diagnostics v_count = row_count;
  if v_count <> 0 then
    failures := failures || 'FAILED: a records request was deleted'::text;
  else
    raise notice 'ok  a request cannot be deleted — "we were asked and did nothing" stays visible';
  end if;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  if failures = '{}' then
    raise notice '';
    raise notice '--- RECORDS REQUEST VERIFIED ---';
  else
    raise notice '';
    raise notice '%  PROBLEM(S):', array_length(failures, 1);
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
