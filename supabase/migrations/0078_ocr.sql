-- ─────────────────────────────────────────────────────────────
-- Text read by OCR, and where it was used
--
-- Most of the documents folder is scans: no text layer, nothing pdf.js can
-- read. The agent on the owner's machine now runs Tesseract over those pages
-- before sending them - locally, no service sees a client's document - and
-- sends the recognised text with the file.
--
-- OCR is a reading, not a fact. A 5 read as an S puts the wrong month on an
-- authorization. So everything that came from it says so:
--
--   The document keeps the OCR text apart from anything read off a text
--   layer, with the engine and its confidence.
--
--   A note made from OCR text is marked, and shows it.
--
--   An authorization whose dates were filled from OCR text is marked until a
--   person changes either date, which is them taking the dates as their own.
-- ─────────────────────────────────────────────────────────────

alter table public.inbox_documents
  add column if not exists ocr_text       text,
  add column if not exists ocr_engine     text not null default '',
  add column if not exists ocr_confidence numeric(5,2),
  add column if not exists ocr_pages      integer,
  add column if not exists ocr_at         timestamptz;

comment on column public.inbox_documents.ocr_text is
  'Text recognised by OCR on the agent''s machine, for a PDF with no text layer. Never mixed with text read off a text layer.';
comment on column public.inbox_documents.ocr_confidence is
  'Tesseract''s mean word confidence, 0-100.';

alter table public.notes
  add column if not exists from_ocr boolean not null default false;

comment on column public.notes.from_ocr is
  'The note''s text and date were read by OCR from a scan, and should be checked against the attached file.';

alter table public.authorizations
  add column if not exists dates_from_ocr boolean not null default false;

comment on column public.authorizations.dates_from_ocr is
  'A start or end date was filled from OCR text. Cleared when a person changes either date.';

-- A person setting a date takes it as theirs. Filing a date from a document
-- is not a person setting it: link_document_to_authorization says so for the
-- length of its own updates, or filling the end date straight after the start
-- would clear the mark the start date had just set.
create or replace function public.authorization_dates_reviewed()
returns trigger language plpgsql as $$
begin
  if coalesce(current_setting('zion.filling_dates', true), '') <> '' then
    return new;
  end if;
  if old.dates_from_ocr
     and new.dates_from_ocr = old.dates_from_ocr
     and (new.start_date is distinct from old.start_date or new.end_date is distinct from old.end_date) then
    new.dates_from_ocr := false;
  end if;
  return new;
end;
$$;

drop trigger if exists authorizations_dates_reviewed on public.authorizations;
create trigger authorizations_dates_reviewed
  before update of start_date, end_date on public.authorizations
  for each row execute function public.authorization_dates_reviewed();

-- ─────────────────────────────────────────────────────────────
-- The filing functions from 0077, now told whether the text was OCR
-- ─────────────────────────────────────────────────────────────
drop function if exists public.file_document_as_note(uuid, text, date, text, text, text, boolean, text);

create or replace function public.file_document_as_note(
  p_doc        uuid,
  p_type       text,
  p_at         date,
  p_dated_from text,
  p_text       text,
  p_category   text    default 'Other',
  p_restricted boolean default false,
  p_outcome    text    default null,
  p_ocr        boolean default false
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

  select n.id into v_note from public.notes n where n.source_document = p_doc;

  if v_note is null then
    insert into public.notes
      (client_id, staff_id, staff_name, text, type, at, ts, visible_roles,
       source_document, attachment_id, dated_from, from_ocr)
    values
      (v_doc.client_id, v_staff, coalesce(v_name, 'Documents folder'), p_text, p_type, p_at,
       (p_at + time '12:00') at time zone 'America/Denver',
       case when coalesce(p_restricted, false) then array['Admin', 'Reports']
            else array['Admin', 'Job Search', 'Reports', 'Billing'] end,
       p_doc, v_att.id, p_dated_from, coalesce(p_ocr, false))
    returning id into v_note;
    v_new := true;
  end if;

  update public.inbox_documents
     set state = 'Filed', decided_by = v_staff, decided_at = now(),
         outcome = coalesce(nullif(btrim(p_outcome), ''), format('Filed as a note (%s)', p_type))
   where id = p_doc and state = 'Pending';

  note_id := v_note; attachment_id := v_att.id; created := v_new;
  return next;
end;
$$;

revoke execute on function public.file_document_as_note(uuid, text, date, text, text, text, boolean, text, boolean) from public;
revoke execute on function public.file_document_as_note(uuid, text, date, text, text, text, boolean, text, boolean) from anon;
grant execute on function public.file_document_as_note(uuid, text, date, text, text, text, boolean, text, boolean) to authenticated, service_role;

comment on function public.file_document_as_note(uuid, text, date, text, text, text, boolean, text, boolean) is
  'Files an inbox document as a note of its activity type, dated from the document, with the file attached. One note per document. Marks a note made from OCR text. Service role or inbox reviewers.';

drop function if exists public.link_document_to_authorization(uuid, uuid, text, date, date, text);

create or replace function public.link_document_to_authorization(
  p_doc      uuid,
  p_auth     uuid,
  p_category text,
  p_start    date    default null,
  p_end      date    default null,
  p_outcome  text    default null,
  p_ocr      boolean default false
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

  if p_category = 'Authorization' then
    perform set_config('zion.filling_dates', 'document', true);
    if p_start is not null then
      if v_auth.start_date is null then
        update public.authorizations
           set start_date = p_start, dates_from_ocr = dates_from_ocr or coalesce(p_ocr, false)
         where id = p_auth;
        v_sfill := true;
      elsif v_auth.start_date <> p_start then
        v_conf := v_conf || format('start date on file is %s, the PDF says %s', v_auth.start_date, p_start);
      end if;
    end if;
    if p_end is not null then
      if v_auth.end_date is null then
        update public.authorizations
           set end_date = p_end, dates_from_ocr = dates_from_ocr or coalesce(p_ocr, false)
         where id = p_auth;
        v_efill := true;
      elsif v_auth.end_date <> p_end then
        v_conf := v_conf || format('end date on file is %s, the PDF says %s', v_auth.end_date, p_end);
      end if;
    end if;
    perform set_config('zion.filling_dates', '', true);
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

revoke execute on function public.link_document_to_authorization(uuid, uuid, text, date, date, text, boolean) from public;
revoke execute on function public.link_document_to_authorization(uuid, uuid, text, date, date, text, boolean) from anon;
grant execute on function public.link_document_to_authorization(uuid, uuid, text, date, date, text, boolean) to authenticated, service_role;

comment on function public.link_document_to_authorization(uuid, uuid, text, date, date, text, boolean) is
  'Puts an inbox document on its authorization as the authorization''s PDF or an invoice against it. Same client only, one authorization per file, blank dates filled and never overwritten, and dates filled from OCR marked as such. Service role, Admin and Billing.';
