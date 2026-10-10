-- Zion Vocational Rehab CRM — deleting a client (0178)
--
-- A delete is the one operation that cannot be inspected afterwards, so every
-- rule it carries is tried here from the direction that would break it:
--
--   Admin's alone, and through the function alone — DELETE on clients is not
--   granted to anybody, so a direct one is refused even for an Admin.
--
--   A reason is required, and a reason of spaces is not a reason.
--
--   Refused while any authorization is Submitted or Paid, and the message
--   names which ones, because "close those first" is useless without them.
--
--   Refused under a legal hold that has not been lifted, and allowed once it
--   has been. Refused while a records request exists.
--
--   What it takes with it: the client's own records go, the practice's record
--   of what it did stays with the client cleared off it, and the audit row
--   says how many of each went — written before the delete, in a table the
--   delete cannot reach.
--
--   A record merged into this one loses its pointer and keeps its life.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_admin    uuid;
  v_adm_uid  uuid;
  v_bil      uuid;
  v_bil_uid  uuid := gen_random_uuid();
  v_client   uuid;
  v_other    uuid;
  v_auth     uuid;
  v_hold     uuid;
  v_req      uuid;
  v_session  uuid;
  v_audit    uuid;
  v_n        bigint;
  v_text     text;
  v_carried  jsonb;
  v_cleared  boolean;
  v_clearcnt jsonb;
  v_access   bigint;
  v_journal  uuid;
  v_line     uuid;
  v_account  uuid;
  v_entity   uuid;
  failures   text[] := '{}';
