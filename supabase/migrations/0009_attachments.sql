-- Zion Vocational Rehab CRM — 0009 client file attachments
--
-- Signed USOR PDFs, work schedules, authorizations and intakes. The kickoff
-- puts these under Supabase Storage, per client.
--
-- Two things hold the security together:
--   * The bucket is private. Nothing is reachable by URL without a session.
--   * A stored object is readable only if its row in public.attachments says
--     the reader may see it. The metadata table is the authority, so a
--     restricted document follows the same rule as DOB, intake and USOR 94/98:
--     Admin, Intake & Reports, or the client's assigned staff member.

-- ─────────────────────────────────────────────────────────────
-- Metadata
-- ─────────────────────────────────────────────────────────────
create table public.attachments (
  id            uuid primary key default gen_random_uuid(),
  client_id     uuid not null references public.clients(id) on delete cascade,
  storage_path  text not null unique,
  filename      text not null,
  mime_type     text not null default '',
  size_bytes    bigint not null default 0,
  category      text not null default 'Other' check (category in
                  ('Signed USOR form','Work schedule','Authorization',
                   'Signed intake','Employer verification','Invoice','Other')),
  restricted    boolean not null default false,
  note          text not null default '',
  form_id       uuid references public.forms(id) on delete set null,
  auth_id       uuid references public.authorizations(id) on delete set null,
  uploaded_by   uuid references public.staff(id) on delete set null,
  uploaded_by_name text not null default '',
  created_at    timestamptz not null default now()
);
create index attachments_client_idx on public.attachments (client_id, created_at desc);
create index attachments_form_idx on public.attachments (form_id) where form_id is not null;

alter table public.attachments enable row level security;

-- A restricted document follows the restricted tier. Everything else is
-- visible to any active staff member, like the client record it belongs to.
create policy attachments_read on public.attachments
  for select to authenticated
  using (
    public.is_active_staff()
    and (not restricted or public.can_see_restricted(client_id))
  );

create policy attachments_insert on public.attachments
  for insert to authenticated
  with check (
    public.is_active_staff()
    and (not restricted or public.can_see_restricted(client_id))
    and uploaded_by is not distinct from public.current_staff_id()
  );

-- Documents are evidence. Correcting a mistake means uploading the right file
-- and removing the wrong one, not editing what a stored file claims to be.
create policy attachments_delete on public.attachments
  for delete to authenticated
  using (
    public.is_admin()
    or (uploaded_by = public.current_staff_id() and not restricted)
    or (uploaded_by = public.current_staff_id() and public.can_see_restricted(client_id))
  );

-- ─────────────────────────────────────────────────────────────
-- Bucket
-- 25 MB is generous for a scanned USOR form and small enough that nobody
-- parks a video in the client record.
-- ─────────────────────────────────────────────────────────────
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'client-files',
  'client-files',
  false,
  26214400,
  array[
    'application/pdf',
    'image/jpeg', 'image/png', 'image/heic', 'image/webp', 'image/tiff',
    'application/msword',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'application/vnd.ms-excel',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'text/plain', 'text/csv'
  ]
)
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- ─────────────────────────────────────────────────────────────
-- Object access
--
-- Reading joins back to public.attachments, so the restricted tier decides
-- who can fetch the bytes — not just who can see the row. Without this, a
-- signed URL for a restricted intake would be obtainable by any staff member.
-- ─────────────────────────────────────────────────────────────
drop policy if exists "zion read client files" on storage.objects;
create policy "zion read client files" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'client-files'
    and exists (
      select 1 from public.attachments a
       where a.storage_path = storage.objects.name
         and (not a.restricted or public.can_see_restricted(a.client_id))
    )
  );

-- Uploads land under clients/<client id>/ and are recorded immediately after.
drop policy if exists "zion upload client files" on storage.objects;
create policy "zion upload client files" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'client-files'
    and public.is_active_staff()
    and (storage.foldername(name))[1] = 'clients'
    and array_length(storage.foldername(name), 1) = 2
  );

drop policy if exists "zion delete client files" on storage.objects;
create policy "zion delete client files" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'client-files'
    and (
      public.is_admin()
      or exists (
        select 1 from public.attachments a
         where a.storage_path = storage.objects.name
           and a.uploaded_by = public.current_staff_id()
      )
    )
  );

-- ─────────────────────────────────────────────────────────────
-- Removing the metadata removes the file. Otherwise a deleted document would
-- linger in storage, retrievable, while the record says it is gone.
-- ─────────────────────────────────────────────────────────────
create or replace function public.delete_attachment_object()
returns trigger language plpgsql security definer set search_path = public, storage as $$
begin
  delete from storage.objects
   where bucket_id = 'client-files' and name = old.storage_path;
  return old;
end;
$$;

create trigger attachments_delete_object
  after delete on public.attachments
  for each row execute function public.delete_attachment_object();
