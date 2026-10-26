-- Zion Vocational Rehab CRM — 0253 replacing asks the column
--
-- `replace_placeholder_authorization` refused anything whose number did not
-- start with `(workbook)`, and no authorization on file starts with it. So
-- the "Replace with this number" action - the one the owner asked to be
-- reachable two days ago - would have refused all four of the placeholders it
-- exists for, in words naming a convention that is not in use.
--
-- It asks `has_usor_number` now (0252), which is the same question the
-- screens ask and the same one the confirm queue filters on. One definition,
-- and the next placeholder convention changes nothing here.
--
-- Built from the live definition; everything else is unchanged.

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
  if v_auth.has_usor_number then
    raise exception 'That authorization already has a number: %. Replacing is for one that has not got one yet.', v_auth.number
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

  /**
   * The reason goes in before the number does.
   *
   * Since 0190 the database refuses a change to a number that was already
   * there without one, and writes the log line itself. This function had
   * been writing that line by hand - so the reason is handed over instead,
   * and the insert that used to follow is gone. One copy of the rule, and
   * one row in the log rather than two saying the same thing.
   *
   * The wording is the one this function always used, because it says the
   * part only this function knows: which document confirmed it, and that the
   * carried hours stay with the record.
   */
  perform set_config('zion.correction_reason',
    format('The placeholder is authorization %s, confirmed from %s. Its carried hours, entries and invoices stay with it.',
           v_num, v_doc.filename), true);

  update public.authorizations set number = v_num where id = p_placeholder;

  perform set_config('zion.correction_reason', '', true);

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
