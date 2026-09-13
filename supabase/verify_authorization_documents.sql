-- Zion Vocational Rehab CRM — an authorization's PDF, on the authorization
--
-- What has to hold, each tried from the direction that would break it:
--
--   A PDF linked to an authorization fills the dates that are blank, and only
--   those. A date already on file is never replaced by one read off a PDF.
--
--   Confirming a document by its number never makes a second authorization,
--   however the number is written. The database refuses a duplicate even
--   when asked directly.
--
--   One client's PDF never lands on another client's authorization.
--
--   Only Admin and Billing do any of it, and a decision already made about a
--   document keeps its wording.
--
-- Runs inside a transaction that is rolled back. Nothing here is left behind.

begin;

do $$
declare
  v_admin   uuid;
  v_adm_uid uuid;
  v_js      uuid;
  v_js_uid  uuid;
  v_a       uuid;
  v_b       uuid;
  v_authA   uuid;
  v_authB   uuid;
  v_authC   uuid;
  v_att1    uuid;
  v_att2    uuid;
  v_att3    uuid;
  v_att4    uuid;
  v_att5    uuid;
  v_att6    uuid;
  v_attB    uuid;
  v_doc     uuid;
  v_doc2    uuid;
  v_count   int;
  r         record;
  failures  text[] := '{}';
