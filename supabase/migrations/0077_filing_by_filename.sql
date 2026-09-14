-- ─────────────────────────────────────────────────────────────
-- Filing documents by what their names say
--
-- The client folders are named with care even when the PDFs inside are scans:
-- "19 V0000910 JC" is an authorization, "Job development invoice 19 V0000908"
-- is what was billed against one, "Jan [USOR96]" is January's job development
-- report. lib/filename-rules.ts reads those names alongside the PDF text and
-- decides; the database does the three things that follow, and refuses the
-- ways they could go wrong.
--
--   A narrative document becomes a note of its activity type on the client's
--   Notes tab, dated from the document, with the file attached. One note per
--   document, however many times filing runs. The note says what its date came
--   from, so a date taken from the file's saved time - the fallback - is never
--   mistaken for one read off the page.
--
--   An authorization or an invoice goes on its authorization. Never another
--   client's, never a second authorization for the same file, and a date on
--   file is never overwritten.
--
--   A correction to an authorization on file - its service, whose it is - is
--   Admin's, needs a reason, and is logged with what it was.
--
-- Filing runs unattended for new arrivals, as the agent route's service role,
-- and from the inbox as a person. Both go through the same functions.
-- ─────────────────────────────────────────────────────────────

-- ── notes: where a note came from ─────────────────────────────
alter table public.notes
  add column if not exists source_document uuid references public.inbox_documents(id) on delete set null,
  add column if not exists attachment_id   uuid references public.attachments(id) on delete set null,
  add column if not exists dated_from      text not null default '';

alter table public.notes drop constraint if exists notes_dated_from_check;
alter table public.notes add constraint notes_dated_from_check
  check (dated_from in ('', 'Named in the file', 'Period covered', 'Read from the document', 'File date (fallback)'));

comment on column public.notes.dated_from is
  'For a note made from a document: where its date came from. "File date (fallback)" means neither the name nor the document carried one.';

create unique index if not exists notes_source_document_unique
  on public.notes (source_document) where source_document is not null;

-- ── corrections to an authorization on file ───────────────────
create table if not exists public.authorization_corrections (
  id          bigserial primary key,
  at          timestamptz not null default now(),
  auth_id     uuid not null references public.authorizations(id) on delete cascade,
  auth_number text not null,
  field       text not null check (field in ('Service', 'Client')),
  was_value   text not null,
  new_value   text not null,
  reason      text not null check (btrim(reason) <> ''),
  staff_id    uuid references public.staff(id) on delete set null,
  staff_name  text not null default ''
);

create index if not exists authorization_corrections_auth_idx
  on public.authorization_corrections (auth_id, at);

alter table public.authorization_corrections enable row level security;

drop policy if exists authorization_corrections_read on public.authorization_corrections;
-- Whoever can see authorizations can see how one was corrected.
create policy authorization_corrections_read on public.authorization_corrections
  for select to authenticated using (public.is_active_staff());

-- Written only by correct_authorization. No write policy, and no write grant.
revoke insert, update, delete, truncate on public.authorization_corrections from authenticated, anon;

-- ─────────────────────────────────────────────────────────────
-- Correcting an authorization on file
-- ─────────────────────────────────────────────────────────────
create or replace function public.correct_authorization(
  p_auth         uuid,
  p_reason       text,
  p_service_type text default null,
  p_client       uuid default null
) returns table (field text, was_value text, new_value text)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare
  v_staff uuid := public.current_staff_id();
  v_name  text;
  v_auth  public.authorizations%rowtype;
  v_svc   text := nullif(btrim(coalesce(p_service_type, '')), '');
  v_was   text;
  v_now   text;
