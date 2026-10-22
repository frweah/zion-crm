-- 0228 — Client portal, step 3: requests and uploads (portal brief, section 3).
--
-- Staff ask a client for a document from the client record: a resume, a
-- photo ID, a social security card, a signed form, or something else they
-- name. The client sees the request in the portal, uploads the file, and it
-- is filed in the client's documents under the matching category - with a
-- task for the assigned staff member to review it. Staff accept it, or ask
-- again with a reason the client reads.
--
-- The client's browser never writes to storage on its own say-so. The server
-- asks portal_upload_path for a place to put one file for one open request
-- of the signed-in client, mints a one-time upload address for exactly that
-- path, and only then does the browser send the bytes. portal_answer_request
-- files it, and refuses any path it did not hand out or any object that is
-- not there.
--
-- Applied in five parts (0228a-e) on 21 Oct 2026; this file is their sum.

-- ── the resume category ─────────────────────────────────────
insert into public.client_file_categories (key, label, detail, restricted_by_default, sort_order, active)
values ('Resume', 'Resume', 'The client''s resume, uploaded or built in the portal.', false, 45, true)
on conflict (key) do nothing;

-- ── where a document came from, and whether staff have accepted it ──
alter table public.attachments
  add column if not exists source text not null default 'Staff' check (source in ('Staff', 'Portal')),
  add column if not exists portal_account_id uuid references public.portal_accounts(id) on delete restrict,
  add column if not exists review_status text check (review_status in ('Waiting', 'Accepted', 'Returned'));

-- ── requests ────────────────────────────────────────────────
create table if not exists public.portal_requests (
  id                uuid primary key default gen_random_uuid(),
  client_id         uuid not null references public.clients(id) on delete cascade,
  item              text not null check (item in ('Resume', 'Photo ID', 'Social Security card', 'Signed form', 'Other')),
  label             text not null default '',
  note              text not null default '' check (length(note) <= 500),
  due               date,
  status            text not null default 'Open' check (status in ('Open', 'Answered', 'Accepted', 'Returned', 'Cancelled')),
  return_reason     text not null default '',
  attachment_id     uuid references public.attachments(id) on delete set null,
  answered_by       uuid references public.portal_accounts(id) on delete set null,
  requested_by      uuid references public.staff(id) on delete set null,
  requested_by_name text not null default '',
  reviewed_by       uuid references public.staff(id) on delete set null,
  reviewed_at       timestamptz,
  answered_at       timestamptz,
  created_at        timestamptz not null default now(),
  constraint portal_requests_other_named check (item <> 'Other' or btrim(label) <> '')
);
create index if not exists portal_requests_client on public.portal_requests (client_id, created_at desc);

alter table public.portal_requests enable row level security;
create policy portal_requests_read on public.portal_requests for select to authenticated
  using ((select public.is_active_staff()));
revoke all on public.portal_requests from anon, authenticated;
grant select on public.portal_requests to authenticated;

-- A task raised for an upload to review.
alter table public.tasks drop constraint if exists tasks_source_kind_check;
alter table public.tasks add constraint tasks_source_kind_check check (source_kind = any (array[
  'Interview prep', 'Interview day', 'Follow-up', 'billing_item', 'text_unanswered', 'intake',
  'authorization_received', 'authorization_missing', 'authorization_ending', 'placement_authorization',
  'portal_upload']));

-- What a request is called, for the client and for staff.
create or replace function public.portal_request_name(p_item text, p_label text)
returns text language sql immutable as $$
  select case when p_item = 'Other' then btrim(p_label) else p_item end;
$$;

-- Which file category an answered request is filed under.
create or replace function public.portal_request_category(p_item text)
returns text language sql immutable as $$
  select case p_item
           when 'Resume' then 'Resume'
           when 'Photo ID' then 'Identity document'
           when 'Social Security card' then 'Identity document'
           when 'Signed form' then 'Signed USOR form'
           else 'Other' end;
$$;

-- A line in each of the client's portal threads, so the request is there
-- when they open Messages, and so the notice that follows has something to
-- point at. Returns the threads written to.
create or replace function public.portal_post_system_line(p_client uuid, p_body text)
returns uuid[] language plpgsql security definer set search_path = public as $$
declare
  a      record;
  v_conv uuid;
  v_seq  bigint;
  v_out  uuid[] := '{}';
begin
  for a in select id from public.portal_accounts where client_id = p_client and disabled_at is null loop
    v_conv := public.portal_thread_for(a.id);
    insert into public.messages (conversation_id, sender_kind, sender_label, body)
    values (v_conv, 'system', 'Zion Voc Rehab', p_body)
    returning seq into v_seq;
    update public.conversations set last_message_at = now(), last_seq = v_seq where id = v_conv;
    v_out := v_out || v_conv;
  end loop;
  return v_out;
end;
$$;

