-- A message can name a client, and be filed on one
--
-- Three things the owner asked for on 30 October, which are one change to
-- `post_message` and one function beside it:
--
--   Typing # and a name puts a client chip in the message. The client is
--   recorded as a reference, not as text, so the client's own record can say
--   "mentioned in Team chat" and link to the thread - and the words stay in
--   the thread, because a message about somebody is not a note about them
--   until a person decides it is.
--
--   "File to client" turns a message into a note on that client, with one of
--   the eight categories chosen. Which is what "contact-log entry with
--   category" has to mean: `contact_log` is the counselor contact log and has
--   no category, and the thing on a client's record that carries one of the
--   eight and feeds the monthly report is `notes`. The message stays in the
--   thread either way; filing copies it onto the record rather than moving it.
--
--   A rate limit per person.
--
-- `post_message` gains a parameter, so the old four-argument function is
-- dropped rather than replaced. A defaulted parameter does not extend a
-- function in Postgres - it makes a second one, which arrives with whatever
-- grants a new function gets and leaves four-argument calls ambiguous between
-- the two. That has happened on this system before.

alter table public.messages
  add column if not exists client_mentions uuid[] not null default '{}'::uuid[];

comment on column public.messages.client_mentions is
  'Clients named in this message with a # chip. References, so the client record can link to the thread without copying what was said (0274).';

-- ─────────────────────────────────────────────────────────────
-- How much one person may send
--
-- Not a guess at what is polite: a human typing cannot reach twenty messages
-- in a minute, and a loop in a browser tab reaches it immediately. The hourly
-- figure is the one that catches something slower that is still not a person.
-- ─────────────────────────────────────────────────────────────
create or replace function public.chat_rate_limit()
returns table (per_minute integer, per_hour integer)
language sql immutable as $$ select 20, 300 $$;

revoke all on function public.chat_rate_limit() from anon, authenticated;
grant execute on function public.chat_rate_limit() to authenticated;

-- ─────────────────────────────────────────────────────────────
-- Sending one
-- ─────────────────────────────────────────────────────────────
drop function if exists public.post_message(uuid, text, jsonb, uuid[]);

create or replace function public.post_message(
  p_conversation uuid,
  p_body         text,
  p_attachments  jsonb default '[]'::jsonb,
  p_mentions     uuid[] default '{}'::uuid[],
  p_clients      uuid[] default '{}'::uuid[]
)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_me         uuid := public.current_staff_id();
  v_name       text;
  v_kind       text;
  v_client     uuid;
  v_id         uuid;
  v_seq        bigint;
  v_item       jsonb;
  v_ref        uuid;
  v_owner      uuid;
  v_restricted boolean;
  v_blocked    text;
  v_mentions   uuid[];
  v_clients    uuid[];
  v_minute     integer;
  v_hour       integer;
  v_limits     record;