begin
  if public.current_staff_role() is distinct from 'Admin' then
    raise exception 'Only Admin corrects an authorization on file.' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'Say why it is being corrected.' using errcode = 'check_violation';
  end if;
  if v_svc is null and p_client is null then
    raise exception 'Nothing to correct.' using errcode = 'invalid_parameter_value';
  end if;

  select * into v_auth from public.authorizations where id = p_auth for update;
  if not found then
    raise exception 'That authorization does not exist.' using errcode = 'no_data_found';
  end if;

  select name into v_name from public.staff where id = v_staff;

  if v_svc is not null and v_svc <> v_auth.service_type then
    if v_svc not in ('Job Coaching', 'Job Development', 'Job Development + HQ Indicator', 'Job Placement',
                     'Job Placement (SE)', 'WSA Tier 1', 'WSA Tier 2', 'HQ Indicator',
                     'Temporary Work Experience', 'Life Skills', 'CRP Group Training', 'Job Readiness',
                     'Supported Employment', 'Follow-Along', 'Other') then
      raise exception '"%" is not a service on the list.', v_svc using errcode = 'check_violation';
    end if;

    update public.authorizations set service_type = v_svc where id = p_auth;

    insert into public.authorization_corrections
      (auth_id, auth_number, field, was_value, new_value, reason, staff_id, staff_name)
    values (p_auth, v_auth.number, 'Service', v_auth.service_type, v_svc, btrim(p_reason), v_staff, coalesce(v_name, ''));

    field := 'Service'; was_value := v_auth.service_type; new_value := v_svc;
    return next;
  end if;

  if p_client is not null and p_client <> v_auth.client_id then
    select name into v_now from public.clients where id = p_client;
    if not found then
      raise exception 'That client does not exist.' using errcode = 'no_data_found';
    end if;
    select name into v_was from public.clients where id = v_auth.client_id;

    -- The authorization's own paperwork goes with it. Its hours and invoices
    -- hang off the authorization and follow without being touched.
    update public.authorizations set client_id = p_client where id = p_auth;
    update public.attachments    set client_id = p_client where auth_id = p_auth;
    update public.forms          set client_id = p_client where auth_id = p_auth;

    insert into public.authorization_corrections
      (auth_id, auth_number, field, was_value, new_value, reason, staff_id, staff_name)
    values (p_auth, v_auth.number, 'Client', coalesce(v_was, ''), v_now, btrim(p_reason), v_staff, coalesce(v_name, ''));

    field := 'Client'; was_value := coalesce(v_was, ''); new_value := v_now;
    return next;
  end if;
end;
$$;

revoke execute on function public.correct_authorization(uuid, text, text, uuid) from public;
revoke execute on function public.correct_authorization(uuid, text, text, uuid) from anon;
grant execute on function public.correct_authorization(uuid, text, text, uuid) to authenticated;

comment on function public.correct_authorization(uuid, text, text, uuid) is
  'Corrects an authorization''s service or client, with a reason, logged in authorization_corrections. Moving it moves its attachments and forms. Admin only.';

-- ─────────────────────────────────────────────────────────────
-- Who may file: the agent route (service role), or staff who review the inbox
-- ─────────────────────────────────────────────────────────────
create or replace function public.filing_caller_role()
returns text language sql stable security definer set search_path = public as $$
  select case
    when coalesce(auth.role(), '') = 'service_role' then 'service_role'
    else public.current_staff_role()
  end;
$$;

revoke execute on function public.filing_caller_role() from public;
revoke execute on function public.filing_caller_role() from anon;
grant execute on function public.filing_caller_role() to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────
-- A document as a note
-- ─────────────────────────────────────────────────────────────
create or replace function public.file_document_as_note(
  p_doc        uuid,
  p_type       text,
  p_at         date,
  p_dated_from text,
  p_text       text,
  p_category   text    default 'Other',
  p_restricted boolean default false,
  p_outcome    text    default null
) returns table (note_id uuid, attachment_id uuid, created boolean)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare
  v_role  text := public.filing_caller_role();
  v_staff uuid := public.current_staff_id();
  v_name  text;
  v_doc   public.inbox_documents%rowtype;
  v_att   public.attachments%rowtype;
  v_note  uuid;
  v_new   boolean := false;
