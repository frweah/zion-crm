-- Zion Vocational Rehab CRM — the inbox is Admin's; the policy is signed again
--
-- The owner, 19 Sept 2026:
--
--   Billing confirms the authorizations that arrive in the documents folder,
--   from Billing → Authorizations, with the PDF beside the form. Everything
--   else in the inbox - folders nobody has claimed, warrant stubs, invoices,
--   USOR forms, anything unreadable - is Admin's, in Admin → Documents.
--   Job Search and Reports no longer review the inbox.
--
--   The data-handling policy has a new version (0102). Everybody signs it on
--   their next sign-in; what they signed before stays on file against the
--   version it was.

-- ── who sees which inbox document ───────────────────────────
-- Admin: all of it. Billing (anybody with Billing to edit): the authorizations
-- - read as one, or named as one. Nobody else.
create or replace function public.inbox_document_open_to_me(p_doc uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select auth.uid() is null
      or coalesce(auth.role(), '') = 'service_role'
      or public.is_admin()
      or (public.staff_has_area('billing', 'edit')
          and exists (select 1 from public.inbox_documents d
                       where d.id = p_doc
                         and (d.kind = 'Authorization' or d.proposal -> 'filename' ->> 'named' = 'Authorization')));
$$;
revoke execute on function public.inbox_document_open_to_me(uuid) from public, anon;
grant execute on function public.inbox_document_open_to_me(uuid) to authenticated, service_role;

drop policy if exists inbox_documents_read on public.inbox_documents;
create policy inbox_documents_read on public.inbox_documents for select to authenticated
  using ((select public.is_admin())
         or ((select public.staff_has_area('billing', 'edit'))
             and (kind = 'Authorization' or proposal -> 'filename' ->> 'named' = 'Authorization')));

drop policy if exists inbox_documents_write on public.inbox_documents;
create policy inbox_documents_write on public.inbox_documents for update to authenticated
  using ((select public.is_admin())
         or ((select public.staff_has_area('billing', 'edit'))
             and (kind = 'Authorization' or proposal -> 'filename' ->> 'named' = 'Authorization')))
  with check ((select public.is_admin())
         or ((select public.staff_has_area('billing', 'edit'))
             and (kind = 'Authorization' or proposal -> 'filename' ->> 'named' = 'Authorization')));

-- Saying whose a folder is: Admin's.
drop policy if exists inbox_folder_map_write on public.inbox_folder_map;
create policy inbox_folder_map_write on public.inbox_folder_map for all to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));

