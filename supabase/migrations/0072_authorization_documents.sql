-- ─────────────────────────────────────────────────────────────
-- An authorization's PDF, on the authorization
--
-- The documents folder holds the signed authorizations. The CRM holds the
-- authorizations. Until now nothing joined them: an authorization filed from
-- the inbox became a loose client attachment, the Authorizations tab never
-- showed a file, and "Create it in Billing" made a second authorization for a
-- number already on file. Meanwhile 159 of 162 authorizations have no dates,
-- and the dates are printed on exactly those PDFs.
--
-- Three rules, all here rather than on a screen:
--
--   One authorization per number. Numbers are compared ignoring case, spaces
--   and punctuation - "z-990 0001" is Z9900001 - and the database refuses a
--   second. All 162 numbers on file were already distinct under that rule
--   when this was written.
--
--   Confirming a document never makes a duplicate. If the number is on file
--   for that client, the PDF is attached to it. If it is on file for somebody
--   else, nothing changes and the reason is given.
--
--   A date on file is never overwritten by a date read off a PDF. A blank is
--   filled; a difference is reported for a person to settle.
--
-- Linking does not change what somebody filed a document as. An
-- "AUTHORIZATION AND INVOICE FOR SERVICE" filed as an Invoice is still an
-- Invoice on the Files tab; it is also, now, that authorization's PDF.
-- ─────────────────────────────────────────────────────────────

create or replace function public.normalize_auth_number(p text)
returns text language sql immutable parallel safe as $$
  select upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g'));
$$;

comment on function public.normalize_auth_number(text) is
  'An authorization number as it is compared: upper case, letters and digits only. lib/auth-number.ts does the same in the application.';

create unique index if not exists authorizations_number_unique
  on public.authorizations (public.normalize_auth_number(number))
  where public.normalize_auth_number(number) <> '';

-- ─────────────────────────────────────────────────────────────
-- Confirming a document as an authorization
--
-- Exactly one source: a file already on the client's record (p_attachment),
-- or a document waiting in the inbox (p_doc), which gets an attachment row if
-- it has none.
--
-- Then the authorization: the one named (p_auth), or the one whose number
-- matches p_number, or - only when no authorization anywhere has that number -
-- a new one built from the fields given.
--
-- Definer, so the refusals below are the database's own. Attachments have no
-- update policy for anyone, deliberately; this is the one way an attachment
-- gains an authorization, and it checks the role itself.
-- ─────────────────────────────────────────────────────────────
create or replace function public.confirm_authorization_document(
  p_attachment   uuid    default null,
  p_doc          uuid    default null,
  p_auth         uuid    default null,
  p_number       text    default null,
  p_service_type text    default null,
  p_rate_type    text    default null,
  p_rate         numeric default null,
  p_total_hours  numeric default null,
  p_start        date    default null,
  p_end          date    default null
) returns table (
  authorization_id uuid,
  auth_number      text,
  created          boolean,
  attachment_id    uuid,
  start_filled     boolean,
  end_filled       boolean,
  conflicts        text
)
language plpgsql security definer set search_path = public as $$
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
  if v_role is null or v_role not in ('Admin', 'Billing') then
    raise exception 'Only Admin and Billing confirm an authorization.'
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
$$;

revoke execute on function public.confirm_authorization_document(uuid, uuid, uuid, text, text, text, numeric, numeric, date, date) from public;
grant execute on function public.confirm_authorization_document(uuid, uuid, uuid, text, text, text, numeric, numeric, date, date) to authenticated;

comment on function public.confirm_authorization_document(uuid, uuid, uuid, text, text, text, numeric, numeric, date, date) is
  'Attaches a PDF to its authorization: the one named, the one with that number, or a new one only if no authorization has that number. Fills blank dates, never overwrites them, and refuses to cross clients. Admin and Billing only.';