begin
  if v_me is null or not public.is_active_staff() then
    raise exception 'Only staff send messages.' using errcode = 'insufficient_privilege';
  end if;
  select kind, client_id into v_kind, v_client from public.conversations where id = p_conversation and archived_at is null;
  if v_kind is null then
    raise exception 'That conversation is not there, or has been archived.' using errcode = 'check_violation';
  end if;
  if v_kind <> 'internal' then
    raise exception 'A text or web chat is answered from its own screen, where its rules are checked.' using errcode = 'check_violation';
  end if;
  if not public.is_conversation_participant(p_conversation) then
    raise exception 'You are not in that conversation.' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(btrim(p_body), '') = '' and coalesce(jsonb_array_length(p_attachments), 0) = 0 then
    raise exception 'The message is empty.' using errcode = 'check_violation';
  end if;
  if length(p_body) > 8000 then
    raise exception 'That message is too long - 8,000 characters at most.' using errcode = 'check_violation';
  end if;
  if jsonb_typeof(coalesce(p_attachments, '[]'::jsonb)) <> 'array'
     or jsonb_array_length(coalesce(p_attachments, '[]'::jsonb)) > 5 then
    raise exception 'Five attachments at most.' using errcode = 'check_violation';
  end if;

  -- ── how fast ─────────────────────────────────────────────
  -- Counted over what this person has actually sent rather than held in a
  -- counter somewhere, so it is right after a restart and cannot drift.
  select * into v_limits from public.chat_rate_limit();
  select count(*) filter (where created_at > now() - interval '1 minute'),
         count(*) filter (where created_at > now() - interval '1 hour')
    into v_minute, v_hour
    from public.messages
   where sender_staff_id = v_me and sender_kind = 'staff';
  if v_minute >= v_limits.per_minute then
    raise exception 'That is % messages in a minute. Wait a moment.', v_minute
      using errcode = 'check_violation';
  end if;
  if v_hour >= v_limits.per_hour then
    raise exception 'That is % messages in an hour. Something is sending on your behalf - say so in Admin.', v_hour
      using errcode = 'check_violation';
  end if;

  -- ── the attachments, one at a time ───────────────────────
  for v_item in select * from jsonb_array_elements(coalesce(p_attachments, '[]'::jsonb)) loop
    -- Something that is not an id at all is a bad reference, not a database
    -- error: it gets the same plain refusal as a reference to nothing.
    begin
      v_ref := nullif(v_item ->> 'id', '')::uuid;
    exception when invalid_text_representation then
      v_ref := null;
    end;
    if v_ref is null or (v_item ->> 'kind') not in ('client_file', 'form', 'chat_file') then
      raise exception 'An attachment is a document on a client''s record, a form, or a file sent in this thread.'
        using errcode = 'check_violation';
    end if;

    -- A file dropped in the thread (0273). Nobody's client, so there is no
    -- tier to check and nothing to compare against the thread's client - but
    -- it does have to be a file from *this* thread.
    if v_item ->> 'kind' = 'chat_file' then
      if not exists (
        select 1 from public.chat_files f
         where f.id = v_ref and f.conversation_id = p_conversation
      ) then
        raise exception 'That file was not sent in this thread.' using errcode = 'no_data_found';
      end if;
      continue;
    end if;

    if v_item ->> 'kind' = 'client_file' then
      select a.client_id, a.restricted into v_owner, v_restricted
        from public.attachments a where a.id = v_ref;
    else
      select f.client_id, f.sensitive into v_owner, v_restricted
        from public.forms f where f.id = v_ref;
    end if;

    if v_owner is null then
      raise exception 'That document is not on a client''s record.' using errcode = 'no_data_found';
    end if;
    -- In a thread about a client it is that client's document or nobody's.
    if v_client is not null and v_owner <> v_client then
      raise exception 'That document belongs to another client. A thread about one client carries that client''s documents.'
        using errcode = 'check_violation';
    end if;

    if v_restricted then
      if not public.can_see_restricted(v_owner) then
        raise exception 'That is a restricted document, and it is not yours to send.' using errcode = 'insufficient_privilege';
      end if;
      select string_agg(s.name, ', ' order by s.name) into v_blocked
        from public.conversation_participants p
        join public.staff s on s.id = p.staff_id
       where p.conversation_id = p_conversation and p.left_at is null and p.staff_id <> v_me
         and not public.can_staff_see_restricted(p.staff_id, v_owner);
      if v_blocked is not null then
        raise exception
          'That document is restricted and % cannot open it, so it cannot be attached here. Restricted documents are for Admin, Intake & Client Reports, and the staff member the client is assigned to. Send a link to the record instead.',
          v_blocked
          using errcode = 'insufficient_privilege';
      end if;
    end if;
  end loop;

  -- A mention is of somebody in the conversation; anybody else is just a name.
  select coalesce(array_agg(distinct m), '{}'::uuid[]) into v_mentions
    from unnest(coalesce(p_mentions, '{}'::uuid[])) m
   where exists (select 1 from public.conversation_participants p
                  where p.conversation_id = p_conversation and p.staff_id = m and p.left_at is null);

  -- A # chip is of a client on file. Five at most: a message naming the whole
  -- caseload is a report, and it would put a line on every one of those
  -- records.
  select coalesce(array_agg(distinct c), '{}'::uuid[]) into v_clients
    from unnest(coalesce(p_clients, '{}'::uuid[])) c
   where exists (select 1 from public.clients cl where cl.id = c);
  if array_length(v_clients, 1) > 5 then
    raise exception 'Five clients at most in one message.' using errcode = 'check_violation';
  end if;

  select name into v_name from public.staff where id = v_me;
  insert into public.messages (conversation_id, sender_kind, sender_staff_id, sender_label, body,
                               attachments, mentions, client_mentions)
  values (p_conversation, 'staff', v_me, coalesce(v_name, ''), p_body,
          coalesce(p_attachments, '[]'::jsonb), v_mentions, v_clients)
  returning id, seq into v_id, v_seq;

  update public.conversations set last_message_at = now(), last_seq = v_seq where id = p_conversation;
  -- The sender has read their own message.
  insert into public.read_receipts (conversation_id, staff_id, last_read_seq, read_at)
  values (p_conversation, v_me, v_seq, now())
  on conflict (conversation_id, staff_id) do update
    set last_read_seq = greatest(public.read_receipts.last_read_seq, excluded.last_read_seq), read_at = now();
  return v_id;
end $$;

revoke all on function public.post_message(uuid, text, jsonb, uuid[], uuid[]) from anon, authenticated;
grant execute on function public.post_message(uuid, text, jsonb, uuid[], uuid[]) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- Filing a message on a client
--
-- A note, with one of the eight categories, on the client's record. Not a
-- move: the message stays in the thread, because the thread is what happened
-- and the note is what the practice decided was worth keeping about a client.
--
-- `notes.category` is not defaulted here even though 0266 would fill it in
-- from the client's stage. Somebody filing a message has the category in front
-- of them and the stage is a guess at it - and 'Personal' is narrowed to Admin
-- and Case Manager by a trigger, which is a decision nobody should make by
-- omission.
-- ─────────────────────────────────────────────────────────────
create or replace function public.file_message_to_client(
  p_message  uuid,
  p_client   uuid,
  p_category text
)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_me     uuid := public.current_staff_id();
  v_name   text;
  v_msg    public.messages;
  v_sender text;
  v_note   uuid;