-- ── the functions that act on an inbox document ─────────────
-- As they stood, each now also asking whether this document is the caller's
-- to act on. They run as definer, so the table's rules alone would not stop
-- them.
CREATE OR REPLACE FUNCTION public.file_document_as_note(p_doc uuid, p_type text, p_at date, p_dated_from text, p_text text, p_category text DEFAULT 'Other'::text, p_restricted boolean DEFAULT false, p_outcome text DEFAULT NULL::text, p_ocr boolean DEFAULT false)
 RETURNS TABLE(note_id uuid, attachment_id uuid, created boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

  -- Admin's inbox, except the authorizations Billing confirms (0103).
  if not public.inbox_document_open_to_me(p_doc) then
    raise exception 'That document is the administrator''s to deal with in Admin → Documents.'
      using errcode = 'insufficient_privilege';
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
$function$;

CREATE OR REPLACE FUNCTION public.link_document_to_authorization(p_doc uuid, p_auth uuid, p_category text, p_start date DEFAULT NULL::date, p_end date DEFAULT NULL::date, p_outcome text DEFAULT NULL::text, p_ocr boolean DEFAULT false)
 RETURNS TABLE(attachment_id uuid, start_filled boolean, end_filled boolean, conflicts text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  if (v_role is null or v_role not in ('service_role', 'Admin', 'Billing')) and not public.staff_has_area('billing', 'edit') then
    raise exception 'Only Admin and Billing put a document on an authorization.' using errcode = 'insufficient_privilege';
  end if;

  -- Admin's inbox, except the authorizations Billing confirms (0103).
  if not public.inbox_document_open_to_me(p_doc) then
    raise exception 'That document is the administrator''s to deal with in Admin → Documents.'
      using errcode = 'insufficient_privilege';
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
$function$;

CREATE OR REPLACE FUNCTION public.replace_placeholder_authorization(p_doc uuid, p_placeholder uuid, p_number text, p_start date DEFAULT NULL::date, p_end date DEFAULT NULL::date)
 RETURNS TABLE(authorization_id uuid, auth_number text, start_filled boolean, end_filled boolean, conflicts text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
declare
  v_role  text := public.current_staff_role();
  v_staff uuid := public.current_staff_id();
  v_name  text;
  v_doc   public.inbox_documents%rowtype;
  v_auth  public.authorizations%rowtype;
  v_att   public.attachments%rowtype;
  v_num   text := btrim(coalesce(p_number, ''));
  v_sfill boolean := false;
  v_efill boolean := false;
  v_conf  text[] := '{}';
begin
  if (v_role is null or v_role not in ('Admin', 'Billing')) and not public.staff_has_area('billing', 'edit') then
    raise exception 'Only Admin and Billing replace a placeholder authorization.' using errcode = 'insufficient_privilege';
  end if;

  -- Admin's inbox, except the authorizations Billing confirms (0103).
  if not public.inbox_document_open_to_me(p_doc) then
    raise exception 'That document is the administrator''s to deal with in Admin → Documents.'
      using errcode = 'insufficient_privilege';
  end if;

  select * into v_doc from public.inbox_documents where id = p_doc;
  if not found then
    raise exception 'That document is not in the inbox.' using errcode = 'no_data_found';
  end if;
  if v_doc.client_id is null or v_doc.storage_path is null then
    raise exception 'That document has no client or no stored file.' using errcode = 'check_violation';
  end if;

  select * into v_auth from public.authorizations where id = p_placeholder for update;
  if not found then
    raise exception 'That authorization does not exist.' using errcode = 'no_data_found';
  end if;
  if v_auth.client_id <> v_doc.client_id then
    raise exception 'That placeholder is another client''s. Nothing was changed.' using errcode = 'check_violation';
  end if;
  if v_auth.number not like '(workbook)%' then
    raise exception 'Only an imported "(workbook)" placeholder is replaced. % is a real authorization.', v_auth.number
      using errcode = 'check_violation';
  end if;

  if public.normalize_auth_number(v_num) = '' then
    raise exception 'Give the authorization''s real number.' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.authorizations
              where public.normalize_auth_number(number) = public.normalize_auth_number(v_num)) then
    raise exception '% is already on file. Attach the PDF to it instead of replacing a placeholder.', v_num
      using errcode = 'check_violation';
  end if;

  select name into v_name from public.staff where id = v_staff;

  -- The file first, so a refusal leaves the placeholder as it was.
  select * into v_att from public.attachments
   where storage_path = v_doc.storage_path and client_id = v_doc.client_id
   order by created_at limit 1;
  if not found then
    insert into public.attachments
      (client_id, storage_path, filename, mime_type, size_bytes, category, note, uploaded_by, uploaded_by_name)
    values
      (v_doc.client_id, v_doc.storage_path, v_doc.filename, 'application/pdf', v_doc.size_bytes,
       'Authorization', 'From the documents folder', v_staff, coalesce(v_name, ''))
    returning * into v_att;
  elsif v_att.auth_id is not null and v_att.auth_id <> p_placeholder then
    raise exception 'That file is on another authorization. Nothing was changed.' using errcode = 'check_violation';
  end if;

  update public.authorizations set number = v_num where id = p_placeholder;

  insert into public.authorization_corrections
    (auth_id, auth_number, field, was_value, new_value, reason, staff_id, staff_name)
  values
    (p_placeholder, v_num, 'Number', v_auth.number, v_num,
     format('The placeholder is authorization %s, confirmed from %s. Its carried hours, entries and invoices stay with it.',
            v_num, v_doc.filename),
     v_staff, coalesce(v_name, ''));

  update public.attachments set auth_id = p_placeholder, review_note = '' where id = v_att.id;

  -- Dates a person confirmed: fill a blank, never overwrite.
  perform set_config('zion.filling_dates', 'person', true);
  if p_start is not null then
    if v_auth.start_date is null then
      update public.authorizations set start_date = p_start where id = p_placeholder;
      v_sfill := true;
    elsif v_auth.start_date <> p_start then
      v_conf := v_conf || format('start date on file is %s, the form says %s', v_auth.start_date, p_start);
    end if;
  end if;
  if p_end is not null then
    if v_auth.end_date is null then
      update public.authorizations set end_date = p_end where id = p_placeholder;
      v_efill := true;
    elsif v_auth.end_date <> p_end then
      v_conf := v_conf || format('end date on file is %s, the form says %s', v_auth.end_date, p_end);
    end if;
  end if;
  perform set_config('zion.filling_dates', '', true);

  update public.inbox_documents
     set state = 'Filed', decided_by = v_staff, decided_at = now(),
         outcome = format('Replaced placeholder %s with authorization %s', v_auth.number, v_num)
   where id = p_doc and state = 'Pending';

  authorization_id := p_placeholder; auth_number := v_num;
  start_filled := v_sfill; end_filled := v_efill;
  conflicts := nullif(array_to_string(v_conf, '; '), '');
  return next;
end;
$function$;

CREATE OR REPLACE FUNCTION public.confirm_authorization_document(p_attachment uuid DEFAULT NULL::uuid, p_doc uuid DEFAULT NULL::uuid, p_auth uuid DEFAULT NULL::uuid, p_number text DEFAULT NULL::text, p_service_type text DEFAULT NULL::text, p_rate_type text DEFAULT NULL::text, p_rate numeric DEFAULT NULL::numeric, p_total_hours numeric DEFAULT NULL::numeric, p_start date DEFAULT NULL::date, p_end date DEFAULT NULL::date)
 RETURNS TABLE(authorization_id uuid, auth_number text, created boolean, attachment_id uuid, start_filled boolean, end_filled boolean, conflicts text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_role    text := public.current_staff_role();
  v_staff   uuid := public.current_staff_id();
  v_name    text;
  v_client  uuid;
  v_att     public.attachments%rowtype;
  v_doc     public.inbox_documents%rowtype;
  v_auth    public.authorizations%rowtype;
  v_norm    text;
  v_type    text := coalesce(nullif(btrim(p_rate_type), ''), 'Hourly');
  v_created boolean := false;
  v_sfill   boolean := false;
  v_efill   boolean := false;
  v_conf    text[] := '{}';
begin
  if (v_role is null or v_role not in ('Admin', 'Billing')) and not public.staff_has_area('billing', 'edit') then
    raise exception 'Only Admin and Billing confirm an authorization.'
      using errcode = 'insufficient_privilege';
  end if;

  -- Admin's inbox, except the authorizations Billing confirms (0103).
  if p_doc is not null and not public.inbox_document_open_to_me(p_doc) then
    raise exception 'That document is the administrator''s to deal with in Admin → Documents.'
      using errcode = 'insufficient_privilege';
  end if;

  if (p_attachment is null) = (p_doc is null) then
    raise exception 'Say which document: a file on record or an inbox document, and only one.'
      using errcode = 'invalid_parameter_value';
  end if;

  select name into v_name from public.staff where id = v_staff;

  -- ── the document ─────────────────────────────────────────
  if p_doc is not null then
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

    select * into v_att from public.attachments
     where storage_path = v_doc.storage_path and client_id = v_doc.client_id
     order by created_at
     limit 1;

    if not found then
      insert into public.attachments
        (client_id, storage_path, filename, mime_type, size_bytes, category, note,
         uploaded_by, uploaded_by_name)
      values
        (v_doc.client_id, v_doc.storage_path, v_doc.filename, 'application/pdf', v_doc.size_bytes,
         'Authorization', 'From the documents folder', v_staff, coalesce(v_name, ''))
      returning * into v_att;
    end if;
  else
    select * into v_att from public.attachments where id = p_attachment;
    if not found then
      raise exception 'That file is not on record.' using errcode = 'no_data_found';
    end if;
  end if;

  v_client := v_att.client_id;

  if v_att.restricted and not public.can_see_restricted(v_client) then
    raise exception 'That file is restricted.' using errcode = 'insufficient_privilege';
  end if;

  -- ── the authorization ────────────────────────────────────
  if p_auth is not null then
    select * into v_auth from public.authorizations where id = p_auth;
    if not found then
      raise exception 'That authorization does not exist.' using errcode = 'no_data_found';
    end if;
  else
    v_norm := public.normalize_auth_number(p_number);
    if v_norm = '' then
      raise exception 'An authorization needs its number.' using errcode = 'check_violation';
    end if;

    select * into v_auth from public.authorizations
     where public.normalize_auth_number(number) = v_norm;

    if not found then
      if coalesce(btrim(p_service_type), '') = '' then
        raise exception 'A new authorization needs its service.' using errcode = 'check_violation';
      end if;
      if p_rate is null or p_rate <= 0 then
        raise exception 'A new authorization needs its rate or fee.' using errcode = 'check_violation';
      end if;
      if v_type = 'Hourly' and (p_total_hours is null or p_total_hours <= 0) then
        raise exception 'An hourly authorization needs the hours USOR authorized.'
          using errcode = 'check_violation';
      end if;

      insert into public.authorizations
        (client_id, number, service_type, rate_type, rate, total_hours, start_date, end_date, status)
      values
        (v_client, btrim(p_number), btrim(p_service_type), v_type, p_rate,
         case when v_type = 'Hourly' then p_total_hours end, p_start, p_end, 'Open')
      returning * into v_auth;

      v_created := true;
      v_sfill := p_start is not null;
      v_efill := p_end is not null;
    end if;
  end if;

  -- The one mistake this exists to make impossible: one client's PDF on
  -- another client's authorization.
  if v_auth.client_id <> v_client then
    raise exception 'Authorization % is on file for a different client. Nothing was changed.', v_auth.number
      using errcode = 'check_violation';
  end if;

  if v_att.auth_id is not null and v_att.auth_id <> v_auth.id then
    raise exception 'That file is already attached to another authorization. Nothing was changed.'
      using errcode = 'check_violation';
  end if;

  update public.attachments set auth_id = v_auth.id where id = v_att.id;

  -- ── dates: fill a blank, never overwrite ─────────────────
  if not v_created then
    if p_start is not null then
      if v_auth.start_date is null then
        update public.authorizations set start_date = p_start where id = v_auth.id;
        v_sfill := true;
      elsif v_auth.start_date <> p_start then
        v_conf := v_conf || format('start date on file is %s, the PDF says %s', v_auth.start_date, p_start);
      end if;
    end if;

    if p_end is not null then
      if v_auth.end_date is null then
        update public.authorizations set end_date = p_end where id = v_auth.id;
        v_efill := true;
      elsif v_auth.end_date <> p_end then
        v_conf := v_conf || format('end date on file is %s, the PDF says %s', v_auth.end_date, p_end);
      end if;
    end if;
  end if;

  -- ── the inbox ────────────────────────────────────────────
  -- A document still waiting is now dealt with. One somebody already decided
  -- about keeps that decision and its wording.
  update public.inbox_documents
     set state = 'Filed',
         decided_by = v_staff,
         decided_at = now(),
         outcome = format('Linked to authorization %s', v_auth.number)
   where storage_path = v_att.storage_path
     and client_id = v_client
     and state = 'Pending';

  return query
    select v_auth.id, v_auth.number, v_created, v_att.id, v_sfill, v_efill,
           nullif(array_to_string(v_conf, '; '), '');
end;
$function$;

-- ── the policy, signed again ────────────────────────────────
create or replace function public.onboarding_step_done(p_staff uuid, p_key text)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare
  v_type text;
begin
  if auth.uid() is not null and coalesce(auth.role(), '') <> 'service_role'
     and not (public.is_admin() or p_staff = public.current_staff_id()) then
    return null;
  end if;
  select coalesce(employment_type, 'Contractor') into v_type from public.staff_employment where staff_id = p_staff;
  v_type := coalesce(v_type, 'Contractor');

  return case p_key
    when 'personal_details' then exists (
      select 1 from public.staff_personal p
       where p.staff_id = p_staff
         and trim(p.legal_name) <> '' and trim(p.address_line1) <> '' and trim(p.city) <> ''
         and trim(p.state) <> '' and trim(p.postal_code) <> '' and trim(p.phone) <> ''
         and p.date_of_birth is not null
         and trim(p.emergency_name) <> '' and trim(p.emergency_phone) <> '')
    when 'identity_documents' then exists (
      select 1 from public.staff_files f
       where f.staff_id = p_staff
         and f.category = case when v_type = 'Employee' then 'I-9' else 'Identity document' end)
    when 'identity_inspected' then
      exists (select 1 from public.staff_files f where f.staff_id = p_staff and f.category = 'I-9')
      and not exists (select 1 from public.staff_files f
                       where f.staff_id = p_staff and f.category = 'I-9' and f.inspected_at is null)
    when 'certifications_submitted' then
      exists (select 1 from public.staff_onboarding o
               where o.staff_id = p_staff and o.certifications_confirmed_at is not null)
      or not exists (select 1 from public.staff_credential_status cs
                      where cs.staff_id = p_staff and cs.kind = 'certificate' and cs.state = 'Missing')
    when 'tax_form_signed' then exists (
      select 1 from public.tax_form_submissions f
        left join public.contractor_profiles cp on cp.staff_id = f.staff_id
       where f.staff_id = p_staff and f.status = 'Signed'
         and f.form_type = case
               when v_type = 'Employee' then 'W-4'
               when cp.tax_status = 'Foreign person' then 'W-8BEN'
               else 'W-9' end)
    when 'policy_signed' then
      exists (select 1 from public.staff_policy_signatures g
                join public.staff_policies sp on sp.key = g.policy_key and sp.version = g.policy_version
               where g.staff_id = p_staff and sp.key = 'data-handling' and sp.is_current)
      -- Signed on paper before the app could take a signature, and ticked
      -- then: that was version 1, and counts only while version 1 is the one
      -- in force. A later version is signed in the app (0103).
      or (exists (select 1 from public.staff_policies sp
                   where sp.key = 'data-handling' and sp.is_current and sp.version = 1)
          and exists (select 1 from public.staff_checklist_items i
                        join public.checklist_tasks t on t.id = i.task_id
                       where i.staff_id = p_staff and t.auto_key = 'policy_signed' and i.done_on is not null))
    when 'payment_setup' then exists (
      select 1 from public.staff_payment_setup ps where ps.staff_id = p_staff)
    else null
  end;
end;
$$;

-- Whether the person signed in owes a signature on a policy now in force.
create or replace function public.policy_signature_due()
returns boolean language sql stable security invoker set search_path = public as $$
  select exists (
    select 1 from public.staff_policies p
     where p.is_current
       and not exists (select 1 from public.staff_policy_signatures g
                        where g.staff_id = public.current_staff_id()
                          and g.policy_key = p.key and g.policy_version = p.version));
$$;
revoke execute on function public.policy_signature_due() from public, anon;
grant execute on function public.policy_signature_due() to authenticated;

-- The inbox's hint is Admin's now, on Admin → Documents.
update public.tour_hints set screen = '/admin/documents', roles = array['Admin'] where key = 'document-inbox';
