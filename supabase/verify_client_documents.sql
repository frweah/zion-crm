-- Zion Vocational Rehab CRM — a client's documents (0202)
--
-- What has to hold, each tried from the direction that would break it:
--
--   A restricted document leaves a shadow and nothing else. Whoever may open
--   it sees its name, its note and its type; whoever may not sees that a file
--   is there, on a date, and none of those three - and the table underneath
--   still gives them no row at all, so the view is the only thing that
--   softened and the bytes did not.
--
--   This is the reverse of the rule until 15 Oct 2026, when a restricted file
--   was invisible. Both halves are checked, because a redaction that leaked
--   and a redaction that hid everything would both pass a test that only
--   looked at one.
--
--   One client cannot hold the same bytes twice, and two clients can. The
--   fingerprint is per client, not per practice: two people can each have
--   their own copy of the same USOR form.
--
--   A name and a date can be corrected by the uploader or an Admin, and by
--   nobody else. The upload date cannot be corrected by anybody - it is a
--   fact about this system rather than about the document.
--
--   Every one of those is written down, and the log is Admin's because it
--   quotes the filenames the redaction exists to withhold.
--
-- Uses made-up clients (ZZ) and staff (ZZ). Everything is rolled back.

begin;

do $$
declare
  v_admin    uuid;
  v_adm_uid  uuid;
  v_assigned uuid;
  v_asg_uid  uuid := gen_random_uuid();
  v_stranger uuid;
  v_str_uid  uuid := gen_random_uuid();
  v_client   uuid;
  v_other    uuid;
  v_open     uuid;
  v_shut     uuid;
  v_n        integer;
  v_text     text;
  r          record;
  failures   text[] := '{}';