-- ── the staff side ──────────────────────────────────────────
create or replace function public.portal_request_document(
  p_client uuid, p_item text, p_label text default '', p_note text default '', p_due date default null)
returns table (request_id uuid, conversation_ids uuid[])
language plpgsql security definer set search_path = public as $$
declare
  v_me   uuid := public.current_staff_id();
  v_name text;
  v_id   uuid;
begin
  if not public.can_manage_portal(p_client) then
    raise exception 'Only Admin, Reports or the assigned staff member asks this client for documents.' using errcode = 'insufficient_privilege';
  end if;
  if not exists (select 1 from public.portal_accounts where client_id = p_client and disabled_at is null) then
    raise exception 'This client has no portal access - give them access first, or ask by phone.' using errcode = 'check_violation';
  end if;
  if p_due is not null and p_due < (now() at time zone 'America/Denver')::date then
    raise exception 'The due date has already passed.' using errcode = 'check_violation';
  end if;

  select name into v_name from public.staff where id = v_me;
  insert into public.portal_requests (client_id, item, label, note, due, requested_by, requested_by_name)
  values (p_client, p_item, case when p_item = 'Other' then btrim(coalesce(p_label, '')) else '' end,
          btrim(coalesce(p_note, '')), p_due, v_me, coalesce(v_name, ''))
  returning id into v_id;

  return query select v_id, public.portal_post_system_line(p_client,
    'Zion has asked you for: ' || public.portal_request_name(p_item, p_label) ||
    '. Upload it under Documents.');
end;
$$;

