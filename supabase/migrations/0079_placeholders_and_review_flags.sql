-- ─────────────────────────────────────────────────────────────
-- Placeholders replaced, and files flagged for a second look
--
-- The spreadsheet import made "(workbook) coaching NNNN" authorizations for
-- coaching that was on the books without a USOR number. Hours were logged
-- against them and carried over. When the real authorization turns up - a
-- scan, read by OCR - confirming it as new would make a second authorization
-- for the same service, with the hours left behind on the placeholder.
--
-- So a placeholder can be replaced: the same authorization takes the real
-- number, keeps its id and therefore everything hanging off it (carried hours,
-- service entries, invoices, forms), gets the PDF, and has its blank dates
-- filled. Admin or Billing, from the inbox, logged.
--
-- And a file on an authorization can carry a review note: OCR read a number
-- one digit away from the authorization it is on, which is either a misread or
-- the wrong authorization, and only a person looking at the scan can say.
-- ─────────────────────────────────────────────────────────────

alter table public.attachments
  add column if not exists review_note text not null default '';

comment on column public.attachments.review_note is
  'Why a person should look at this file again, shown beside it. Empty when nothing is in doubt.';

alter table public.authorization_corrections drop constraint if exists authorization_corrections_field_check;
alter table public.authorization_corrections add constraint authorization_corrections_field_check
  check (field in ('Service', 'Client', 'Number', 'Document'));

create or replace function public.replace_placeholder_authorization(
  p_doc         uuid,
  p_placeholder uuid,
  p_number      text,
  p_start       date default null,
  p_end         date default null
) returns table (authorization_id uuid, auth_number text, start_filled boolean, end_filled boolean, conflicts text)
language plpgsql security definer set search_path = public as $$
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
  if v_role is null or v_role not in ('Admin', 'Billing') then
    raise exception 'Only Admin and Billing replace a placeholder authorization.' using errcode = 'insufficient_privilege';
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
$$;

revoke execute on function public.replace_placeholder_authorization(uuid, uuid, text, date, date) from public;
revoke execute on function public.replace_placeholder_authorization(uuid, uuid, text, date, date) from anon;
grant execute on function public.replace_placeholder_authorization(uuid, uuid, text, date, date) to authenticated;

comment on function public.replace_placeholder_authorization(uuid, uuid, text, date, date) is
  'Gives an imported "(workbook)" placeholder authorization its real number from a confirmed PDF: same authorization, so carried hours, entries and invoices stay; PDF attached; blank dates filled; logged. Admin and Billing.';
