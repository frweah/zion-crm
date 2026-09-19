-- Zion Vocational Rehab CRM — staff chat (0106)
--
-- What has to hold, each tried from the direction that would break it:
--
--   A group is the people in it. Somebody outside it cannot read it and
--   cannot write to it, and that includes Admin - a conversation between
--   colleagues is not client information. What Admin can see is who is in it,
--   and Admin can archive it.
--
--   A thread about a client is different, and deliberately: Admin reads it,
--   because a conversation about a client is part of that client's record,
--   the same rule logged mail and texts already follow. It shows on that
--   client's Activity to the people in it and to Admin, and to nobody else.
--
--   Leaving is allowed. What was said stays; the person who left stops
--   reading it.
--
--   A document is attached by reference and never copied. A restricted one
--   cannot be sent to somebody who could not open it, and the refusal says
--   who. A document belonging to another client cannot be dropped into a
--   thread about this one.
--
--   Five minutes to fix a typo, and not a minute more. Your own message can
--   be taken back, and leaves the marker. Somebody else's cannot.
--
--   Search reaches the conversations you are in, and no further.
--
-- Uses made-up staff, clients and documents (ZZ). Runs inside a transaction
-- that is rolled back.

begin;

do $$
declare
  v_admin  uuid; v_admin_uid  uuid := gen_random_uuid();
  v_worker uuid; v_worker_uid uuid := gen_random_uuid();
  v_other  uuid; v_other_uid  uuid := gen_random_uuid();
  v_third  uuid; v_third_uid  uuid := gen_random_uuid();
  v_client uuid;
  v_client_b uuid;
  v_open   uuid;   -- an ordinary document
  v_locked uuid;   -- a restricted one
  v_far    uuid;   -- one belonging to the other client
  v_group  uuid;
  v_thread uuid;
  v_dm     uuid;
  v_msg    uuid;
  v_n      integer;
  v_files  integer;
  v_txt    text;
  failures text[] := '{}';