create or replace function public.portal_cancel_request(p_request uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_r public.portal_requests%rowtype;
begin
  select * into v_r from public.portal_requests where id = p_request;
  if v_r.id is null or not public.can_manage_portal(v_r.client_id) then
    raise exception 'Only Admin, Reports or the assigned staff member changes this client''s requests.' using errcode = 'insufficient_privilege';
  end if;
  if v_r.status not in ('Open', 'Returned') then
    raise exception 'Only a request still waiting on the client can be withdrawn.' using errcode = 'check_violation';
  end if;
  update public.portal_requests set status = 'Cancelled' where id = p_request;
end;
$$;

-- Accept the upload, or ask again with a reason the client reads.
create or replace function public.portal_review_request(p_request uuid, p_accept boolean, p_reason text default '')
returns uuid[] language plpgsql security definer set search_path = public as $$
declare
  v_r  public.portal_requests%rowtype;
  v_me uuid := public.current_staff_id();
begin
  select * into v_r from public.portal_requests where id = p_request;
  if v_r.id is null or not public.can_manage_portal(v_r.client_id) then
    raise exception 'Only Admin, Reports or the assigned staff member reviews this client''s uploads.' using errcode = 'insufficient_privilege';
  end if;
  if v_r.status <> 'Answered' then
    raise exception 'There is no upload waiting for review on that request.' using errcode = 'check_violation';
  end if;
  if not p_accept and coalesce(btrim(p_reason), '') = '' then
    raise exception 'Say what is wrong with it, so the client knows what to send.' using errcode = 'check_violation';
  end if;

  update public.portal_requests
     set status = case when p_accept then 'Accepted' else 'Returned' end,
         return_reason = case when p_accept then '' else btrim(p_reason) end,
         reviewed_by = v_me, reviewed_at = now()
   where id = p_request;
  update public.attachments
     set review_status = case when p_accept then 'Accepted' else 'Returned' end,
         review_note = case when p_accept then review_note else btrim(p_reason) end
   where id = v_r.attachment_id;
  update public.tasks set status = 'Done', done_at = (now() at time zone 'America/Denver')::date, updated_at = now()
   where source_kind = 'portal_upload' and source_ref = p_request and status = 'Open';

  if p_accept then
    return '{}';
  end if;
  return public.portal_post_system_line(v_r.client_id,
    'Zion needs your ' || public.portal_request_name(v_r.item, v_r.label) || ' again: ' || btrim(p_reason));
end;
$$;

-- ── the client's side ───────────────────────────────────────
create or replace function public.portal_my_requests()
returns table (id uuid, name text, note text, due date, status text, return_reason text,
               filename text, answered_at timestamptz, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select r.id, public.portal_request_name(r.item, r.label), r.note, r.due, r.status, r.return_reason,
         a.filename, r.answered_at, r.created_at
    from public.portal_requests r
    left join public.attachments a on a.id = r.attachment_id
   where r.client_id = public.portal_client_id()
     and (r.status in ('Open', 'Answered', 'Returned')
          or (r.status = 'Accepted' and r.reviewed_at > now() - interval '30 days'))
   order by case r.status when 'Returned' then 0 when 'Open' then 1 when 'Answered' then 2 else 3 end,
            r.due nulls last, r.created_at;
$$;

create or replace function public.portal_open_requests()
returns integer language sql stable security definer set search_path = public as $$
  select count(*)::integer from public.portal_requests
   where client_id = public.portal_client_id() and status in ('Open', 'Returned');
$$;

-- A place to put one file for one request. The server mints the upload
-- address for exactly this path and nothing else.
create or replace function public.portal_upload_path(p_request uuid, p_filename text)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_client uuid := public.portal_client_id();
  v_safe   text;
begin
  if v_client is null then
    raise exception 'Sign in and agree to the portal terms first.' using errcode = 'insufficient_privilege';
  end if;
  if not exists (select 1 from public.portal_requests
                  where id = p_request and client_id = v_client and status in ('Open', 'Returned')) then
    raise exception 'That request is not waiting for a file. Refresh the page and try again.' using errcode = 'check_violation';
  end if;
  v_safe := left(regexp_replace(coalesce(p_filename, ''), '[^A-Za-z0-9._-]+', '-', 'g'), 80);
  if v_safe = '' or v_safe ~ '^[.-]+$' then v_safe := 'upload'; end if;
  return 'portal/' || v_client || '/' || p_request || '/' || gen_random_uuid() || '-' || v_safe;
end;
$$;

create or replace function public.portal_answer_request(
  p_request uuid, p_path text, p_filename text, p_mime text, p_size bigint, p_sha256 text)
returns uuid language plpgsql security definer set search_path = public, storage as $$
declare
  v_account uuid := public.portal_session_account_id();
  v_client  uuid := public.portal_client_id();
  v_r       public.portal_requests%rowtype;
  v_acc     public.portal_accounts%rowtype;
  v_cat     text;
  v_restr   boolean;
  v_att     uuid;
  v_staff   uuid;
begin
  if v_client is null then
    raise exception 'Sign in and agree to the portal terms first.' using errcode = 'insufficient_privilege';
  end if;
  select * into v_r from public.portal_requests where id = p_request and client_id = v_client;
  if v_r.id is null or v_r.status not in ('Open', 'Returned') then
    raise exception 'That request is not waiting for a file. Refresh the page and try again.' using errcode = 'check_violation';
  end if;
  if p_path is null or p_path not like 'portal/' || v_client || '/' || p_request || '/%' then
    raise exception 'That upload did not come from this request. Try again.' using errcode = 'check_violation';
  end if;
  if not exists (select 1 from storage.objects where bucket_id = 'client-files' and name = p_path) then
    raise exception 'The file did not finish uploading. Try again.' using errcode = 'check_violation';
  end if;

  select * into v_acc from public.portal_accounts where id = v_account;
  v_cat := public.portal_request_category(v_r.item);
  select restricted_by_default into v_restr from public.client_file_categories where key = v_cat;

  begin
    insert into public.attachments (client_id, storage_path, filename, mime_type, size_bytes, category, restricted,
                                    note, uploaded_by, uploaded_by_name, sha256, source, portal_account_id, review_status)
    values (v_client, p_path, left(btrim(coalesce(nullif(p_filename, ''), 'upload')), 200), coalesce(p_mime, ''),
            coalesce(p_size, 0), v_cat, coalesce(v_restr, false),
            'Uploaded in the client portal for: ' || public.portal_request_name(v_r.item, v_r.label),
            null, v_acc.name || ' (portal)', nullif(p_sha256, ''), 'Portal', v_account, 'Waiting')
    returning id into v_att;
  exception when unique_violation then
    raise exception 'Zion already has that exact file. If it is the right one, send a message instead.' using errcode = 'check_violation';
  end;

  update public.portal_requests
     set status = 'Answered', attachment_id = v_att, answered_by = v_account, answered_at = now(), return_reason = ''
   where id = p_request;

  select assigned_staff_id into v_staff from public.clients where id = v_client;
  insert into public.tasks (client_id, assigned_staff_id, title, due, system_generated, source_kind, source_ref)
  values (v_client, coalesce(v_staff, v_r.requested_by),
          'Review ' || public.portal_request_name(v_r.item, v_r.label) || ' uploaded in the portal',
          (now() at time zone 'America/Denver')::date, true, 'portal_upload', p_request);

  return v_att;
end;
$$;

-- ── who may call what ───────────────────────────────────────
revoke execute on function public.portal_post_system_line(uuid, text) from public, anon, authenticated;
revoke execute on function public.portal_request_document(uuid, text, text, text, date), public.portal_cancel_request(uuid),
  public.portal_review_request(uuid, boolean, text), public.portal_my_requests(), public.portal_open_requests(),
  public.portal_upload_path(uuid, text), public.portal_answer_request(uuid, text, text, text, bigint, text)
  from public, anon;
grant execute on function public.portal_request_document(uuid, text, text, text, date), public.portal_cancel_request(uuid),
  public.portal_review_request(uuid, boolean, text) to authenticated;
grant execute on function public.portal_my_requests(), public.portal_open_requests(),
  public.portal_upload_path(uuid, text), public.portal_answer_request(uuid, text, text, text, bigint, text)
  to authenticated, portal_client;
