-- Zion Vocational Rehab CRM — filing documents by what their names say
--
-- What has to hold, each tried from the direction that would break it:
--
--   A document filed as a note makes exactly one note, however often filing
--   runs, dated as it was told and saying where that date came from, with the
--   file attached. A sensitive one is restricted - the note and the file - and
--   a role outside the restricted tier cannot read it.
--
--   A document goes on an authorization only for the same client, only one
--   authorization per file, and an authorization's dates are filled when blank
--   and never overwritten. An invoice changes no dates.
--
--   A decision somebody already made keeps its words.
--
--   Correcting an authorization is Admin's, needs a reason, is logged with what
--   it was, and moving it moves its paperwork. Nobody writes the log directly.
--
--   The unattended agent (service role) may file; anonymous callers may not.
--
-- Runs inside a transaction that is rolled back. Nothing here is left behind.

begin;

do $$
declare
  v_admin    uuid;
  v_adm_uid  uuid;
  v_js       uuid;
  v_js_uid   uuid;
  v_a        uuid;
  v_b        uuid;
  v_authA    uuid;
  v_authA2   uuid;
  v_authB    uuid;
  v_doc1     uuid;
  v_doc2     uuid;
  v_doc3     uuid;
  v_doc4     uuid;
  v_doc5     uuid;
  v_doc6     uuid;
  v_docB     uuid;
  v_att      uuid;
  v_form     uuid;
  v_authO    uuid;
  v_docO     uuid;
  v_docN     uuid;
  v_count    int;
  r          record;
  failures   text[] := '{}';