begin
  insert into public.staff (name, email, role, active) values ('ZZ Chat Admin', 'zz-chat-admin@example.test', 'Admin', true) returning id into v_admin;
  insert into public.staff (name, email, role, active) values ('ZZ Chat Worker', 'zz-chat-worker@example.test', 'Job Search', true) returning id into v_worker;
  insert into public.staff (name, email, role, active) values ('ZZ Chat Other', 'zz-chat-other@example.test', 'Job Search', true) returning id into v_other;
  insert into public.staff (name, email, role, active) values ('ZZ Chat Third', 'zz-chat-third@example.test', 'Job Search', true) returning id into v_third;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_admin_uid,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-chat-admin@example.test',  '{}', '{}', now(), now()),
         (v_worker_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-chat-worker@example.test', '{}', '{}', now(), now()),
         (v_other_uid,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-chat-other@example.test',  '{}', '{}', now(), now()),
         (v_third_uid,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-chat-third@example.test',  '{}', '{}', now(), now());

  insert into public.clients (name, stage, status, assigned_staff_id) values ('ZZ Chat Client', 'Intake', 'Active', v_worker) returning id into v_client;
  insert into public.clients (name, stage, status, assigned_staff_id) values ('ZZ Chat Client Two', 'Intake', 'Active', v_worker) returning id into v_client_b;

  insert into public.attachments (client_id, storage_path, filename, category, restricted)
  values (v_client, 'zz/chat/resume.pdf', 'ZZ resume.pdf', 'Other', false) returning id into v_open;
  insert into public.attachments (client_id, storage_path, filename, category, restricted)
  values (v_client, 'zz/chat/assessment.pdf', 'ZZ assessment.pdf', 'Other', true) returning id into v_locked;
  insert into public.attachments (client_id, storage_path, filename, category, restricted)
  values (v_client_b, 'zz/chat/other-client.pdf', 'ZZ other client.pdf', 'Other', false) returning id into v_far;
  select count(*) into v_files from public.attachments where client_id in (v_client, v_client_b);

  -- ── a group is the people in it ────────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_worker_uid, 'role', 'authenticated')::text, true);

  v_group := public.start_group_conversation('ZZ Case Huddle', array[v_other], null);
  perform public.post_message(v_group, 'ZZ hello the both of us', '[]'::jsonb, '{}'::uuid[]);

  perform set_config('request.jwt.claims', json_build_object('sub', v_other_uid, 'role', 'authenticated')::text, true);
  if not exists (select 1 from public.conversations where id = v_group) then
    failures := failures || 'FAILED: somebody put in a group cannot read it'::text;
  end if;

  -- Admin is not in it, so Admin does not read it.
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin_uid, 'role', 'authenticated')::text, true);
  if exists (select 1 from public.messages where conversation_id = v_group) then
    failures := failures || 'FAILED: Admin read a private conversation between colleagues'::text;
  end if;
  begin
    perform public.post_message(v_group, 'ZZ admin writing in', '[]'::jsonb, '{}'::uuid[]);
    failures := failures || 'FAILED: Admin wrote into a conversation Admin is not in'::text;
  exception when insufficient_privilege then null;
  end;
  -- But Admin can see who is in it.
  select count(*) into v_n from public.conversation_participants where conversation_id = v_group and left_at is null;
  if v_n <> 2 then
    failures := failures || format('FAILED: Admin saw %s of the two people in a group', v_n)::text;
  else
    raise notice 'ok  a group is read and written by the people in it; Admin sees the membership, not the messages';
  end if;

  -- ── attachments, by reference ──────────────────────────────
  perform set_config('request.jwt.claims', json_build_object('sub', v_worker_uid, 'role', 'authenticated')::text, true);
  v_msg := public.post_message(v_group, 'ZZ their resume', jsonb_build_array(jsonb_build_object('kind', 'client_file', 'id', v_open, 'name', 'ZZ resume.pdf')), '{}'::uuid[]);
  if (select attachments -> 0 ->> 'id' from public.messages where id = v_msg) <> v_open::text then
    failures := failures || 'FAILED: an attached document was not carried as a reference to the one on file'::text;
  end if;
  if (select count(*) from public.attachments where client_id in (v_client, v_client_b)) <> v_files then
    failures := failures || 'FAILED: attaching a document made a second copy of it'::text;
  end if;

  -- The restricted one, to somebody who could not open it.
  begin
    perform public.post_message(v_group, 'ZZ the assessment', jsonb_build_array(jsonb_build_object('kind', 'client_file', 'id', v_locked)), '{}'::uuid[]);
    failures := failures || 'FAILED: a restricted document was sent to somebody who cannot open it'::text;
  exception when insufficient_privilege then
    if position('ZZ Chat Other' in sqlerrm) = 0 then
      failures := failures || format('FAILED: the refusal did not say who could not open it: %s', sqlerrm)::text;
    end if;
  end;

  -- Another client's document, in a thread about this one.
  v_thread := public.start_group_conversation('', array[v_third], v_client);
  begin
    perform public.post_message(v_thread, 'ZZ wrong file', jsonb_build_array(jsonb_build_object('kind', 'client_file', 'id', v_far)), '{}'::uuid[]);
    failures := failures || 'FAILED: another client''s document went into a thread about this one'::text;
  exception when check_violation then null;
  end;

  -- The same restricted document where everybody may see it: Admin may.
  v_dm := public.start_direct_conversation(v_admin);
  perform public.post_message(v_dm, 'ZZ the assessment, to Admin', jsonb_build_array(jsonb_build_object('kind', 'client_file', 'id', v_locked)), '{}'::uuid[]);
  raise notice 'ok  documents go by reference, never copied; a restricted one is refused by name, and allowed where everybody may see it';

  -- Somebody who cannot see the restricted document cannot send it either.
  perform set_config('request.jwt.claims', json_build_object('sub', v_other_uid, 'role', 'authenticated')::text, true);
  begin
    perform public.post_message(v_group, 'ZZ passing it on', jsonb_build_array(jsonb_build_object('kind', 'client_file', 'id', v_locked)), '{}'::uuid[]);
    failures := failures || 'FAILED: somebody sent a restricted document they cannot open themselves'::text;
  exception when insufficient_privilege then null;
  end;

  -- ── a thread about a client ────────────────────────────────
  perform set_config('request.jwt.claims', json_build_object('sub', v_worker_uid, 'role', 'authenticated')::text, true);
  perform public.post_message(v_thread, 'ZZ about this client', '[]'::jsonb, '{}'::uuid[]);
  select count(*) into v_n from public.client_activity where client_id = v_client and kind = 'Chat';
  if v_n <> 1 then
    failures := failures || format('FAILED: the thread showed %s times on the client''s Activity for somebody in it', v_n)::text;
  end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_admin_uid, 'role', 'authenticated')::text, true);
  if not exists (select 1 from public.messages where conversation_id = v_thread) then
    failures := failures || 'FAILED: Admin cannot read a conversation about a client'::text;
  end if;
  if (select count(*) from public.client_activity where client_id = v_client and kind = 'Chat') <> 1 then
    failures := failures || 'FAILED: the thread is not on the client''s Activity for Admin'::text;
  end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_other_uid, 'role', 'authenticated')::text, true);
  if exists (select 1 from public.messages where conversation_id = v_thread) then
    failures := failures || 'FAILED: somebody outside the thread read a conversation about a client'::text;
  end if;
  if (select count(*) from public.client_activity where client_id = v_client and kind = 'Chat') <> 0 then
    failures := failures || 'FAILED: a thread showed on the client''s Activity to somebody not in it'::text;
  else
    raise notice 'ok  a thread about a client is on that client''s Activity to the people in it and to Admin, and to nobody else';
  end if;

  -- ── leaving ────────────────────────────────────────────────
  perform public.leave_conversation(v_group);
  if exists (select 1 from public.conversations where id = v_group) then
    failures := failures || 'FAILED: somebody who left a group still reads it'::text;
  end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_worker_uid, 'role', 'authenticated')::text, true);
  select count(*) into v_n from public.messages where conversation_id = v_group;
  if v_n < 2 then
    failures := failures || 'FAILED: somebody leaving took the conversation with them'::text;
  else
    raise notice 'ok  leaving stops the reading and leaves what was said where it was said';
  end if;

  -- ── five minutes ───────────────────────────────────────────
  v_msg := public.post_message(v_thread, 'ZZ teh typo', '[]'::jsonb, '{}'::uuid[]);
  perform public.edit_message(v_msg, 'ZZ the typo');
  if (select body from public.messages where id = v_msg) <> 'ZZ the typo'
     or (select edited_at from public.messages where id = v_msg) is null then
    failures := failures || 'FAILED: a message could not be corrected in the first five minutes'::text;
  end if;

  perform set_config('role', 'postgres', true);
  update public.messages set created_at = now() - interval '10 minutes' where id = v_msg;
  perform set_config('role', 'authenticated', true);
  begin
    perform public.edit_message(v_msg, 'ZZ rewriting history');
    failures := failures || 'FAILED: a message was changed long after it was sent'::text;
  exception when check_violation then null;
  end;

  -- Somebody else's message is not yours to change or remove.
  perform set_config('request.jwt.claims', json_build_object('sub', v_third_uid, 'role', 'authenticated')::text, true);
  begin
    perform public.edit_message(v_msg, 'ZZ putting words in');
    failures := failures || 'FAILED: somebody changed a colleague''s message'::text;
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.remove_message(v_msg);
    failures := failures || 'FAILED: somebody removed a colleague''s message'::text;
  exception when insufficient_privilege then null;
  end;

  perform set_config('request.jwt.claims', json_build_object('sub', v_worker_uid, 'role', 'authenticated')::text, true);
  perform public.remove_message(v_msg);
  if not exists (select 1 from public.messages where id = v_msg and status = 'removed' and removed_at is not null and body = '') then
    failures := failures || 'FAILED: a removed message did not leave the marker'::text;
  else
    raise notice 'ok  five minutes to correct a message, your own to take back, and nobody else''s to touch';
  end if;

  -- ── mentions ───────────────────────────────────────────────
  -- A name typed at somebody not in the conversation is a name, not a mention.
  v_msg := public.post_message(v_thread, 'ZZ @ZZ Chat Other could you look', '[]'::jsonb, array[v_other]);
  if array_length((select mentions from public.messages where id = v_msg), 1) is not null then
    failures := failures || 'FAILED: somebody outside the conversation was mentioned into it'::text;
  end if;
  v_msg := public.post_message(v_thread, 'ZZ @ZZ Chat Third over to you', '[]'::jsonb, array[v_third]);
  if (select mentions from public.messages where id = v_msg) <> array[v_third] then
    failures := failures || 'FAILED: a mention of somebody in the conversation was not recorded'::text;
  else
    raise notice 'ok  a mention reaches somebody in the conversation and nobody outside it';
  end if;

  -- ── search ─────────────────────────────────────────────────
  perform public.post_message(v_thread, 'ZZ needle in the thread', '[]'::jsonb, '{}'::uuid[]);
  select count(*) into v_n from public.search_messages('ZZ needle');
  if v_n <> 1 then
    failures := failures || format('FAILED: search found %s of the one message', v_n)::text;
  end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_other_uid, 'role', 'authenticated')::text, true);
  select count(*) into v_n from public.search_messages('ZZ needle');
  if v_n <> 0 then
    failures := failures || 'FAILED: search reached a conversation the searcher is not in'::text;
  end if;
  -- And a removed message is not searchable.
  perform set_config('request.jwt.claims', json_build_object('sub', v_worker_uid, 'role', 'authenticated')::text, true);
  if exists (select 1 from public.search_messages('ZZ the typo')) then
    failures := failures || 'FAILED: a removed message still turns up in search'::text;
  else
    raise notice 'ok  search reaches the conversations the searcher is in, and does not bring back what was removed';
  end if;

  -- ── archiving ──────────────────────────────────────────────
  perform set_config('request.jwt.claims', json_build_object('sub', v_third_uid, 'role', 'authenticated')::text, true);
  begin
    perform public.archive_conversation(v_thread, true);
    failures := failures || 'FAILED: somebody who neither started the conversation nor is Admin archived it'::text;
  exception when insufficient_privilege then null;
  end;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin_uid, 'role', 'authenticated')::text, true);
  perform public.archive_conversation(v_group, true);
  -- Read back as the database itself: Admin archived a group Admin cannot
  -- read, which is the point - the membership and the switch, not the words.
  perform set_config('role', 'postgres', true);
  if (select archived_at from public.conversations where id = v_group) is null then
    failures := failures || 'FAILED: Admin could not archive a group'::text;
  end if;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_worker_uid, 'role', 'authenticated')::text, true);
  begin
    perform public.post_message(v_group, 'ZZ still talking', '[]'::jsonb, '{}'::uuid[]);
    failures := failures || 'FAILED: an archived conversation still took messages'::text;
  exception when check_violation then null;
  end;
  if not exists (select 1 from public.messages where conversation_id = v_group) then
    failures := failures || 'FAILED: archiving a conversation took its messages away'::text;
  else
    raise notice 'ok  Admin, or whoever started it, archives a conversation; it stops taking messages and keeps the ones it has';
  end if;

  -- ── nobody signed in ───────────────────────────────────────
  perform set_config('request.jwt.claims', '', true);
  if has_function_privilege('anon', 'public.post_message(uuid, text, jsonb, uuid[])', 'execute')
     or has_function_privilege('anon', 'public.search_messages(text, integer)', 'execute')
     or has_function_privilege('anon', 'public.start_group_conversation(text, uuid[], uuid)', 'execute')
     or has_function_privilege('anon', 'public.can_staff_see_restricted(uuid, uuid)', 'execute') then
    failures := failures || 'FAILED: somebody not signed in can work the staff chat'::text;
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- STAFF CHAT VERIFIED ---';
end $$;

rollback;