begin
  if v_role is null or v_role not in ('service_role', 'Admin', 'Billing', 'Job Search', 'Reports') then
    raise exception 'Your role does not file documents.' using errcode = 'insufficient_privilege';
  end if;

  if p_type is null or p_type not in ('General', 'Phone call', 'Meeting', 'Job search', 'Application submitted',
                                      'Interview', 'Employer contact', 'Coaching session', 'Counselor contact',
                                      'No-show / not responding') then
    raise exception '"%" is not an activity type.', p_type using errcode = 'check_violation';
  end if;
  if p_at is null then
    raise exception 'A note made from a document needs the document''s date.' using errcode = 'check_violation';
  end if;
  if p_at > public.practice_today() then
    raise exception 'A document cannot be dated after today (%).', p_at using errcode = 'check_violation';
  end if;
  if coalesce(p_dated_from, '') not in ('Named in the file', 'Period covered', 'Read from the document', 'File date (fallback)') then
    raise exception 'Say where the date came from.' using errcode = 'check_violation';
  end if;
  if coalesce(btrim(p_text), '') = '' then
    raise exception 'A note needs its text.' using errcode = 'check_violation';
  end if;
  if coalesce(p_category, '') not in ('Signed USOR form', 'Work schedule', 'Authorization', 'Signed intake',
                                      'Employer verification', 'Invoice', 'Other') then
    raise exception '"%" is not a file category.', p_category using errcode = 'check_violation';
  end if;

  select * into v_doc from public.inbox_documents where id = p_doc;
  if not found then
    raise exception 'That document is not in the inbox.' using errcode = 'no_data_found';
  end if;
  if v_doc.client_id is null then
    raise exception 'Say whose folder that document came from first.' using errcode = 'check_violation';
  end if;
  if v_doc.storage_path is null then
    raise exception 'That document has no stored file.' using errcode = 'check_violation';
  end if;

  select name into v_name from public.staff where id = v_staff;

  -- The file: the one already on the record for this document, or a new row.
  -- A sensitive document makes its file restricted; nothing here loosens one.
  select * into v_att from public.attachments
   where storage_path = v_doc.storage_path and client_id = v_doc.client_id
   order by created_at limit 1;

  if not found then
    insert into public.attachments
      (client_id, storage_path, filename, mime_type, size_bytes, category, restricted, note,
       uploaded_by, uploaded_by_name)
    values
      (v_doc.client_id, v_doc.storage_path, v_doc.filename, 'application/pdf', v_doc.size_bytes,
       p_category, coalesce(p_restricted, false), 'From the documents folder',
       v_staff, coalesce(v_name, 'Documents folder'))
    returning * into v_att;
  elsif coalesce(p_restricted, false) and not v_att.restricted then
    update public.attachments set restricted = true where id = v_att.id returning * into v_att;
  end if;

  -- The note: one per document.
  select n.id into v_note from public.notes n where n.source_document = p_doc;

  if v_note is null then
    insert into public.notes
      (client_id, staff_id, staff_name, text, type, at, ts, visible_roles,
       source_document, attachment_id, dated_from)
    values
      (v_doc.client_id, v_staff, coalesce(v_name, 'Documents folder'), p_text, p_type, p_at,
       -- Midday where the practice is, on the document's date: the Notes tab
       -- shows this time, and the time the filing ran is not when it happened.
       (p_at + time '12:00') at time zone 'America/Denver',
       case when coalesce(p_restricted, false) then array['Admin', 'Reports']
            else array['Admin', 'Job Search', 'Reports', 'Billing'] end,
       p_doc, v_att.id, p_dated_from)
    returning id into v_note;
    v_new := true;
  end if;

  -- A document still waiting is dealt with. A decision already made keeps its words.
  update public.inbox_documents
     set state = 'Filed', decided_by = v_staff, decided_at = now(),
         outcome = coalesce(nullif(btrim(p_outcome), ''), format('Filed as a note (%s)', p_type))
   where id = p_doc and state = 'Pending';

  note_id := v_note; attachment_id := v_att.id; created := v_new;
  return next;
end;
$$;

revoke execute on function public.file_document_as_note(uuid, text, date, text, text, text, boolean, text) from public;
revoke execute on function public.file_document_as_note(uuid, text, date, text, text, text, boolean, text) from anon;
grant execute on function public.file_document_as_note(uuid, text, date, text, text, text, boolean, text) to authenticated, service_role;

comment on function public.file_document_as_note(uuid, text, date, text, text, text, boolean, text) is
  'Files an inbox document as a note of its activity type, dated from the document, with the file attached. One note per document. Service role or inbox reviewers.';

-- ─────────────────────────────────────────────────────────────
-- A document on its authorization: the authorization itself, or an invoice
-- ─────────────────────────────────────────────────────────────
create or replace function public.link_document_to_authorization(
  p_doc      uuid,
  p_auth     uuid,
  p_category text,
  p_start    date default null,
  p_end      date default null,
  p_outcome  text default null
) returns table (attachment_id uuid, start_filled boolean, end_filled boolean, conflicts text)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare
  v_role  text := public.filing_caller_role();
  v_staff uuid := public.current_staff_id();
  v_name  text;
  v_doc   public.inbox_documents%rowtype;
  v_att   public.attachments%rowtype;
  v_auth  public.authorizations%rowtype;
  v_sfill boolean := false;
  v_efill boolean := false;
  v_conf  text[] := '{}';