begin
  select id, user_id into v_admin, v_adm_uid from public.staff
   where role = 'Admin' and active and user_id is not null
   order by created_at, id limit 1;
  if v_admin is null then
    raise exception 'FAILED: no active Admin with a sign-in to test as';
  end if;

  insert into public.staff (name, email, role, active)
  values ('ZZ Delete Billing', 'zz-delete-billing@example.test', 'Billing', true)
  returning id into v_bil;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data,
                          raw_user_meta_data, created_at, updated_at)
  values (v_bil_uid, '00000000-0000-0000-0000-000000000000', 'authenticated',
          'authenticated', 'zz-delete-billing@example.test', '{}', '{}', now(), now());

  -- ── somebody entered twice ─────────────────────────────────
  insert into public.clients (name, stage, status)
  values ('ZZ Delete Client', 'Placement', 'Active') returning id into v_client;
  insert into public.clients (name, stage, status, merged_into)
  values ('ZZ Delete Duplicate', 'Closed', 'Closed', v_client) returning id into v_other;

  insert into public.notes (client_id, text) values
    (v_client, 'ZZ a note on the wrong person'),
    (v_client, 'ZZ and another');
  insert into public.tasks (title, client_id) values ('ZZ a task on the wrong person', v_client);
  insert into public.authorizations
    (client_id, number, service_type, rate_type, rate, status, start_date, end_date)
  values (v_client, 'ZZ-D-1', 'Job Development', 'Flat Fee', 560, 'Due',
          public.practice_today() - 30, public.practice_today() + 30)
  returning id into v_auth;

  -- Somebody opened the record. Every real client has rows like this, and
  -- they are what made the first version of this refuse every delete.
  insert into public.access_log (subject, client_id, staff_id)
  values ('Client restricted details', v_client, v_admin) returning id into v_access;

  -- The practice's own record of time it spent. This one keeps its row.
  insert into public.work_sessions (staff_id, client_id, worked_on, hours)
  values (v_admin, v_client, public.practice_today() - 1, 1.5)
  returning id into v_session;

  -- ── not everybody's to do ──────────────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_bil_uid, 'role', 'authenticated')::text, true);
  begin
    perform public.delete_client(v_client, 'ZZ tidying up');
    failures := failures || 'FAILED: Billing deleted a client'::text;
  exception when insufficient_privilege then
    raise notice 'ok  only an Admin deletes a client';
  end;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);

  -- ── and not without saying why ─────────────────────────────
  begin
    perform public.delete_client(v_client, '   ');
    failures := failures || 'FAILED: a client was deleted for no stated reason'::text;
  exception when check_violation then
    raise notice 'ok  a reason of spaces is not a reason';
  end;

  -- ── not while the bill is out ──────────────────────────────
  perform set_config('role', 'postgres', true);
  update public.authorizations set status = 'Submitted',
         submitted_on = public.practice_today() - 2, submitted_by = v_admin
   where id = v_auth;
  perform set_config('role', 'authenticated', true);
  begin
    perform public.delete_client(v_client, 'ZZ entered against the wrong person');
    failures := failures || 'FAILED: a client with a Submitted authorization was deleted'::text;
  exception when check_violation then
    get stacked diagnostics v_text = message_text;
    if position('ZZ-D-1' in v_text) = 0 then
      failures := failures ||
        format('FAILED: the refusal does not say which authorization to close: %s', v_text)::text;
    else
      raise notice 'ok  Submitted stops it, and the refusal names the authorization to close';
    end if;
  end;

  perform set_config('role', 'postgres', true);
  update public.authorizations set status = 'Paid', paid_on = public.practice_today() - 1,
         paid_amount = 560 where id = v_auth;
  perform set_config('role', 'authenticated', true);
  begin
    perform public.delete_client(v_client, 'ZZ entered against the wrong person');
    failures := failures || 'FAILED: a client with a Paid authorization was deleted'::text;
  exception when check_violation then
    raise notice 'ok  Paid stops it too — the money has moved';
  end;

  -- Closed is the thing the refusal asks for, so Closed must let it through.
  perform set_config('role', 'postgres', true);
  update public.authorizations set status = 'Closed', closed_reason = 'ZZ wrong person',
         closed_at = now(), closed_by = v_admin, paid_on = null, paid_amount = null
   where id = v_auth;

  -- ── not while the books name them ──────────────────────────
  -- A posting is made rather than asserted, because the refusal has to be the
  -- one a real line sets off. Two things shape how this is written: the books
  -- do not open until the CPA has signed off the chart, so the entry is dated
  -- the first open day rather than today; and the ledger refuses a delete as
  -- firmly as an edit, so the posting cannot be tidied away afterwards - it is
  -- unwound by failing the block it was made in, which is the only way to take
  -- something back out of the ledger.
  begin
    perform set_config('role', 'postgres', true);
    select entity_id, id into v_entity, v_account
      from public.ledger_accounts order by code limit 1;
    insert into public.journals (entity_id, entry_date, source_kind)
    values (v_entity, date '2027-01-02', 'Manual') returning id into v_journal;
    insert into public.journal_lines (journal_id, account_id, client_id, debit, credit)
    values (v_journal, v_account, v_client, 100, 0) returning id into v_line;

    perform set_config('role', 'authenticated', true);
    begin
      perform public.delete_client(v_client, 'ZZ entered against the wrong person');
      failures := failures || 'FAILED: a client the ledger names was deleted'::text;
    exception when check_violation then
      get stacked diagnostics v_text = message_text;
      if position('ledger' in lower(v_text)) = 0 then
        failures := failures || format('FAILED: the ledger refusal reads "%s"', v_text)::text;
      else
        raise notice 'ok  a posting in the books stops it, and the ledger keeps its own rule';
      end if;
    end;
    raise exception 'ZZ unwind the posting';
  exception when raise_exception then
    get stacked diagnostics v_text = message_text;
    if v_text <> 'ZZ unwind the posting' then raise; end if;
  end;
  perform set_config('role', 'postgres', true);
  if exists (select 1 from public.journal_lines where id = v_line) then
    failures := failures || 'FAILED: the test left a posting in the ledger'::text;
  end if;

  -- ── not while the law is looking ───────────────────────────
  insert into public.legal_holds (client_id, reason, placed_by, placed_by_name)
  values (v_client, 'ZZ litigation hold', v_admin, 'ZZ Tester') returning id into v_hold;
  perform set_config('role', 'authenticated', true);
  begin
    perform public.delete_client(v_client, 'ZZ entered against the wrong person');
    failures := failures || 'FAILED: a client under a legal hold was deleted'::text;
  exception when check_violation then
    raise notice 'ok  a legal hold stops it';
  end;

  perform set_config('role', 'postgres', true);
  update public.legal_holds set lifted_at = now(), lifted_by = v_admin,
         lifted_by_name = 'ZZ Tester', lifted_reason = 'ZZ matter closed' where id = v_hold;

  insert into public.records_requests (client_id, requested_by) values (v_client, 'ZZ Counsel')
  returning id into v_req;
  perform set_config('role', 'authenticated', true);
  begin
    perform public.delete_client(v_client, 'ZZ entered against the wrong person');
    failures := failures || 'FAILED: a client with a records request was deleted'::text;
  exception when check_violation then
    raise notice 'ok  a records request stops it';
  end;

  perform set_config('role', 'postgres', true);
  delete from public.records_requests where id = v_req;

  -- ── the function is the only door ──────────────────────────
  if has_table_privilege('authenticated', 'public.clients', 'delete') then
    failures := failures ||
      'FAILED: DELETE on clients is granted, so a delete can happen with no reason attached'::text;
  else
    raise notice 'ok  nothing but the function deletes a client';
  end if;

  -- ── the exception is not an edit ───────────────────────────
  -- The access log and a time record let a pointer go only when the client it
  -- points at no longer exists. While the client is there - which is the only
  -- state anybody working a screen can be in - the guard refuses exactly as it
  -- did before. Run as postgres, so it is the guard answering and not a grant.
  perform set_config('role', 'postgres', true);
  begin
    update public.work_sessions set client_id = null where id = v_session;
    failures := failures ||
      'FAILED: the client can be cleared off a time record by hand'::text;
  exception when check_violation then
    raise notice 'ok  while the client is there a time record still refuses the change';
  end;
  begin
    update public.access_log set client_id = null where id = v_access;
    failures := failures ||
      'FAILED: the client can be cleared off an access log row by hand'::text;
  exception when check_violation then
    raise notice 'ok  and so does the access log';
  end;

  -- ── and now it goes ────────────────────────────────────────
  perform set_config('role', 'authenticated', true);
  v_audit := public.delete_client(v_client, 'ZZ entered against the wrong person');
  perform set_config('role', 'postgres', true);

  if exists (select 1 from public.clients where id = v_client) then
    failures := failures || 'FAILED: the client is still there'::text;
  else
    raise notice 'ok  the client is gone';
  end if;

  select count(*) into v_n from (
    select 1 from public.notes where client_id = v_client
    union all select 1 from public.tasks where client_id = v_client
    union all select 1 from public.authorizations where client_id = v_client
  ) x;
  if v_n > 0 then
    failures := failures || format('FAILED: %s of the client''s own records were left behind', v_n)::text;
  else
    raise notice 'ok  their notes, tasks and authorizations went with them';
  end if;

  select client_id is null into v_cleared from public.work_sessions where id = v_session;
  if v_cleared is null then
    failures := failures || 'FAILED: the practice lost its record of time it worked'::text;
  elsif not v_cleared then
    failures := failures || 'FAILED: a work session still points at a client that is gone'::text;
  else
    raise notice 'ok  the practice keeps what it did, with the client cleared off it';
  end if;

  select client_id is null into v_cleared from public.access_log where id = v_access;
  if v_cleared is null then
    failures := failures || 'FAILED: the access log lost a row, which it is not allowed to do'::text;
  elsif not v_cleared then
    failures := failures || 'FAILED: the access log still points at a client that is gone'::text;
  else
    select format('%s / %s', subject, (staff_id is not null)::text) into v_text
      from public.access_log where id = v_access;
    if v_text <> 'Client restricted details / true' then
      failures := failures || format('FAILED: the access log row was changed as well: %s', v_text)::text;
    else
      raise notice 'ok  the access log still says who looked and at what, with the pointer emptied';
    end if;
  end if;

  if (select merged_into from public.clients where id = v_other) is not null then
    failures := failures || 'FAILED: a merged record still points at a client that is gone'::text;
  elsif not exists (select 1 from public.clients where id = v_other) then
    failures := failures || 'FAILED: deleting one client took a merged record with it'::text;
  else
    raise notice 'ok  the record merged into them kept its life and lost the pointer';
  end if;

  -- ── what it says it did ────────────────────────────────────
  select carried into v_carried from public.client_deletions where id = v_audit;
  select format('%s / %s / %s', client_name, reason, deleted_by_name) into v_text
    from public.client_deletions where id = v_audit;
  if v_text is null then
    failures := failures || 'FAILED: nothing was recorded about the deletion'::text;
  elsif v_text <> format('ZZ Delete Client / ZZ entered against the wrong person / %s',
                         (select name from public.staff where id = v_admin)) then
    failures := failures || format('FAILED: the record of the deletion reads "%s"', v_text)::text;
  else
    raise notice 'ok  who, what and why is on the record: %', v_text;
  end if;

  if (v_carried ->> 'notes')::int is distinct from 2
     or (v_carried ->> 'tasks')::int is distinct from 1
     or (v_carried ->> 'authorizations')::int is distinct from 1 then
    failures := failures ||
      format('FAILED: it counted %s rather than 2 notes, 1 task and 1 authorization', v_carried)::text;
  else
    raise notice 'ok  it counted what went with them: %', v_carried;
  end if;

  select cleared into v_clearcnt from public.client_deletions where id = v_audit;
  if (v_clearcnt ->> 'access_log')::int is distinct from 1
     or (v_clearcnt ->> 'work_sessions')::int is distinct from 1 then
    failures := failures ||
      format('FAILED: it says %s kept their row rather than one access log row and one work session', v_clearcnt)::text;
  else
    raise notice 'ok  and what kept its own record: %', v_clearcnt;
  end if;

  if exists (select 1 from public.client_deletions where client_id = v_client
              and at < (select at from public.client_deletions where id = v_audit)) then
    failures := failures || 'FAILED: more than one record of one deletion'::text;
  end if;

  perform set_config('request.jwt.claims', '', true);

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- CLIENT DELETION VERIFIED ---';
end $$;

rollback;
