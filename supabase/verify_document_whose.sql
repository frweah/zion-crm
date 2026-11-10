-- Zion Vocational Rehab CRM — a document says whose it is (0341)
--
-- What has to hold:
--
--   Saying whose a document is files nothing and confirms nothing. It leaves
--   the document Pending with a client on it, so the doors that file and
--   confirm are still the ones that do those things.
--
--   A client made from a document is Active, at Intake, with the counselor
--   and the office the form named, and the document is on their record.
--
--   The parse's own mistake is refused. The USOR form prints the name and the
--   client number on one line, so the parser's suggestion can be a first name
--   with "Client ID" on the end, and a client called that would be created by
--   anybody who clicked without reading.
--
--   A name already on file is refused: the practice has had two duplicate
--   client records and does not need a third.
--
--   And it is Admin's and Billing's.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_admin uuid; v_admin_uid uuid := gen_random_uuid();
  v_coach uuid; v_coach_uid uuid := gen_random_uuid();
  v_counselor uuid;
  v_existing uuid; v_made uuid;
  v_doc uuid; v_doc2 uuid; v_doc3 uuid; v_doc4 uuid; v_doc5 uuid;
  v_text text; v_state text; v_client uuid;
  r record;
  failures text[] := '{}';
begin
  insert into public.staff (name, email, role, active)
  values ('ZZ Whose Admin', 'zz-whose-admin@example.test', 'Admin', true) returning id into v_admin;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_admin_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-whose-admin@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_admin_uid where id = v_admin;

  insert into public.staff (name, email, role, active)
  values ('ZZ Whose Coach', 'zz-whose-coach@example.test', 'Job Coach', true) returning id into v_coach;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_coach_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-whose-coach@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_coach_uid where id = v_coach;

  insert into public.offices (name) values ('ZZ Office');
  insert into public.counselors (name, agency, office) values ('ZZ Counselor', 'USOR', 'ZZ Office')
  returning id into v_counselor;
  insert into public.clients (name, stage, status, assigned_staff_id, phone)
  values ('ZZ Already Here', 'Job Search', 'Active', v_admin, '+13855550401') returning id into v_existing;

  insert into public.inbox_documents (sha256, folder_name, relative_path, filename, kind, state, parsed)
  values (repeat('c', 64), 'service@ mail', 'a.pdf', 'ZZ auth one.pdf', 'Authorization', 'Pending',
          '{"fields": {"clientName": {"value": "ZZ New Person"}}}'::jsonb)
  returning id into v_doc;
  insert into public.inbox_documents (sha256, folder_name, relative_path, filename, kind, state)
  values (repeat('d', 64), 'service@ mail', 'b.pdf', 'ZZ auth two.pdf', 'Authorization', 'Pending')
  returning id into v_doc2;
  insert into public.inbox_documents (sha256, folder_name, relative_path, filename, kind, state, outcome, decided_by, decided_at)
  values (repeat('e', 64), 'service@ mail', 'c.pdf', 'ZZ filed.pdf', 'USOR form', 'Filed', 'Filed as Other', v_admin, now())
  returning id into v_doc3;
  -- Each refusal gets a document of its own. With a refusal taken out, the
  -- first case creates a client and consumes the document, and every later
  -- case would raise about that rather than reporting its own answer - a
  -- script that stops is a script that has said less than it knew.
  insert into public.inbox_documents (sha256, folder_name, relative_path, filename, kind, state)
  values (repeat('f', 64), 'service@ mail', 'd.pdf', 'ZZ auth three.pdf', 'Authorization', 'Pending')
  returning id into v_doc4;
  insert into public.inbox_documents (sha256, folder_name, relative_path, filename, kind, state)
  values (repeat('1', 64), 'service@ mail', 'e.pdf', 'ZZ auth four.pdf', 'Authorization', 'Pending')
  returning id into v_doc5;

  -- ── a coach does not say whose a document is ───────────────
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_coach_uid, 'role', 'authenticated')::text, true);
  v_text := '';
  begin
    perform public.assign_document_to_client(v_doc, v_existing);
    v_text := 'allowed';
  exception when insufficient_privilege then
    v_text := sqlerrm;
  end;
  if v_text = 'allowed' then
    failures := failures || 'FAILED: a Job Coach said whose a document was'::text;
  else
    raise notice 'ok  saying whose a document is belongs to Admin and Billing';
  end if;

  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_admin_uid, 'role', 'authenticated')::text, true);

  -- ── assigning files nothing ────────────────────────────────
  perform public.assign_document_to_client(v_doc2, v_existing);
  select state, client_id into v_state, v_client from public.inbox_documents where id = v_doc2;
  if v_client is distinct from v_existing then
    failures := failures || 'FAILED: the document did not land on the client'::text;
  elsif v_state <> 'Pending' then
    failures := failures || format('FAILED: assigning a document made it %s', v_state)::text;
  elsif exists (select 1 from public.attachments a where a.client_id = v_existing) then
    failures := failures || 'FAILED: assigning a document filed it as well'::text;
  else
    raise notice 'ok  saying whose it is leaves it waiting to be filed, which is a different decision';
  end if;

  -- ── a document already dealt with ──────────────────────────
  v_text := '';
  begin
    perform public.assign_document_to_client(v_doc3, v_existing);
    v_text := 'allowed';
  exception when check_violation then
    v_text := sqlerrm;
  end;
  if v_text = 'allowed' then
    failures := failures || 'FAILED: a document already filed was reassigned'::text;
  else
    raise notice 'ok  a document already dealt with is left alone';
  end if;

  -- ── the parse's own mistake ────────────────────────────────
  v_text := '';
  begin
    perform public.client_from_document(v_doc4, 'ZZ Firstname Client ID', v_counselor, 'ZZ Office', '89914', '');
    v_text := 'allowed';
  exception when check_violation then
    v_text := sqlerrm;
  end;
  if v_text = 'allowed' then
    failures := failures || 'FAILED: a client was created called "Client ID"'::text;
  elsif v_text not like '%form%' then
    failures := failures || format('FAILED: refused, but not in a sentence: %s', v_text)::text;
  else
    raise notice 'ok  the form''s own wording is refused as a name, in a sentence';
  end if;

  -- ── and a name with nothing in it ──────────────────────────
  v_text := '';
  begin
    perform public.client_from_document(v_doc5, 'ZZ', v_counselor, 'ZZ Office', '', '');
    v_text := 'allowed';
  exception when check_violation then
    v_text := sqlerrm;
  end;
  if v_text = 'allowed' then
    failures := failures || 'FAILED: a client was created from half a name'::text;
  else
    raise notice 'ok  a full name is asked for, as the document has it';
  end if;

  -- ── a name already on file ─────────────────────────────────
  v_text := '';
  begin
    perform public.client_from_document(v_doc5, 'ZZ Already Here', v_counselor, 'ZZ Office', '', '');
    v_text := 'allowed';
  exception when unique_violation then
    v_text := sqlerrm;
  end;
  if v_text = 'allowed' then
    failures := failures || 'FAILED: a second client was created under a name already on file'::text;
  elsif v_text not like '%already a client%' then
    failures := failures || format('FAILED: refused, but not in a sentence: %s', v_text)::text;
  else
    raise notice 'ok  a name already on file is refused — assign the document to them instead';
  end if;

  -- ── and the one that works ─────────────────────────────────
  v_made := public.client_from_document(v_doc, 'ZZ New Person', v_counselor, 'ZZ Office', '89914', '');
  select c.status, c.stage, c.counselor_id, c.referring_office, c.agency_id, c.no_phone_reason
    into r from public.clients c where c.id = v_made;
  select client_id, state into v_client, v_state from public.inbox_documents where id = v_doc;

  if r.status <> 'Active' or r.stage <> 'Intake' then
    failures := failures || format('FAILED: the client was made %s at %s', r.status, r.stage)::text;
  elsif r.counselor_id is distinct from v_counselor then
    failures := failures || 'FAILED: the counselor on the form is not on the client'::text;
  elsif r.referring_office is distinct from 'ZZ Office' then
    failures := failures || 'FAILED: the office on the form is not on the client'::text;
  elsif r.agency_id is distinct from '89914' then
    failures := failures || 'FAILED: the client number on the form is not on the client'::text;
  elsif coalesce(btrim(r.no_phone_reason), '') = '' then
    failures := failures || 'FAILED: a client with no number has no reason for having none'::text;
  elsif v_client is distinct from v_made then
    failures := failures || 'FAILED: the document is not on the client it was made from'::text;
  elsif v_state <> 'Pending' then
    failures := failures || format('FAILED: making a client from a document made it %s', v_state)::text;
  else
    raise notice 'ok  a client from a document is Active at Intake, with the counselor, the office and the number off the form';
  end if;

  -- ── and the document is not reused ─────────────────────────
  v_text := '';
  begin
    perform public.client_from_document(v_doc, 'ZZ Second Person', v_counselor, 'ZZ Office', '', '');
    v_text := 'allowed';
  exception when check_violation then
    v_text := sqlerrm;
  end;
  if v_text = 'allowed' then
    failures := failures || 'FAILED: a second client was made from a document that already belongs to somebody'::text;
  else
    raise notice 'ok  a document that already belongs to somebody makes no second client';
  end if;

  perform set_config('request.jwt.claims', '', true);

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, chr(10));
  end if;
end $$;

rollback;