begin
  select id, user_id into v_admin, v_adm_uid from public.staff
   where role = 'Admin' and active and user_id is not null order by created_at, id limit 1;

  insert into public.staff (name, email, role, active)
  values ('ZZ Docs Assigned', 'zz-docs-assigned@example.test', 'Job Coach', true) returning id into v_assigned;
  insert into public.staff (name, email, role, active)
  values ('ZZ Docs Stranger', 'zz-docs-stranger@example.test', 'Job Coach', true) returning id into v_stranger;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_asg_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-docs-assigned@example.test', '{}', '{}', now(), now()),
         (v_str_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-docs-stranger@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_asg_uid where id = v_assigned;
  update public.staff set user_id = v_str_uid where id = v_stranger;

  insert into public.clients (name, stage, status, assigned_staff_id)
  values ('ZZ Docs Client', 'Placement', 'Active', v_assigned) returning id into v_client;
  insert into public.clients (name, stage, status)
  values ('ZZ Docs Other', 'Placement', 'Active') returning id into v_other;

  -- One of each, both uploaded by the assigned staff member.
  insert into public.attachments
    (client_id, storage_path, filename, mime_type, size_bytes, category, restricted,
     note, document_date, sha256, uploaded_by, uploaded_by_name)
  values (v_client, 'clients/zz/open.pdf', 'ZZ work schedule.pdf', 'application/pdf', 100,
          'Work schedule', false, 'ZZ the note', date '2026-03-04',
          repeat('a', 64), v_assigned, 'ZZ Docs Assigned')
  returning id into v_open;
  insert into public.attachments
    (client_id, storage_path, filename, mime_type, size_bytes, category, restricted,
     note, document_date, sha256, uploaded_by, uploaded_by_name)
  values (v_client, 'clients/zz/shut.pdf', 'ZZ guardianship order.pdf', 'application/pdf', 200,
          'Guardianship document', true, 'ZZ the private note', date '2026-05-06',
          repeat('b', 64), v_assigned, 'ZZ Docs Assigned')
  returning id into v_shut;

  -- ── the date on the paper is not the date it arrived ───────
  if (select document_date from public.attachments where id = v_open) <> date '2026-03-04' then
    failures := failures || 'FAILED: the document date was not kept'::text;
  elsif (select created_at::date from public.attachments where id = v_open) = date '2026-03-04' then
    failures := failures || 'FAILED: the upload date was overwritten by the document date'::text;
  else
    raise notice 'ok  a document carries the date on it and the date it arrived, separately';
  end if;

  -- ── the same bytes, twice, for one client ──────────────────
  begin
    insert into public.attachments
      (client_id, storage_path, filename, category, sha256, uploaded_by, uploaded_by_name)
    values (v_client, 'clients/zz/again.pdf', 'ZZ the same scan again.pdf', 'Other',
            repeat('a', 64), v_assigned, 'ZZ Docs Assigned');
    failures := failures || 'FAILED: one client took the same file twice'::text;
  exception when unique_violation then
    raise notice 'ok  one client cannot hold the same bytes twice';
  end;

  -- ── and the same bytes for somebody else ───────────────────
  begin
    insert into public.attachments
      (client_id, storage_path, filename, category, sha256, uploaded_by, uploaded_by_name)
    values (v_other, 'clients/zz/theirs.pdf', 'ZZ their copy.pdf', 'Other',
            repeat('a', 64), v_assigned, 'ZZ Docs Assigned');
    raise notice 'ok  and another client may have their own copy of the same form';
  exception when unique_violation then
    failures := failures || 'FAILED: one client''s file stopped another having the same form'::text;
  end;

  -- ═══ what each person sees ═════════════════════════════════
  perform set_config('role', 'authenticated', true);

  -- The assigned staff member: both, in full.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_asg_uid, 'role', 'authenticated')::text, true);
  select count(*) into v_n from public.client_documents where client_id = v_client;
  if v_n <> 2 then
    failures := failures || format('FAILED: the assigned staff member sees %s of 2 documents', v_n)::text;
  elsif (select filename from public.client_documents where id = v_shut) <> 'ZZ guardianship order.pdf' then
    failures := failures || 'FAILED: the assigned staff member cannot read the restricted name'::text;
  elsif not (select can_open from public.client_documents where id = v_shut) then
    failures := failures || 'FAILED: the assigned staff member is told they cannot open it'::text;
  else
    raise notice 'ok  the staff member a client is assigned to sees both documents in full';
  end if;

  -- A colleague who is not: both rows, one of them a shadow.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_str_uid, 'role', 'authenticated')::text, true);

  select count(*) into v_n from public.client_documents where client_id = v_client;
  if v_n <> 2 then
    failures := failures || format('FAILED: a colleague sees %s rows, not 2 - the shadow is missing', v_n)::text;
  else
    raise notice 'ok  a colleague who is not assigned still sees that two documents are there';
  end if;

  select filename, note, category, storage_path, can_open into r
    from public.client_documents where id = v_shut;
  if coalesce(r.filename, 'x') <> '' or coalesce(r.note, 'x') <> ''
     or coalesce(r.category, 'x') <> '' or coalesce(r.storage_path, 'x') <> '' then
    failures := failures || format('FAILED: the restricted document leaked (name "%s", type "%s")',
      r.filename, r.category)::text;
  elsif r.can_open then
    failures := failures || 'FAILED: a colleague is told they can open a restricted document'::text;
  else
    raise notice 'ok  and of the restricted one they get the date and nothing else';
  end if;

  -- The unrestricted one is not redacted by accident.
  if (select filename from public.client_documents where id = v_open) <> 'ZZ work schedule.pdf' then
    failures := failures || 'FAILED: an ordinary document was redacted too'::text;
  else
    raise notice 'ok  while the ordinary one reads as it always did';
  end if;

  -- And the table underneath still refuses them outright.
  select count(*) into v_n from public.attachments where id = v_shut;
  if v_n <> 0 then
    failures := failures || 'FAILED: the table handed a colleague the restricted row'::text;
  else
    raise notice 'ok  the table itself still gives them no row, so only the view softened';
  end if;

  /**
   * ═══ the types that start restricted (0203) ════════════════
   *
   * An ID, anything medical, a guardianship or legal paper and the client's
   * own financial documents. The default is in the database rather than in
   * the form, so it holds for the agent and the filing rules too - and the
   * only way to check that is to write a row the way they would.
   */
  perform set_config('request.jwt.claims', '', true);
  perform set_config('role', 'postgres', true);

  select string_agg(key, ', ' order by key) into v_text
    from public.client_file_categories where restricted_by_default;
  if v_text is distinct from 'Financial document, Guardianship document, Identity document, Medical or psychological' then
    failures := failures || format('FAILED: the types that start restricted are %s', v_text)::text;
  else
    raise notice 'ok  an ID, anything medical, a legal paper and the client''s own money start restricted';
  end if;

  -- An invoice does not. There are 130 on file and none restricted: they are
  -- what the practice bills USOR, not the client's bank statements.
  if (select restricted_by_default from public.client_file_categories where key = 'Invoice') then
    failures := failures || 'FAILED: an invoice now starts restricted, which hides routine billing'::text;
  else
    raise notice 'ok  and an invoice does not, because it is the practice''s paper and not theirs';
  end if;

  -- ── turning the default off is the thing that is written down ──
  insert into public.attachments
    (client_id, storage_path, filename, category, restricted, sha256, uploaded_by, uploaded_by_name)
  values (v_client, 'clients/zz/id-open.jpg', 'ZZ drivers licence.jpg', 'Identity document',
          false, repeat('c', 64), v_assigned, 'ZZ Docs Assigned');

  if not exists (
    select 1 from public.client_document_events
     where client_id = v_client and action = 'Added'
       and changes -> 'restricted_default_declined' ->> 'category' = 'Identity document') then
    failures := failures || 'FAILED: filing an ID unrestricted was not written down'::text;
  else
    raise notice 'ok  and filing one of them unrestricted is recorded against whoever did it';
  end if;

  -- The same type, left restricted, is not reported as a decision.
  insert into public.attachments
    (client_id, storage_path, filename, category, restricted, sha256, uploaded_by, uploaded_by_name)
  values (v_client, 'clients/zz/id-shut.jpg', 'ZZ passport.jpg', 'Identity document',
          true, repeat('d', 64), v_assigned, 'ZZ Docs Assigned');

  if exists (
    select 1 from public.client_document_events e
     where e.filename = 'ZZ passport.jpg'
       and e.changes ? 'restricted_default_declined') then
    failures := failures || 'FAILED: an ID filed restricted was reported as a declined default'::text;
  else
    raise notice 'ok  while one left restricted is just a document, not a decision';
  end if;

  -- And a type that never defaults to restricted says nothing either way.
  insert into public.attachments
    (client_id, storage_path, filename, category, restricted, sha256, uploaded_by, uploaded_by_name)
  values (v_client, 'clients/zz/invoice.pdf', 'ZZ invoice.pdf', 'Invoice',
          false, repeat('e', 64), v_assigned, 'ZZ Docs Assigned');
  if exists (
    select 1 from public.client_document_events e
     where e.filename = 'ZZ invoice.pdf' and e.changes ? 'restricted_default_declined') then
    failures := failures || 'FAILED: an ordinary document was reported as a declined default'::text;
  else
    raise notice 'ok  and an ordinary one is not reported at all';
  end if;

  -- ── a type that is not on the list is refused ──────────────
  begin
    insert into public.attachments
      (client_id, storage_path, filename, category, uploaded_by, uploaded_by_name)
    values (v_client, 'clients/zz/made-up.pdf', 'ZZ made up.pdf', 'ZZ Not A Type',
            v_assigned, 'ZZ Docs Assigned');
    failures := failures || 'FAILED: a document type nobody has heard of was accepted'::text;
  exception when foreign_key_violation then
    raise notice 'ok  a type that is not on the list is refused by the key, not by a copy of it';
  end;

  perform set_config('role', 'authenticated', true);

  -- ═══ correcting a name and a date ══════════════════════════
  begin
    update public.attachments set filename = 'ZZ renamed by a stranger.pdf' where id = v_open;
    if found then
      failures := failures || 'FAILED: somebody who did not upload it renamed it'::text;
    else
      raise notice 'ok  somebody who neither uploaded it nor is an Admin cannot rename it';
    end if;
  exception when insufficient_privilege then
    raise notice 'ok  somebody who neither uploaded it nor is an Admin cannot rename it';
  end;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_asg_uid, 'role', 'authenticated')::text, true);
  update public.attachments
     set filename = 'ZZ August work schedule.pdf', document_date = date '2026-08-01'
   where id = v_open;
  if (select filename from public.attachments where id = v_open) <> 'ZZ August work schedule.pdf' then
    failures := failures || 'FAILED: the uploader could not correct the name'::text;
  else
    raise notice 'ok  the person who uploaded it can correct the name and the date';
  end if;

  -- ═══ and all of it is written down ═════════════════════════
  perform set_config('request.jwt.claims', '', true);
  perform set_config('role', 'postgres', true);

  -- The two this section put on the file, named rather than counted: the
  -- section above adds three more of its own and a bare count would move
  -- every time somebody adds a case to it.
  select count(*) into v_n from public.client_document_events
   where attachment_id in (v_open, v_shut) and action = 'Added';
  if v_n <> 2 then
    failures := failures || format('FAILED: %s of 2 documents were logged as added', v_n)::text;
  elsif not exists (select 1 from public.client_document_events
                     where attachment_id = v_open and action = 'Edited'
                       and changes -> 'filename' ->> 'to' = 'ZZ August work schedule.pdf') then
    failures := failures || 'FAILED: the rename was not logged from what to what'::text;
  else
    raise notice 'ok  adding one and renaming one are both in the log, with who did it';
  end if;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_asg_uid, 'role', 'authenticated')::text, true);
  delete from public.attachments where id = v_open;
  perform set_config('request.jwt.claims', '', true);
  perform set_config('role', 'postgres', true);

  if not exists (select 1 from public.client_document_events
                  where attachment_id = v_open and action = 'Removed'
                    and filename = 'ZZ August work schedule.pdf') then
    failures := failures || 'FAILED: removing a document was not logged, or lost its name'::text;
  else
    raise notice 'ok  and removing one is logged with the name it had when it went';
  end if;

  -- ── who may read that log ──────────────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_str_uid, 'role', 'authenticated')::text, true);
  select count(*) into v_n from public.client_document_events where client_id = v_client;
  if v_n > 0 then
    failures := failures || format('FAILED: a colleague can read %s log rows naming restricted files', v_n)::text;
  else
    raise notice 'ok  the log is Admin''s - it quotes the names the redaction withholds';
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);
  begin
    update public.client_document_events set filename = 'ZZ rewritten' where client_id = v_client;
    failures := failures || 'FAILED: the document log can be rewritten'::text;
  exception when insufficient_privilege then
    raise notice 'ok  and it is added to, never rewritten';
  end;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('role', 'postgres', true);

  if has_table_privilege('anon', 'public.client_documents', 'select')
     or has_table_privilege('anon', 'public.client_document_events', 'select') then
    failures := failures || 'FAILED: somebody not signed in can read a client''s documents'::text;
  else
    raise notice 'ok  and somebody not signed in can read none of it';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- CLIENT DOCUMENTS VERIFIED ---';
end $$;

rollback;
