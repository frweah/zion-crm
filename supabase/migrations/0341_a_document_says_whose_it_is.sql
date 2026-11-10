-- Zion Vocational Rehab CRM — a document says whose it is
--
-- "Each waiting document gets 'Assign to client' (search) and 'New client
-- from this document' (name, counselor, office read from the PDF, editable),
-- then creates or attaches the authorization with the one-door function."
--
-- A hundred and eight documents are waiting with no client against them, and
-- nothing in the practice could give them one. The inbox offered exactly one
-- answer — map a whole *folder* to a client — which is right for a folder
-- named after somebody and useless for the ninety-odd that arrived by email
-- into a folder called "service@ mail".
--
-- So two answers per document. Neither of them files anything or confirms
-- anything: they say whose the document is, and then the doors that were
-- already there do what they already do. A document with a client on it is a
-- document the inbox can file, and an authorization on it is one Billing can
-- confirm through `confirm_authorization_document`, which is still the only
-- way an authorization is created from a document.
--
-- ── and the name is read, not trusted ────────────────────────
--
-- The parse gives a name from the PDF and it is often wrong in a way that
-- matters. The authorization looked at while writing this has a clientName of
-- "<firstname> Client ID", because the form prints
-- "Client Name: <surname>, <firstname> Client ID: 89914" on one line and the
-- parser took the wrong span. So the screen offers the parse **and the line it
-- came from**, and whoever is reading corrects it. A function that created a
-- client straight from the parse would have created a client called
-- "<firstname> Client ID", and the check below refuses exactly that.

begin;

-- ── whose it is ──────────────────────────────────────────────

create or replace function public.assign_document_to_client(p_doc uuid, p_client uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_doc    public.inbox_documents%rowtype;
  v_name   text;
  v_staff  uuid := public.current_staff_id();
begin
  if public.current_staff_role() is distinct from 'Admin'
     and public.current_staff_role() is distinct from 'Billing'
     and not public.staff_has_area('billing', 'edit') then
    raise exception 'Only Admin and Billing say whose a document is.'
      using errcode = 'insufficient_privilege';
  end if;

  select * into v_doc from public.inbox_documents where id = p_doc for update;
  if not found then
    raise exception 'That document is not in the inbox.' using errcode = 'no_data_found';
  end if;
  if v_doc.state <> 'Pending' then
    raise exception 'That one has already been dealt with.' using errcode = 'check_violation';
  end if;

  select c.name into v_name from public.clients c
   where c.id = p_client and c.merged_into is null;
  if v_name is null then
    raise exception 'That client is not on file.' using errcode = 'no_data_found';
  end if;

  update public.inbox_documents
     set client_id = p_client,
         -- Not decided: saying whose a document is leaves it waiting to be
         -- filed or confirmed, which is a different decision by a different
         -- person. The inbox's own count stays honest.
         parsed = coalesce(parsed, '{}'::jsonb) || jsonb_build_object(
           'assigned_by', coalesce((select s.name from public.staff s where s.id = v_staff), 'staff'),
           'assigned_at', now())
   where id = p_doc;
end;
$$;

comment on function public.assign_document_to_client is
  'Says which client a waiting document belongs to. Files nothing and '
  'confirms nothing: it leaves the document where it was, with a client on '
  'it, so the doors that file and confirm can be used.';

revoke all on function public.assign_document_to_client(uuid, uuid) from public, anon, authenticated;
grant execute on function public.assign_document_to_client(uuid, uuid) to authenticated;

-- ── or a client who is not on file yet ───────────────────────

create or replace function public.client_from_document(
  p_doc uuid,
  p_name text,
  p_counselor uuid,
  p_office text,
  p_agency_id text,
  p_no_phone_reason text
) returns uuid
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_doc    public.inbox_documents%rowtype;
  v_client uuid;
  v_staff  uuid := public.current_staff_id();
  v_name   text := btrim(coalesce(p_name, ''));
  v_same   integer;
begin
  if public.current_staff_role() is distinct from 'Admin'
     and public.current_staff_role() is distinct from 'Billing'
     and not public.staff_has_area('billing', 'edit') then
    raise exception 'Only Admin and Billing add a client from a document.'
      using errcode = 'insufficient_privilege';
  end if;

  select * into v_doc from public.inbox_documents where id = p_doc for update;
  if not found then
    raise exception 'That document is not in the inbox.' using errcode = 'no_data_found';
  end if;
  if v_doc.state <> 'Pending' then
    raise exception 'That one has already been dealt with.' using errcode = 'check_violation';
  end if;
  if v_doc.client_id is not null then
    raise exception 'That document already belongs to somebody.' using errcode = 'check_violation';
  end if;

  if length(v_name) < 3 or position(' ' in v_name) = 0 then
    raise exception 'Give the client''s full name as the document has it.'
      using errcode = 'check_violation';
  end if;

  /*
   * The parse's own mistake, refused by name.
   *
   * The USOR form prints the name and the client number on one line, and the
   * parser reads the name as running into the words that follow it - so its
   * suggestion can be a first name with "Client ID" stuck on the end. A
   * client called that would be created by anybody who clicked without
   * reading. It is the one wrong answer this function can recognise, so it
   * recognises it.
   */
  if v_name ilike '%client id%' or v_name ilike '%client name%' then
    raise exception 'That is the form''s own wording, not a name. Read the name off the line below it.'
      using errcode = 'check_violation';
  end if;

  -- Somebody already on file under that name is a duplicate waiting to
  -- happen, and the practice has had two of those.
  select count(*) into v_same from public.clients c
   where c.merged_into is null and lower(btrim(c.name)) = lower(v_name);
  if v_same > 0 then
    raise exception 'There is already a client with that name. Assign the document to them instead.'
      using errcode = 'unique_violation';
  end if;

  insert into public.clients
    (name, stage, status, funding_source, counselor_id, referring_office, agency_id,
     assigned_staff_id, no_phone_reason, import_review)
  values
    (v_name, 'Intake', 'Active', 'Utah VR', p_counselor,
     nullif(btrim(coalesce(p_office, '')), ''), nullif(btrim(coalesce(p_agency_id, '')), ''),
     v_staff, btrim(coalesce(nullif(btrim(coalesce(p_no_phone_reason, '')), ''),
                            'Added from a document; no number on it')),
     format('Added from %s', coalesce(nullif(v_doc.filename, ''), 'a document in the inbox')))
  returning id into v_client;

  update public.inbox_documents
     set client_id = v_client,
         parsed = coalesce(parsed, '{}'::jsonb) || jsonb_build_object(
           'assigned_by', coalesce((select s.name from public.staff s where s.id = v_staff), 'staff'),
           'assigned_at', now(),
           'client_made_here', true)
   where id = p_doc;

  return v_client;
end;
$$;

comment on function public.client_from_document is
  'A client the practice does not have yet, from the document that arrived '
  'about them. The name is whatever the person reading the PDF types: the '
  'parse is a suggestion and is often wrong in a way that matters.';

revoke all on function public.client_from_document(uuid, text, uuid, text, text, text)
  from public, anon, authenticated;
grant execute on function public.client_from_document(uuid, text, uuid, text, text, text)
  to authenticated;

commit;
