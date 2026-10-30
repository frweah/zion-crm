-- A file dropped in a thread
--
-- 0106 settled how a document gets into a conversation: by reference, never a
-- second copy, so it keeps its own tier and its own retention and cannot be
-- attached where somebody in the thread could not open it anyway. The owner
-- kept that rule on 30 October and added the missing half - dragging or
-- pasting a file uploads it and then attaches it, by reference, like anything
-- else.
--
-- It needs somewhere to go. `attachments.client_id` is `not null` and its
-- storage policy joins through it, so a file that is nobody's client's cannot
-- live there; `staff_files` is an HR record and belongs to one person. So
-- `chat_files` is the one table this needed, and it is not one of the four the
-- owner said not to build - there is no second conversation, no second
-- message, no second membership. A dropped file is internal: it is on the
-- thread, never on a client, until somebody files it on one deliberately.
--
-- Same bucket rules as a client file: the twelve types the practice accepts
-- and 50 MB, which is the allow-list the brief asks for rather than a second
-- list that would drift from it.

-- ─────────────────────────────────────────────────────────────
-- Where the bytes go
-- ─────────────────────────────────────────────────────────────
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('chat-files', 'chat-files', false, 52428800, array[
  'application/pdf', 'image/jpeg', 'image/png', 'image/heic', 'image/webp',
  'image/tiff', 'application/msword',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'application/vnd.ms-excel',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'text/plain', 'text/csv'])
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- ─────────────────────────────────────────────────────────────
-- Which thread a path is in
--
-- The upload happens before the row describing it exists, so the only thing
-- the insert policy can ask about is the path. `threads/<conversation>/<file>`
-- and nothing else, and a path whose second part is not an id answers null
-- rather than raising - a policy that errors on a bad path is a 500 where a
-- refusal belongs.
-- ─────────────────────────────────────────────────────────────
create or replace function public.thread_in_path(p_name text)
returns uuid
language plpgsql immutable security definer set search_path = public as $$
declare v_parts text[] := storage.foldername(p_name);
begin
  if array_length(v_parts, 1) <> 2 or v_parts[1] <> 'threads' then
    return null;
  end if;
  begin
    return v_parts[2]::uuid;
  exception when invalid_text_representation then
    return null;
  end;
end $$;

revoke all on function public.thread_in_path(text) from anon, authenticated;
grant execute on function public.thread_in_path(text) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- What arrived
-- ─────────────────────────────────────────────────────────────
create table if not exists public.chat_files (
  id               uuid primary key default gen_random_uuid(),
  conversation_id  uuid not null references public.conversations (id) on delete cascade,
  storage_path     text not null unique,
  filename         text not null,
  mime_type        text not null,
  size_bytes       bigint not null check (size_bytes > 0 and size_bytes <= 52428800),
  uploaded_by      uuid references public.staff (id),
  uploaded_by_name text not null default '',
  created_at       timestamptz not null default now()
);

comment on table public.chat_files is
  'A file dropped or pasted into a staff thread. Internal: on the thread, never on a client, until somebody files it on one (0273).';

create index if not exists chat_files_conversation_idx
  on public.chat_files (conversation_id, created_at desc);

alter table public.chat_files enable row level security;

-- Read by the people in the thread, which is the same rule the messages
-- themselves follow.
drop policy if exists chat_files_read on public.chat_files;
create policy chat_files_read on public.chat_files
  for select using ((select public.is_conversation_participant(conversation_id)));

-- Written by `record_chat_file` and nothing else, the way every other write in
-- this part of the system goes through a function that checks the rules once.
revoke all on public.chat_files from authenticated;
revoke all on public.chat_files from anon;
grant select on public.chat_files to authenticated;

select public.apply_system_read_only('chat_files');

-- ─────────────────────────────────────────────────────────────
-- Storage, by the same rules
-- ─────────────────────────────────────────────────────────────
drop policy if exists "zion upload chat files" on storage.objects;
create policy "zion upload chat files" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'chat-files'
    and (select public.is_active_staff())
    and (select public.is_conversation_participant(public.thread_in_path(name)))
  );

drop policy if exists "zion read chat files" on storage.objects;
create policy "zion read chat files" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'chat-files'
    and exists (
      select 1 from public.chat_files f
       where f.storage_path = objects.name
         and public.is_conversation_participant(f.conversation_id)
    )
  );

-- An upload that never became a message is the uploader's to clear away. A
-- file that is in a thread is not: messages are kept, and so is what was sent
-- with them.
drop policy if exists "zion delete chat files" on storage.objects;
create policy "zion delete chat files" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'chat-files'
    and (select public.is_active_staff())
    and not exists (select 1 from public.chat_files f where f.storage_path = objects.name)
  );

-- ─────────────────────────────────────────────────────────────
-- Recording one
--
-- The browser uploads to storage itself - a 50 MB file cannot go through a
-- server action, which is the lesson of every upload on this system - and
-- then says what it put there. This is where that is checked: the path has to
-- be in this thread, and the person has to be in it.
-- ─────────────────────────────────────────────────────────────
create or replace function public.record_chat_file(
  p_conversation uuid,
  p_path         text,
  p_filename     text,
  p_mime         text,
  p_size         bigint
)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_me   uuid := public.current_staff_id();
  v_name text;
  v_id   uuid;
begin
  if v_me is null or not public.is_active_staff() then
    raise exception 'Only staff send files.' using errcode = 'insufficient_privilege';
  end if;
  if not public.is_conversation_participant(p_conversation) then
    raise exception 'You are not in that conversation.' using errcode = 'insufficient_privilege';
  end if;
  -- The path says which thread it is in, and it has to be this one. Without
  -- this, a participant of any thread could record a file sitting in another.
  if public.thread_in_path(p_path) is distinct from p_conversation then
    raise exception 'That file is not in this thread.' using errcode = 'check_violation';
  end if;
  if coalesce(btrim(p_filename), '') = '' then
    raise exception 'That file has no name.' using errcode = 'check_violation';
  end if;
  if p_size is null or p_size <= 0 then
    raise exception 'That file is empty.' using errcode = 'check_violation';
  end if;
  if p_size > 52428800 then
    raise exception 'That file is over 50MB - put it on the client''s record and send a link to it.'
      using errcode = 'check_violation';
  end if;
  -- The allow-list is the bucket's, asked rather than copied, so there is one
  -- list of what the practice accepts and not two that drift.
  if not exists (
    select 1 from storage.buckets b
     where b.id = 'chat-files' and p_mime = any (b.allowed_mime_types)
  ) then
    raise exception 'The practice does not take % files. Send a PDF, an image, a document or a spreadsheet.', p_mime
      using errcode = 'check_violation';
  end if;

  select name into v_name from public.staff where id = v_me;
  insert into public.chat_files (conversation_id, storage_path, filename, mime_type, size_bytes,
                                 uploaded_by, uploaded_by_name)
  values (p_conversation, p_path, btrim(p_filename), p_mime, p_size, v_me, coalesce(v_name, ''))
  returning id into v_id;
  return v_id;
end $$;

revoke all on function public.record_chat_file(uuid, text, text, text, bigint) from anon, authenticated;
grant execute on function public.record_chat_file(uuid, text, text, text, bigint) to authenticated;