begin
  if v_me is null or not public.is_active_staff() then
    raise exception 'Only staff file a message on a record.' using errcode = 'insufficient_privilege';
  end if;

  select * into v_msg from public.messages where id = p_message;
  if v_msg.id is null then
    raise exception 'That message is not there.' using errcode = 'no_data_found';
  end if;
  if not public.is_conversation_participant(v_msg.conversation_id) then
    raise exception 'You are not in that conversation.' using errcode = 'insufficient_privilege';
  end if;
  if v_msg.removed_at is not null then
    raise exception 'That message was taken down. Nothing is filed from it.' using errcode = 'check_violation';
  end if;
  if coalesce(btrim(v_msg.body), '') = '' then
    raise exception 'There are no words in that message to file. File the file instead.'
      using errcode = 'check_violation';
  end if;
  if not exists (select 1 from public.clients where id = p_client) then
    raise exception 'That client is not on file.' using errcode = 'check_violation';
  end if;
  if coalesce(btrim(p_category), '') = '' then
    raise exception 'Say which service this is about.' using errcode = 'check_violation';
  end if;

  select name into v_name from public.staff where id = v_me;
  v_sender := coalesce(nullif(v_msg.sender_label, ''), 'a colleague');

  -- Whose words they are is part of the note, because the person reading it in
  -- six months is not the person who filed it.
  insert into public.notes (client_id, staff_id, staff_name, text, type, category, at)
  values (p_client, v_me, coalesce(v_name, ''),
          v_sender || ' in Team chat: ' || btrim(v_msg.body),
          'General', btrim(p_category), public.practice_today())
  returning id into v_note;

  return v_note;
end $$;

revoke all on function public.file_message_to_client(uuid, uuid, text) from anon, authenticated;
grant execute on function public.file_message_to_client(uuid, uuid, text) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- Filing a dropped file on a client
--
-- The bytes are copied into the client's own bucket by the screen - storage is
-- not something SQL can copy - and this records what landed there. Which is
-- the same division as every other upload on this system: the browser moves
-- the file, a function checks the rules and writes the row.
-- ─────────────────────────────────────────────────────────────
create or replace function public.file_chat_file_to_client(
  p_file     uuid,
  p_client   uuid,
  p_path     text,
  p_category text
)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_me   uuid := public.current_staff_id();
  v_name text;
  v_file public.chat_files;
  v_id   uuid;
begin
  if v_me is null or not public.is_active_staff() then
    raise exception 'Only staff file a document on a record.' using errcode = 'insufficient_privilege';
  end if;

  select * into v_file from public.chat_files where id = p_file;
  if v_file.id is null then
    raise exception 'That file is not there.' using errcode = 'no_data_found';
  end if;
  if not public.is_conversation_participant(v_file.conversation_id) then
    raise exception 'You are not in that conversation.' using errcode = 'insufficient_privilege';
  end if;
  if not exists (select 1 from public.clients where id = p_client) then
    raise exception 'That client is not on file.' using errcode = 'check_violation';
  end if;
  if coalesce(btrim(p_path), '') = '' then
    raise exception 'Nothing was copied to the record.' using errcode = 'check_violation';
  end if;

  select name into v_name from public.staff where id = v_me;
  insert into public.attachments (client_id, storage_path, filename, mime_type, size_bytes,
                                  category, note, uploaded_by, uploaded_by_name, source)
  values (p_client, p_path, v_file.filename, v_file.mime_type, v_file.size_bytes,
          coalesce(nullif(btrim(p_category), ''), 'Other'),
          'Sent in Team chat by ' || coalesce(nullif(v_file.uploaded_by_name, ''), 'a colleague'),
          v_me, coalesce(v_name, ''), 'Staff')
  returning id into v_id;

  return v_id;
end $$;

revoke all on function public.file_chat_file_to_client(uuid, uuid, text, text) from anon, authenticated;
grant execute on function public.file_chat_file_to_client(uuid, uuid, text, text) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- Mentioned in Team chat
--
-- A link, never the words. The owner's rule, and the same one the pop-up
-- follows: a message may be about a client and whoever is looking at the
-- screen may not be somebody who should read it. What the record says is that
-- a thread named this person, when, and who was talking.
-- ─────────────────────────────────────────────────────────────
create or replace view public.client_chat_mentions as
select m.id            as message_id,
       c.id            as conversation_id,
       cl.id           as client_id,
       m.created_at,
       m.sender_label,
       coalesce(nullif(c.title, ''), 'a direct message') as thread
  from public.messages m
  join public.conversations c on c.id = m.conversation_id
  cross join lateral unnest(m.client_mentions) as cl(id)
 where m.removed_at is null
   and c.kind = 'internal';

alter view public.client_chat_mentions set (security_invoker = true);

-- A view arrives writable in this project, and this one reads messages.
revoke all on public.client_chat_mentions from authenticated;
revoke all on public.client_chat_mentions from anon;
grant select on public.client_chat_mentions to authenticated;
