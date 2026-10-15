-- Zion Vocational Rehab CRM — a client document has a date, a fingerprint,
-- and a shadow where a restricted one sits
-- (owner, 15 Oct 2026, item 1)
--
-- Most of what was asked for is already here and this adds to it rather than
-- building beside it: attachments is the table, client-files is the bucket,
-- and the agent, the authorization confirm queue and Admin → Documents all
-- already read these rows. Four things were missing.
--
-- ── a document has two dates ────────────────────────────────
--
-- created_at is when somebody uploaded it. That is not the date on the
-- document, and sorting a client's file by upload date puts a form signed in
-- March below a scan of it made in October. So document_date is the date on
-- the paper, defaulting to today, and created_at goes on recording the upload
-- by itself.
--
-- Existing rows are backfilled from created_at, which is the best thing known
-- about them and is what the list has been sorting by all along.
--
-- ── and a fingerprint ───────────────────────────────────────
--
-- The owner asked for the same dedupe the document store already has.
-- attachments had unique (storage_path), which dedupes the *path* - and since
-- every upload gets a fresh timestamped path, the same scan uploaded twice
-- landed twice. inbox_documents has had sha256 since the agent was built;
-- this gives attachments the same, and one client cannot hold the same bytes
-- twice.
--
-- Partial, so the rows that predate it (sha256 null) do not collide with each
-- other. They are not going to be deduped retrospectively - nobody has the
-- bytes to hash without downloading every file - and a null means "nobody
-- asked", not "this is unique".
--
-- ── a restricted file leaves a shadow ───────────────────────
--
-- The rule until today was the opposite, and it was deliberate: the client
-- record said "Restricted documents are filtered out by RLS, not here - a
-- staff member without access does not learn that they exist."
--
-- The owner has reversed it: "everyone else sees that a restricted file
-- exists but not its name or contents." That is a real trade and it is worth
-- naming rather than quietly flipping. What is gained is that a colleague can
-- tell the difference between a client with nothing on file and a client
-- whose file they cannot see, so they ask instead of re-uploading. What is
-- given up is that the existence of a restricted document is now itself
-- visible - a guardianship document on a file says something by being there.
--
-- The redaction is done in a view rather than in a screen, because a screen
-- that filters is a screen somebody forgets to write. The view hands back the
-- row with its name, note and path blanked for anybody who may not see it;
-- the underlying table still refuses them outright, so the bytes are no
-- nearer than they were.
--
-- ── and the editing the owner asked for ─────────────────────
--
-- attachments had no update policy at all, so a name could not be corrected
-- after upload. Admin or whoever uploaded it, which is the same test the
-- delete policy already uses.

-- ── the two columns ─────────────────────────────────────────
alter table public.attachments add column if not exists document_date date;
alter table public.attachments add column if not exists sha256 text;

update public.attachments
   set document_date = created_at::date
 where document_date is null;

alter table public.attachments alter column document_date set default current_date;
alter table public.attachments alter column document_date set not null;

comment on column public.attachments.document_date is
  'The date on the document, which is not the date it was uploaded - created_at is that. Defaults to today and is editable.';
comment on column public.attachments.sha256 is
  'The file''s content fingerprint, so the same scan cannot be filed twice against one client. Null on rows that predate it, which means nobody asked rather than that it is unique.';

create unique index if not exists attachments_one_copy_per_client
  on public.attachments (client_id, sha256)
  where sha256 is not null and sha256 <> '';

create index if not exists attachments_by_document_date
  on public.attachments (client_id, document_date desc);

-- ── a name and a date can be corrected ──────────────────────
drop policy if exists attachments_update on public.attachments;
create policy attachments_update on public.attachments
  for update using (
    (select public.is_admin())
    or (uploaded_by = (select public.current_staff_id())
        and ((not restricted) or public.can_see_restricted(client_id)))
  )
  with check (
    (select public.is_admin())
    or (uploaded_by = (select public.current_staff_id())
        and ((not restricted) or public.can_see_restricted(client_id)))
  );

-- ─────────────────────────────────────────────────────────────
-- What a client's file looks like to whoever is reading it
--
-- security_invoker is off, so this sees every row and decides what to hand
-- back - which is the whole point. It is gated on is_active_staff() in its
-- own where clause, because without the table's RLS behind it that is the
-- only thing standing there.
-- ─────────────────────────────────────────────────────────────
create or replace view public.client_documents as
select
  a.id,
  a.client_id,
  a.document_date,
  a.created_at,
  /** Redacted with the name: "Guardianship document" says the thing the
      restriction exists to not say. The date survives - a date on its own
      tells nobody anything and it keeps the list in order. */
  case when (not a.restricted) or public.can_see_restricted(a.client_id)
       then a.category else '' end as category,
  a.restricted,
  a.uploaded_by,
  a.uploaded_by_name,
  /** Whether this reader may open it. The screens draw from this rather than
      working it out again. */
  ((not a.restricted) or public.can_see_restricted(a.client_id)) as can_open,
  case when (not a.restricted) or public.can_see_restricted(a.client_id)
       then a.filename else '' end as filename,
  case when (not a.restricted) or public.can_see_restricted(a.client_id)
       then a.note else '' end as note,
  case when (not a.restricted) or public.can_see_restricted(a.client_id)
       then a.storage_path else '' end as storage_path,
  case when (not a.restricted) or public.can_see_restricted(a.client_id)
       then a.mime_type else '' end as mime_type,
  case when (not a.restricted) or public.can_see_restricted(a.client_id)
       then a.size_bytes else null end as size_bytes,
  a.auth_id,
  a.form_id