begin
  if v_role is null or v_role not in ('service_role', 'Admin', 'Billing') then
    raise exception 'Only Admin and Billing put a document on an authorization.' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(p_category, '') not in ('Authorization', 'Invoice') then
    raise exception 'A document on an authorization is the authorization or an invoice.' using errcode = 'check_violation';
  end if;

  select * into v_doc from public.inbox_documents where id = p_doc;
  if not found then
    raise exception 'That document is not in the inbox.' using errcode = 'no_data_found';
  end if;
  if v_doc.client_id is null then
    raise exception 'Say whose folder that document came from first.' using errcode = 'check_violation';
  end if;
  if v_doc.storage_path is null then
    raise exception 'That document has no stored file.' using errcode = 'check_violation';
  end if;

  select * into v_auth from public.authorizations where id = p_auth;
  if not found then
    raise exception 'That authorization does not exist.' using errcode = 'no_data_found';
  end if;
  if v_auth.client_id <> v_doc.client_id then
    raise exception 'Authorization % is on file for a different client. Nothing was changed.', v_auth.number
      using errcode = 'check_violation';
  end if;

  select name into v_name from public.staff where id = v_staff;

  select * into v_att from public.attachments
   where storage_path = v_doc.storage_path and client_id = v_doc.client_id
   order by created_at limit 1;

  if not found then
    insert into public.attachments
      (client_id, storage_path, filename, mime_type, size_bytes, category, note, uploaded_by, uploaded_by_name)
    values
      (v_doc.client_id, v_doc.storage_path, v_doc.filename, 'application/pdf', v_doc.size_bytes,
       p_category, 'From the documents folder', v_staff, coalesce(v_name, 'Documents folder'))
    returning * into v_att;
  end if;

  if v_att.auth_id is not null and v_att.auth_id <> p_auth then
    raise exception 'That file is already on another authorization. Nothing was changed.'
      using errcode = 'check_violation';
  end if;

  update public.attachments set auth_id = p_auth where id = v_att.id;

  -- An authorization's own dates: fill a blank, never overwrite. An invoice
  -- says nothing about them.
  if p_category = 'Authorization' then
    if p_start is not null then
      if v_auth.start_date is null then
        update public.authorizations set start_date = p_start where id = p_auth;
        v_sfill := true;
      elsif v_auth.start_date <> p_start then
        v_conf := v_conf || format('start date on file is %s, the PDF says %s', v_auth.start_date, p_start);
      end if;
    end if;
    if p_end is not null then
      if v_auth.end_date is null then
        update public.authorizations set end_date = p_end where id = p_auth;
        v_efill := true;
      elsif v_auth.end_date <> p_end then
        v_conf := v_conf || format('end date on file is %s, the PDF says %s', v_auth.end_date, p_end);
      end if;
    end if;
  end if;

  update public.inbox_documents
     set state = 'Filed', decided_by = v_staff, decided_at = now(),
         outcome = coalesce(nullif(btrim(p_outcome), ''),
                            case when p_category = 'Invoice'
                                 then format('Invoice for authorization %s', v_auth.number)
                                 else format('Linked to authorization %s', v_auth.number) end)
   where id = p_doc and state = 'Pending';

  attachment_id := v_att.id; start_filled := v_sfill; end_filled := v_efill;
  conflicts := nullif(array_to_string(v_conf, '; '), '');
  return next;
end;
$$;

revoke execute on function public.link_document_to_authorization(uuid, uuid, text, date, date, text) from public;
revoke execute on function public.link_document_to_authorization(uuid, uuid, text, date, date, text) from anon;
grant execute on function public.link_document_to_authorization(uuid, uuid, text, date, date, text) to authenticated, service_role;

comment on function public.link_document_to_authorization(uuid, uuid, text, date, date, text) is
  'Puts an inbox document on its authorization as the authorization''s PDF or an invoice against it. Same client only, one authorization per file, blank dates filled and never overwritten. Service role, Admin and Billing.';