begin
  select id, user_id into v_admin, v_adm_uid from public.staff
   where role = 'Admin' and active order by created_at limit 1;
  select id, user_id into v_js, v_js_uid from public.staff
   where active and role = 'Job Search' order by created_at limit 1;

  insert into public.clients (name, stage, status, assigned_staff_id)
  values ('ZZ Filing One', 'Job Coaching', 'Active', v_admin) returning id into v_a;
  insert into public.clients (name, stage, status, assigned_staff_id)
  values ('ZZ Filing Two', 'Job Coaching', 'Active', v_admin) returning id into v_b;

  insert into public.authorizations (client_id, number, service_type, rate_type, rate, total_hours, status)
  values (v_a, 'ZQ9800001', 'Job Coaching', 'Hourly', 45, 20, 'Open') returning id into v_authA;
  insert into public.authorizations (client_id, number, service_type, rate_type, rate, status, start_date)
  values (v_a, 'ZQ9800002', 'Job Development', 'Flat Fee', 560, 'Open', date '2025-01-01') returning id into v_authA2;
  insert into public.authorizations (client_id, number, service_type, rate_type, rate, total_hours, status)
  values (v_b, 'ZQ9800003', 'Job Coaching', 'Hourly', 45, 20, 'Open') returning id into v_authB;

  insert into public.inbox_documents (sha256, folder_name, relative_path, filename, client_id, kind, state, storage_path, size_bytes)
  values ('zy' || repeat('1', 62), 'ZZ Filing One', 'ZZ Filing One/a.pdf', 'Feb job coach.pdf', v_a, 'USOR form', 'Pending', 'inbox/zy/1.pdf', 10)
  returning id into v_doc1;
  insert into public.inbox_documents (sha256, folder_name, relative_path, filename, client_id, kind, state, storage_path, size_bytes)
  values ('zy' || repeat('2', 62), 'ZZ Filing One', 'ZZ Filing One/b.pdf', 'WSA complete.pdf', v_a, 'Unreadable', 'Pending', 'inbox/zy/2.pdf', 10)
  returning id into v_doc2;
  -- Filed by a person earlier, as Other, with its attachment.
  insert into public.inbox_documents (sha256, folder_name, relative_path, filename, client_id, kind, state, storage_path,
                                      decided_by, decided_at, outcome)
  values ('zy' || repeat('3', 62), 'ZZ Filing One', 'ZZ Filing One/c.pdf', 'progress report.pdf', v_a, 'Other', 'Filed',
          'inbox/zy/3.pdf', v_admin, now(), 'Filed as Other')
  returning id into v_doc3;
  insert into public.attachments (client_id, storage_path, filename, mime_type, category, uploaded_by)
  values (v_a, 'inbox/zy/3.pdf', 'progress report.pdf', 'application/pdf', 'Other', v_admin);
  insert into public.inbox_documents (sha256, folder_name, relative_path, filename, client_id, kind, state, storage_path)
  values ('zy' || repeat('4', 62), 'ZZ Filing One', 'ZZ Filing One/d.pdf', 'job coach invoice.pdf', v_a, 'Unreadable', 'Pending', 'inbox/zy/4.pdf')
  returning id into v_doc4;
  insert into public.inbox_documents (sha256, folder_name, relative_path, filename, client_id, kind, state, storage_path)
  values ('zy' || repeat('5', 62), 'ZZ Filing One', 'ZZ Filing One/e.pdf', '19 ZQ9800002 JD.pdf', v_a, 'Authorization', 'Pending', 'inbox/zy/5.pdf')
  returning id into v_doc5;
  insert into public.inbox_documents (sha256, folder_name, relative_path, filename, client_id, kind, state, storage_path)
  values ('zy' || repeat('6', 62), 'ZZ Filing One', 'ZZ Filing One/f.pdf', 'no client.pdf', null, 'Other', 'Pending', 'inbox/zy/6.pdf')
  returning id into v_doc6;
  insert into public.inbox_documents (sha256, folder_name, relative_path, filename, client_id, kind, state, storage_path)
  values ('zy' || repeat('7', 62), 'ZZ Filing Two', 'ZZ Filing Two/g.pdf', 'invoice.pdf', v_b, 'Unreadable', 'Pending', 'inbox/zy/7.pdf')
  returning id into v_docB;

  -- ── nobody anonymous ───────────────────────────────────────
  if has_function_privilege('anon', 'public.file_document_as_note(uuid, text, date, text, text, text, boolean, text, boolean)', 'execute')
     or has_function_privilege('anon', 'public.link_document_to_authorization(uuid, uuid, text, date, date, text, boolean)', 'execute')
     or has_function_privilege('anon', 'public.correct_authorization(uuid, text, text, uuid)', 'execute') then
    failures := failures || 'FAILED: an anonymous caller may run a filing or correcting function'::text;
  else
    raise notice 'ok  no filing or correcting function is open to anonymous callers';
  end if;

  if has_table_privilege('authenticated', 'public.authorization_corrections', 'insert')
     or has_table_privilege('authenticated', 'public.authorization_corrections', 'update')
     or has_table_privilege('authenticated', 'public.authorization_corrections', 'delete') then
    failures := failures || 'FAILED: a signed-in person could write the corrections log directly'::text;
  else
    raise notice 'ok  the corrections log cannot be written, changed or deleted directly';
  end if;

  -- ── as the unattended agent ────────────────────────────────
  perform set_config('role', 'service_role', true);
  perform set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);

  select * into r from public.file_document_as_note(
    v_doc1, 'Coaching session', date '2025-02-28', 'Period covered', 'Monthly job coaching report', 'Signed USOR form', false, null);

  if not r.created or r.note_id is null or r.attachment_id is null then
    failures := failures || 'FAILED: filing a document as a note did not make the note and its file'::text;
  elsif exists (select 1 from public.notes n where n.id = r.note_id and
                (n.type <> 'Coaching session' or n.at <> date '2025-02-28' or n.dated_from <> 'Period covered'
                 or n.attachment_id <> r.attachment_id or n.source_document <> v_doc1
                 or (n.ts at time zone 'America/Denver')::date <> date '2025-02-28'
                 or not (n.visible_roles @> array['Admin', 'Job Search', 'Reports', 'Billing']))) then
    failures := failures || 'FAILED: the note is not the type, date, date source, file or visibility it was filed with'::text;
  elsif (select category from public.attachments where id = r.attachment_id) <> 'Signed USOR form' then
    failures := failures || 'FAILED: the note''s file was not filed in the category given'::text;
  elsif (select state from public.inbox_documents where id = v_doc1) <> 'Filed' then
    failures := failures || 'FAILED: a document filed as a note is still waiting in the inbox'::text;
  else
    raise notice 'ok  the agent files a document as one note: its type, its date and where that came from, its file, shown on that day';
  end if;

  select * into r from public.file_document_as_note(
    v_doc1, 'Coaching session', date '2025-02-28', 'Period covered', 'Monthly job coaching report', 'Signed USOR form', false, null);
  select count(*) into v_count from public.notes where source_document = v_doc1;
  if r.created or v_count <> 1
     or (select count(*) from public.attachments where storage_path = 'inbox/zy/1.pdf') <> 1 then
    failures := failures || 'FAILED: filing the same document twice made a second note or file'::text;
  else
    raise notice 'ok  filing it again changes nothing: one note, one file';
  end if;

  -- A sensitive document.
  select * into r from public.file_document_as_note(
    v_doc2, 'Meeting', date '2025-03-10', 'File date (fallback)', 'Work strategy assessment', 'Signed USOR form', true, null);
  v_att := r.attachment_id;

  if not (select restricted from public.attachments where id = v_att)
     or (select visible_roles from public.notes where id = r.note_id) <> array['Admin', 'Reports'] then
    failures := failures || 'FAILED: a restricted document''s note or file is not restricted'::text;
  else
    raise notice 'ok  a sensitive document''s file is restricted and its note is for Admin and Reports only';
  end if;

  -- A decision already made.
  select * into r from public.file_document_as_note(
    v_doc3, 'Job search', date '2025-04-01', 'Read from the document', 'Progress report', 'Signed USOR form', false, null);
  if (select outcome from public.inbox_documents where id = v_doc3) <> 'Filed as Other'
     or (select category from public.attachments where storage_path = 'inbox/zy/3.pdf') <> 'Other'
     or (select count(*) from public.attachments where storage_path = 'inbox/zy/3.pdf') <> 1 then
    failures := failures || 'FAILED: filing a note rewrote a decision somebody had already made, or duplicated its file'::text;
  else
    raise notice 'ok  a document somebody filed earlier gains its note, and keeps their decision and its file';
  end if;

  -- What a note will not be filed with.
  begin
    perform public.file_document_as_note(v_doc4, 'Lunch', date '2025-04-01', 'Named in the file', 'x');
    failures := failures || 'FAILED: a note was filed with an activity type that does not exist'::text;
  exception when check_violation then
    raise notice 'ok  an activity type that is not on the list is refused';
  end;
  begin
    perform public.file_document_as_note(v_doc4, 'General', public.practice_today() + 2, 'Named in the file', 'x');
    failures := failures || 'FAILED: a note was dated after today'::text;
  exception when check_violation then
    raise notice 'ok  a document dated after today is refused';
  end;
  begin
    perform public.file_document_as_note(v_doc4, 'General', date '2025-04-01', '', 'x');
    failures := failures || 'FAILED: a note was filed without saying where its date came from'::text;
  exception when check_violation then
    raise notice 'ok  a note has to say where its date came from';
  end;
  begin
    perform public.file_document_as_note(v_doc6, 'General', date '2025-04-01', 'Named in the file', 'x');
    failures := failures || 'FAILED: a document from a folder nobody has matched was filed against a client'::text;
  exception when check_violation then
    raise notice 'ok  a document whose folder is nobody''s is not filed';
  end;

  -- ── onto an authorization ──────────────────────────────────
  select * into r from public.link_document_to_authorization(v_doc4, v_authA, 'Invoice', date '2024-01-01', date '2024-12-31', null);
  if (select auth_id from public.attachments where id = r.attachment_id) is distinct from v_authA
     or (select category from public.attachments where id = r.attachment_id) <> 'Invoice' then
    failures := failures || 'FAILED: an invoice did not go on its authorization as an invoice'::text;
  elsif (select start_date from public.authorizations where id = v_authA) is not null or r.start_filled then
    failures := failures || 'FAILED: an invoice changed its authorization''s dates'::text;
  elsif (select outcome from public.inbox_documents where id = v_doc4) not like 'Invoice for authorization ZQ9800001%' then
    failures := failures || 'FAILED: the inbox does not say the invoice went on its authorization'::text;
  else
    raise notice 'ok  an invoice goes on its authorization as billed, and touches none of its dates';
  end if;

  select * into r from public.link_document_to_authorization(v_doc5, v_authA2, 'Authorization', date '2025-02-01', date '2025-12-31', null);
  if (select start_date from public.authorizations where id = v_authA2) <> date '2025-01-01' then
    failures := failures || 'FAILED: a start date on file was overwritten'::text;
  elsif (select end_date from public.authorizations where id = v_authA2) <> date '2025-12-31' or not r.end_filled then
    failures := failures || 'FAILED: a blank end date was not filled from the authorization''s PDF'::text;
  elsif r.conflicts is null or r.conflicts not like '%2025-01-01%2025-02-01%' then
    failures := failures || format('FAILED: a disagreement over the start date was not reported (%s)', coalesce(r.conflicts, 'nothing'));
  else
    raise notice 'ok  an authorization''s PDF fills a blank date, keeps one on file, and reports the difference';
  end if;

  begin
    perform public.link_document_to_authorization(v_docB, v_authA, 'Invoice');
    failures := failures || 'FAILED: one client''s invoice went on another client''s authorization'::text;
  exception when check_violation then
    raise notice 'ok  a document never goes on another client''s authorization';
  end;

  begin
    perform public.link_document_to_authorization(v_doc4, v_authA2, 'Invoice');
    failures := failures || 'FAILED: a file on one authorization was moved to another'::text;
  exception when check_violation then
    raise notice 'ok  a file already on one authorization is not moved to another';
  end;

  -- ── read by OCR ────────────────────────────────────────────
  perform set_config('role', 'postgres', true);
  insert into public.authorizations (client_id, number, service_type, rate_type, rate, status)
  values (v_a, 'ZQ9800004', 'Job Placement', 'Flat Fee', 2250, 'Open') returning id into v_authO;
  insert into public.inbox_documents (sha256, folder_name, relative_path, filename, client_id, kind, state, storage_path)
  values ('zy' || repeat('8', 62), 'ZZ Filing One', 'ZZ Filing One/h.pdf', '19 ZQ9800004 JP.pdf', v_a, 'Unreadable', 'Pending', 'inbox/zy/ocr-1.pdf')
  returning id into v_docO;
  insert into public.inbox_documents (sha256, folder_name, relative_path, filename, client_id, kind, state, storage_path)
  values ('zy' || repeat('9', 62), 'ZZ Filing One', 'ZZ Filing One/i.pdf', 'scan notes.pdf', v_a, 'Unreadable', 'Pending', 'inbox/zy/ocr-2.pdf')
  returning id into v_docN;
  perform set_config('role', 'service_role', true);

  perform public.link_document_to_authorization(v_docO, v_authO, 'Authorization', date '2025-05-01', date '2025-10-31', null, true);
  if (select start_date from public.authorizations where id = v_authO) is distinct from date '2025-05-01'
     or not (select dates_from_ocr from public.authorizations where id = v_authO) then
    failures := failures || 'FAILED: dates filled from OCR text were not filled, or not marked as OCR'::text;
  elsif (select dates_from_ocr from public.authorizations where id = v_authA2) then
    failures := failures || 'FAILED: dates read off a text layer were marked as OCR'::text;
  else
    raise notice 'ok  dates filled from OCR text are marked as OCR; dates from a text layer are not';
  end if;

  select * into r from public.file_document_as_note(
    v_docN, 'Meeting', date '2025-05-02', 'Read from the document', 'Read by OCR', 'Other', false, null, true);
  if not (select from_ocr from public.notes where id = r.note_id)
     or (select from_ocr from public.notes where source_document = v_doc1) then
    failures := failures || 'FAILED: a note from OCR text is not marked, or an ordinary note is'::text;
  else
    raise notice 'ok  a note made from OCR text is marked as OCR, and an ordinary one is not';
  end if;

  -- A person changing either date takes the dates as theirs.
  perform set_config('role', 'postgres', true);
  update public.authorizations set end_date = date '2025-11-30' where id = v_authO;
  if (select dates_from_ocr from public.authorizations where id = v_authO) then
    failures := failures || 'FAILED: a date a person changed still says it came from OCR'::text;
  else
    raise notice 'ok  once a person changes a date, the authorization no longer says its dates came from OCR';
  end if;
  perform set_config('role', 'service_role', true);

  -- ── who ────────────────────────────────────────────────────
  if v_js is null then
    raise notice 'ok  (no active Job Search staff to try the refusals with)';
  else
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', v_js_uid, 'role', 'authenticated')::text, true);

    if exists (select 1 from public.notes where source_document = v_doc2) then
      failures := failures || 'FAILED: Job Search can read a restricted document''s note'::text;
    elsif exists (select 1 from public.attachments where id = v_att) then
      failures := failures || 'FAILED: Job Search can read a restricted document''s file'::text;
    elsif not exists (select 1 from public.notes where source_document = v_doc1) then
      failures := failures || 'FAILED: Job Search cannot read an ordinary document''s note'::text;
    else
      raise notice 'ok  Job Search reads the ordinary note and cannot see the restricted note or file';
    end if;

    begin
      perform public.link_document_to_authorization(v_docB, v_authB, 'Invoice');
      failures := failures || 'FAILED: Job Search put a document on an authorization'::text;
    exception when insufficient_privilege then
      raise notice 'ok  only Admin, Billing and the agent put a document on an authorization';
    end;

    begin
      perform public.correct_authorization(v_authB, 'because', 'Job Development');
      failures := failures || 'FAILED: Job Search corrected an authorization'::text;
    exception when insufficient_privilege then
      raise notice 'ok  only Admin corrects an authorization';
    end;
  end if;

  -- ── corrections ────────────────────────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);

  begin
    perform public.correct_authorization(v_authB, '  ', 'Job Development');
    failures := failures || 'FAILED: an authorization was corrected with no reason'::text;
  exception when check_violation then
    raise notice 'ok  a correction needs a reason';
  end;

  begin
    perform public.correct_authorization(v_authB, 'typo', 'Basket weaving');
    failures := failures || 'FAILED: an authorization was given a service that is not on the list'::text;
  exception when check_violation then
    raise notice 'ok  a correction can only name a service on the list';
  end;

  perform public.correct_authorization(v_authB, 'The filename is right: this is job development', 'Job Development');
  if (select service_type from public.authorizations where id = v_authB) <> 'Job Development' then
    failures := failures || 'FAILED: correcting the service did not change it'::text;
  elsif not exists (select 1 from public.authorization_corrections
                     where auth_id = v_authB and field = 'Service' and was_value = 'Job Coaching'
                       and new_value = 'Job Development' and reason like 'The filename is right%'
                       and staff_id = v_admin) then
    failures := failures || 'FAILED: the service correction was not logged with what it was, why, and who'::text;
  else
    raise notice 'ok  a service correction is made and logged with what it was, why, and who';
  end if;

  -- Moving it takes its paperwork.
  perform set_config('role', 'postgres', true);
  insert into public.attachments (client_id, storage_path, filename, mime_type, category, uploaded_by, auth_id)
  values (v_b, 'inbox/zy/8.pdf', 'auth.pdf', 'application/pdf', 'Authorization', v_admin, v_authB);
  insert into public.forms (template_id, client_id, auth_id, status)
  values ((select id from public.form_templates order by sort_order limit 1), v_b, v_authB, 'Draft')
  returning id into v_form;
  perform set_config('role', 'authenticated', true);

  perform public.correct_authorization(v_authB, 'Belongs to the other client', null, v_a);
  if (select client_id from public.authorizations where id = v_authB) <> v_a
     or exists (select 1 from public.attachments where auth_id = v_authB and client_id <> v_a)
     or (select client_id from public.forms where id = v_form) <> v_a then
    failures := failures || 'FAILED: moving an authorization left its files or forms with the other client'::text;
  elsif not exists (select 1 from public.authorization_corrections
                     where auth_id = v_authB and field = 'Client'
                       and was_value = 'ZZ Filing Two' and new_value = 'ZZ Filing One') then
    failures := failures || 'FAILED: moving an authorization was not logged with both clients'::text;
  else
    raise notice 'ok  moving an authorization moves its files and forms, and the log names both clients';
  end if;

  begin
    insert into public.authorization_corrections (auth_id, auth_number, field, was_value, new_value, reason)
    values (v_authA, 'ZQ9800001', 'Service', 'a', 'b', 'forged');
    failures := failures || 'FAILED: Admin wrote a correction straight into the log'::text;
  exception when insufficient_privilege then
    raise notice 'ok  even Admin cannot write the log except by making the correction';
  end;

  if not exists (select 1 from public.authorization_corrections where auth_id = v_authB) then
    failures := failures || 'FAILED: staff cannot read the corrections log'::text;
  end if;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  if failures = '{}' then
    raise notice '';
    raise notice '--- FILING BY FILENAME VERIFIED ---';
  else
    raise notice '';
    raise notice '%  PROBLEM(S):', array_length(failures, 1);
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