from public.attachments a
where (select public.is_active_staff());

comment on view public.client_documents is
  'A client''s documents as the person reading them may see them: a restricted file they may not open comes back with its name, note and path blank and can_open false, so they can tell an empty file apart from one they cannot see. The table itself still refuses them the row.';

revoke all on public.client_documents from anon, authenticated;
grant select on public.client_documents to authenticated;

-- ─────────────────────────────────────────────────────────────
-- And what happened to one
--
-- The owner asked for deletes to be logged. Edits are logged with them: the
-- name and the date are editable now, and "who changed the date on this" is
-- the same question as "who removed it".
--
-- Admin reads it. Not every member of staff, because the filename of a
-- restricted document is exactly what the redaction above exists to withhold,
-- and a log that quotes it would hand it back.
-- ─────────────────────────────────────────────────────────────
create table if not exists public.client_document_events (
  id            uuid primary key default gen_random_uuid(),
  seq           bigserial,
  at            timestamptz not null default now(),
  attachment_id uuid,
  client_id     uuid references public.clients(id) on delete cascade,
  filename      text not null default '',
  category      text not null default '',
  restricted    boolean not null default false,
  action        text not null check (action in ('Added', 'Edited', 'Removed')),
  changes       jsonb not null default '{}'::jsonb,
  staff_id      uuid references public.staff(id) on delete set null,
  staff_name    text not null default ''
);
create index if not exists client_document_events_client
  on public.client_document_events (client_id, seq desc);

comment on table public.client_document_events is
  'What has happened to a client''s documents: added, renamed, redated or removed, and by whom. Admin reads it - it quotes filenames, which is what the redaction on client_documents withholds.';

alter table public.client_document_events enable row level security;

drop policy if exists client_document_events_read on public.client_document_events;
create policy client_document_events_read on public.client_document_events
  for select using ((select public.is_admin()));

revoke all on public.client_document_events from anon, authenticated;
grant select on public.client_document_events to authenticated;
select public.apply_system_read_only('client_document_events');

create or replace function public.client_document_events_append_only()
returns trigger language plpgsql as $$
begin
  raise exception 'The document log is a record; it is added to, never changed or removed.'
    using errcode = 'insufficient_privilege';
end;
$$;

drop trigger if exists client_document_events_append_only on public.client_document_events;
create trigger client_document_events_append_only
  before update or delete on public.client_document_events
  for each row execute function public.client_document_events_append_only();

-- ── written by the database, whatever makes the change ──────
create or replace function public.client_document_log()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  k_watched constant text[] := array['filename', 'document_date', 'category', 'restricted', 'note'];
  v_old     jsonb := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) else '{}'::jsonb end;
  v_new     jsonb := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) else '{}'::jsonb end;
  v_changes jsonb := '{}'::jsonb;
  v_key     text;
  v_row     public.attachments;
  v_me      uuid := public.current_staff_id();
  v_name    text;
begin
  v_row := case when tg_op = 'DELETE' then old else new end;

  if tg_op = 'UPDATE' then
    foreach v_key in array k_watched loop
      if (v_old -> v_key) is distinct from (v_new -> v_key) then
        v_changes := v_changes || jsonb_build_object(v_key,
          jsonb_build_object('from', v_old -> v_key, 'to', v_new -> v_key));
      end if;
    end loop;
    -- A save that moved none of the fields a person edits is not news.
    if v_changes = '{}'::jsonb then
      return null;
    end if;
  end if;

  select name into v_name from public.staff where id = v_me;

  insert into public.client_document_events
    (attachment_id, client_id, filename, category, restricted, action, changes, staff_id, staff_name)
  values (v_row.id, v_row.client_id, coalesce(v_row.filename, ''), coalesce(v_row.category, ''),
          coalesce(v_row.restricted, false),
          case tg_op when 'INSERT' then 'Added' when 'DELETE' then 'Removed' else 'Edited' end,
          v_changes, v_me, coalesce(v_name, 'the system'));
  return null;
end;
$$;

comment on function public.client_document_log is
  'Records a client document being added, edited or removed, with who did it. A trigger rather than a line in the upload screen, because the agent and the filing rules write this table too.';

drop trigger if exists attachments_log on public.attachments;
create trigger attachments_log
  after insert or update or delete on public.attachments
  for each row execute function public.client_document_log();