begin
  select id, user_id into v_admin, v_adm_uid from public.staff
   where role = 'Admin' and active order by created_at limit 1;
  select id, user_id into v_js, v_js_uid from public.staff
   where active and role not in ('Admin', 'Billing') order by created_at limit 1;

  -- Two clients, an authorization each, with numbers no real authorization
  -- has: every real one is a letter and six or seven digits.
  insert into public.clients (name, stage, status, assigned_staff_id)
  values ('ZZ AuthDoc One', 'Job Coaching', 'Active', v_admin) returning id into v_a;
  insert into public.clients (name, stage, status, assigned_staff_id)
  values ('ZZ AuthDoc Two', 'Job Coaching', 'Active', v_admin) returning id into v_b;

  insert into public.authorizations (client_id, number, service_type, rate_type, rate, total_hours, status)
  values (v_a, 'ZQ9900001', 'Job Coaching', 'Hourly', 45, 20, 'Open') returning id into v_authA;
  insert into public.authorizations (client_id, number, service_type, rate_type, rate, total_hours, status)
  values (v_b, 'ZQ9900002', 'Job Coaching', 'Hourly', 45, 20, 'Open') returning id into v_authB;

  insert into public.attachments (client_id, storage_path, filename, mime_type, category, uploaded_by)
  values (v_a, 'zz/one.pdf', 'one.pdf', 'application/pdf', 'Other', v_admin) returning id into v_att1;
  insert into public.attachments (client_id, storage_path, filename, mime_type, category, uploaded_by)
  values (v_a, 'zz/two.pdf', 'two.pdf', 'application/pdf', 'Invoice', v_admin) returning id into v_att2;
  insert into public.attachments (client_id, storage_path, filename, mime_type, category, uploaded_by)
  values (v_a, 'zz/three.pdf', 'three.pdf', 'application/pdf', 'Authorization', v_admin) returning id into v_att3;
  insert into public.attachments (client_id, storage_path, filename, mime_type, category, uploaded_by)
  values (v_a, 'zz/five.pdf', 'five.pdf', 'application/pdf', 'Authorization', v_admin) returning id into v_att4;
  insert into public.attachments (client_id, storage_path, filename, mime_type, category, uploaded_by)
  values (v_a, 'zz/seven.pdf', 'seven.pdf', 'application/pdf', 'Authorization', v_admin) returning id into v_att5;
  insert into public.attachments (client_id, storage_path, filename, mime_type, category, uploaded_by)
  values (v_b, 'zz/b.pdf', 'b.pdf', 'application/pdf', 'Authorization', v_admin) returning id into v_attB;

  -- An inbox document still waiting, with no attachment yet.
  insert into public.inbox_documents (sha256, folder_name, relative_path, filename, client_id, kind, state, storage_path)
  values ('zz' || repeat('1', 62), 'ZZ AuthDoc One', 'ZZ AuthDoc One/four.pdf', 'four.pdf', v_a,
          'Authorization', 'Pending', 'inbox/zz/four.pdf')
  returning id into v_doc;

  -- And one somebody already filed, as an Invoice, with its attachment.
  insert into public.inbox_documents (sha256, folder_name, relative_path, filename, client_id, kind, state,
                                      storage_path, decided_by, decided_at, outcome)
  values ('zz' || repeat('2', 62), 'ZZ AuthDoc One', 'ZZ AuthDoc One/six.pdf', 'six.pdf', v_a,
          'Unreadable', 'Filed', 'inbox/zz/six.pdf', v_admin, now(), 'Filed as Invoice')
  returning id into v_doc2;
  insert into public.attachments (client_id, storage_path, filename, mime_type, category, uploaded_by)
  values (v_a, 'inbox/zz/six.pdf', 'six.pdf', 'application/pdf', 'Invoice', v_admin) returning id into v_att6;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);

  -- ── linking fills the blanks ───────────────────────────────
  select * into r from public.confirm_authorization_document(
    p_attachment => v_att1, p_auth => v_authA,
    p_start => date '2025-01-02', p_end => date '2025-06-30');

  if r.authorization_id is distinct from v_authA or r.created or not r.start_filled or not r.end_filled then
    failures := failures || 'FAILED: linking a PDF did not report filling the blank dates'::text;
  elsif (select start_date from public.authorizations where id = v_authA) is distinct from date '2025-01-02'
     or (select end_date from public.authorizations where id = v_authA) is distinct from date '2025-06-30' then
    failures := failures || 'FAILED: linking a PDF did not fill the blank dates on the authorization'::text;
  elsif (select auth_id from public.attachments where id = v_att1) is distinct from v_authA then
    failures := failures || 'FAILED: the PDF was not attached to the authorization'::text;
  else
    raise notice 'ok  a PDF attached to an authorization fills its blank start and end dates';
  end if;

  if (select category from public.attachments where id = v_att1) is distinct from 'Other' then
    failures := failures || 'FAILED: linking changed what the file had been filed as'::text;
  else
    raise notice 'ok  and leaves what the file was filed as exactly as it was';
  end if;

  -- ── a date on file is never replaced ───────────────────────
  select * into r from public.confirm_authorization_document(
    p_attachment => v_att2, p_auth => v_authA,
    p_start => date '2025-02-01', p_end => date '2025-06-30');

  if (select start_date from public.authorizations where id = v_authA) is distinct from date '2025-01-02' then
    failures := failures || 'FAILED: a start date on file was overwritten by one read off a PDF'::text;
  elsif r.start_filled or r.end_filled then
    failures := failures || 'FAILED: a date that was already there was reported as filled'::text;
  elsif r.conflicts is null or r.conflicts not like '%2025-01-02%' or r.conflicts not like '%2025-02-01%' then
    failures := failures || format('FAILED: a disagreement about the start date was not reported (%s)', coalesce(r.conflicts, 'nothing'));
  else
    raise notice 'ok  a date already on file is kept, and a different one on the PDF is reported, not applied';
  end if;

  -- ── the number decides, however it is written ──────────────
  select count(*) into v_count from public.authorizations where client_id = v_a;

  select * into r from public.confirm_authorization_document(
    p_doc => v_doc, p_number => 'zq-990 0001',
    p_service_type => 'Job Coaching', p_rate_type => 'Hourly', p_rate => 45, p_total_hours => 20);

  if r.created or r.authorization_id is distinct from v_authA then
    failures := failures || 'FAILED: confirming a document for a number on file did not use that authorization'::text;
  elsif (select count(*) from public.authorizations where client_id = v_a) <> v_count then
    failures := failures || 'FAILED: confirming a document for a number on file created a second authorization'::text;
  else
    raise notice 'ok  "zq-990 0001" is ZQ9900001: the PDF goes on the authorization on file, and nothing new is made';
  end if;

  if not exists (select 1 from public.attachments
                  where storage_path = 'inbox/zz/four.pdf' and client_id = v_a and auth_id = v_authA) then
    failures := failures || 'FAILED: an inbox document confirmed as an authorization did not end up on it'::text;
  elsif (select state from public.inbox_documents where id = v_doc) <> 'Filed'
     or (select outcome from public.inbox_documents where id = v_doc) not like '%ZQ9900001%' then
    failures := failures || 'FAILED: the inbox does not show that document as dealt with, and how'::text;
  else
    raise notice 'ok  an inbox document becomes the authorization''s file and leaves the inbox saying which';
  end if;

  -- ── never onto somebody else ───────────────────────────────
  begin
    select * into r from public.confirm_authorization_document(
      p_attachment => v_att3, p_number => 'ZQ9900002',
      p_service_type => 'Job Coaching', p_rate_type => 'Hourly', p_rate => 45, p_total_hours => 20);
    failures := failures || 'FAILED: a PDF was attached to another client''s authorization by its number'::text;
  exception when check_violation then
    raise notice 'ok  a number on file for a different client is refused, not attached';
  end;

  if (select auth_id from public.attachments where id = v_att3) is not null then
    failures := failures || 'FAILED: the refused attempt still attached the file'::text;
  end if;

  begin
    select * into r from public.confirm_authorization_document(p_attachment => v_attB, p_auth => v_authA);
    failures := failures || 'FAILED: one client''s file was attached to another client''s authorization by id'::text;
  exception when check_violation then
    raise notice 'ok  and so is naming another client''s authorization outright';
  end;

  -- ── a new number makes exactly one ─────────────────────────
  select * into r from public.confirm_authorization_document(
    p_attachment => v_att3, p_number => 'ZQ9900003',
    p_service_type => 'Job Development', p_rate_type => 'Flat Fee', p_rate => 560,
    p_start => date '2025-03-01');
  v_authC := r.authorization_id;

  if not coalesce(r.created, false) or v_authC is null then
    failures := failures || 'FAILED: a number nobody has on file did not create the authorization'::text;
  elsif (select start_date from public.authorizations where id = v_authC) is distinct from date '2025-03-01' then
    failures := failures || 'FAILED: a new authorization did not take the dates it was given'::text;
  else
    raise notice 'ok  a number nobody has on file creates the authorization, with its PDF and dates';
  end if;

  select * into r from public.confirm_authorization_document(
    p_attachment => v_att4, p_number => 'zq 990-0003',
    p_service_type => 'Job Development', p_rate_type => 'Flat Fee', p_rate => 560);

  if r.created or r.authorization_id is distinct from v_authC then
    failures := failures || 'FAILED: a second copy of a new authorization made another authorization'::text;
  elsif (select count(*) from public.authorizations
          where public.normalize_auth_number(number) = 'ZQ9900003') <> 1 then
    failures := failures || 'FAILED: there is more than one authorization numbered ZQ9900003'::text;
  else
    raise notice 'ok  a second PDF of the same authorization joins it rather than making another';
  end if;

  -- ── the database refuses a duplicate on its own ────────────
  begin
    insert into public.authorizations (client_id, number, service_type, rate_type, rate, status)
    values (v_a, 'zq-990-0003', 'Other', 'Flat Fee', 1, 'Open');
    failures := failures || 'FAILED: the database accepted a second authorization with the same number'::text;
  exception when unique_violation then
    raise notice 'ok  asked directly, the database refuses a second authorization with the same number';
  end;

  -- ── one file, one authorization ────────────────────────────
  begin
    select * into r from public.confirm_authorization_document(p_attachment => v_att1, p_auth => v_authC);
    failures := failures || 'FAILED: a file attached to one authorization was moved to another'::text;
  exception when check_violation then
    raise notice 'ok  a file already on one authorization is not quietly moved to another';
  end;

  -- ── a new authorization needs what makes it one ────────────
  begin
    select * into r from public.confirm_authorization_document(
      p_attachment => v_att5, p_number => 'ZQ9900009',
      p_service_type => 'Job Coaching', p_rate_type => 'Hourly', p_rate => null, p_total_hours => 20);
    failures := failures || 'FAILED: an authorization was created with no rate'::text;
  exception when check_violation then
    raise notice 'ok  a new authorization with no rate is refused rather than created half-done';
  end;

  if exists (select 1 from public.authorizations where public.normalize_auth_number(number) = 'ZQ9900009') then
    failures := failures || 'FAILED: the refused authorization exists anyway'::text;
  end if;

  begin
    select * into r from public.confirm_authorization_document(p_auth => v_authA);
    failures := failures || 'FAILED: confirming with no document at all was accepted'::text;
  exception when invalid_parameter_value then
    raise notice 'ok  it has to be told which document';
  end;

  -- ── a decision already made keeps its wording ──────────────
  select * into r from public.confirm_authorization_document(p_attachment => v_att6, p_auth => v_authC);

  if (select auth_id from public.attachments where id = v_att6) is distinct from v_authC then
    failures := failures || 'FAILED: a file filed earlier could not be attached to its authorization'::text;
  elsif (select state from public.inbox_documents where id = v_doc2) <> 'Filed'
     or (select outcome from public.inbox_documents where id = v_doc2) <> 'Filed as Invoice' then
    failures := failures || 'FAILED: linking rewrote what somebody had already decided about the document'::text;
  else
    raise notice 'ok  a file somebody filed earlier can be attached, and their decision keeps its wording';
  end if;

  -- ── who ────────────────────────────────────────────────────
  if v_js is null then
    raise notice 'ok  (no active staff outside Admin and Billing to try the refusal with)';
  else
    perform set_config('request.jwt.claims',
                       json_build_object('sub', v_js_uid, 'role', 'authenticated')::text, true);
    begin
      select * into r from public.confirm_authorization_document(p_attachment => v_att5, p_auth => v_authA);
      failures := failures || 'FAILED: somebody outside Admin and Billing attached a PDF to an authorization'::text;
    exception when insufficient_privilege then
      raise notice 'ok  only Admin and Billing confirm an authorization';
    end;
  end if;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  if failures = '{}' then
    raise notice '';
    raise notice '--- AUTHORIZATION DOCUMENTS VERIFIED ---';
  else
    raise notice '';
    raise notice '%  PROBLEM(S):', array_length(failures, 1);
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
