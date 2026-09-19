-- Zion Vocational Rehab CRM — the messaging foundation (0104)
--
-- What has to hold, each tried from the direction that would break it:
--
--   A staff conversation is read by its participants and nobody else; Admin
--   also reads one about a client, but not a private one between colleagues -
--   though Admin can see who is in it. A text or web conversation is the
--   team's. Nobody writes a message, a membership or a receipt directly; a
--   staff message goes only into a staff conversation its sender is in.
--   Unread counts move with reading, and nobody marks somebody else's.
--   Presence says online, away or offline and nothing more; the heartbeat's
--   time is its owner's alone.
--   A conversation about a client goes with the client, and into their file.
--   Live delivery carries messages; nobody signed out reads any of it.
--
-- Uses made-up staff and a made-up client (ZZ). Runs inside a transaction
-- that is rolled back.

begin;

do $$
declare
  v_adm_uid uuid;
  v_a uuid; v_a_uid uuid := gen_random_uuid();
  v_b uuid; v_b_uid uuid := gen_random_uuid();
  v_c uuid; v_c_uid uuid := gen_random_uuid();
  v_client uuid;
  v_gone uuid;
  v_gone_conv uuid;
  v_dm uuid; v_about uuid; v_sms uuid;
  v_msg uuid; v_seq bigint;
  v_n integer;
  v_status text;
  v_bundle jsonb;
  failures text[] := '{}';
begin
  select user_id into v_adm_uid from public.staff where role = 'Admin' and active and user_id is not null order by created_at, id limit 1;

  insert into public.staff (name, email, role, active) values ('ZZ Chat A', 'zz-chat-a@example.test', 'Job Search', true) returning id into v_a;
  insert into public.staff (name, email, role, active) values ('ZZ Chat B', 'zz-chat-b@example.test', 'Job Search', true) returning id into v_b;
  insert into public.staff (name, email, role, active) values ('ZZ Chat C', 'zz-chat-c@example.test', 'Reports', true) returning id into v_c;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_a_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-chat-a@example.test', '{}', '{}', now(), now()),
         (v_b_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-chat-b@example.test', '{}', '{}', now(), now()),
         (v_c_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-chat-c@example.test', '{}', '{}', now(), now());
  insert into public.clients (name, stage, status) values ('ZZ Chat Client', 'Intake', 'Active') returning id into v_client;

  -- A thread about the client between A and B, and the team's text thread.
  insert into public.conversations (kind, title, client_id, created_by) values ('internal', 'About ZZ', v_client, v_a) returning id into v_about;
  insert into public.conversation_participants (conversation_id, staff_id) values (v_about, v_a), (v_about, v_b);
  insert into public.messages (conversation_id, sender_kind, sender_staff_id, sender_label, body)
  values (v_about, 'staff', v_a, 'ZZ Chat A', 'ZZ about the client');
  insert into public.conversations (kind, client_id, external_address) values ('sms', v_client, '+18015550100') returning id into v_sms;
  insert into public.messages (conversation_id, sender_kind, body, status) values (v_sms, 'client', 'ZZ text in', 'received');

  perform set_config('role', 'authenticated', true);

  -- ── A messages B ───────────────────────────────────────────
  perform set_config('request.jwt.claims', json_build_object('sub', v_a_uid, 'role', 'authenticated')::text, true);
  v_dm := public.start_direct_conversation(v_b);
  if public.start_direct_conversation(v_b) <> v_dm then
    failures := failures || 'FAILED: a second direct message to the same person opened a second conversation'::text;
  end if;
  v_msg := public.post_message(v_dm, 'ZZ hello B');
  begin
    perform public.post_message(v_sms, 'ZZ a text from the wrong door');
    failures := failures || 'FAILED: a text was sent through the staff-message door, round its consent and hours checks'::text;
  exception when check_violation then null;
  end;
  -- Attaching arrived with staff chat (0106), which checks every reference
  -- against the people in the conversation. What holds here is what held
  -- before it: an attachment that is not a document on somebody's record does
  -- not go, whether it names nothing or is not an id at all.
  begin
    perform public.post_message(v_dm, 'ZZ', '[{"kind":"client_file","id":"x"}]'::jsonb);
    failures := failures || 'FAILED: an attachment that is not even an id went through'::text;
  exception when check_violation then null;
  end;
  begin
    perform public.post_message(v_dm, 'ZZ', jsonb_build_array(jsonb_build_object('kind', 'client_file', 'id', gen_random_uuid())));
    failures := failures || 'FAILED: an attachment pointing at no document went through'::text;
  exception when no_data_found then null;
  end;
  begin
    insert into public.messages (conversation_id, sender_kind, sender_staff_id, body) values (v_dm, 'staff', v_a, 'ZZ direct');
    failures := failures || 'FAILED: a message was written directly'::text;
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.conversation_participants (conversation_id, staff_id) values (v_about, v_c);
    failures := failures || 'FAILED: somebody added a person to a conversation directly'::text;
  exception when insufficient_privilege then null;
  end;

  -- ── B reads it ─────────────────────────────────────────────
  perform set_config('request.jwt.claims', json_build_object('sub', v_b_uid, 'role', 'authenticated')::text, true);
  select unread into v_n from public.my_unread() where conversation_id = v_dm;
  if coalesce(v_n, 0) <> 1 then
    failures := failures || format('FAILED: B had %s unread, not 1', v_n)::text;
  end if;
  select seq into v_seq from public.messages where id = v_msg;
  perform public.mark_read(v_dm, v_seq);
  select unread into v_n from public.my_unread() where conversation_id = v_dm;
  if coalesce(v_n, -1) <> 0 then
    failures := failures || 'FAILED: reading did not clear the unread count'::text;
  else
    raise notice 'ok  a direct message is one conversation, arrives unread, and reading clears it';
  end if;

  -- ── C, who is in neither ───────────────────────────────────
  perform set_config('request.jwt.claims', json_build_object('sub', v_c_uid, 'role', 'authenticated')::text, true);
  select count(*) into v_n from public.messages where conversation_id in (v_dm, v_about);
  if v_n <> 0 then
    failures := failures || format('FAILED: somebody outside two staff conversations read %s of their messages', v_n)::text;
  end if;
  begin
    perform public.post_message(v_dm, 'ZZ butting in');
    failures := failures || 'FAILED: somebody posted into a conversation they are not in'::text;
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.mark_read(v_dm, 999999);
    failures := failures || 'FAILED: somebody marked a conversation they are not in as read'::text;
  exception when insufficient_privilege then null;
  end;
  select count(*) into v_n from public.messages where conversation_id = v_sms;
  if v_n <> 1 then
    failures := failures || 'FAILED: the team text thread was not readable by a member of staff'::text;
  else
    raise notice 'ok  a staff conversation is its participants''; a text thread is the team''s';
  end if;

  -- ── Admin ──────────────────────────────────────────────────
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);
  if (select count(*) from public.messages where conversation_id = v_about) <> 1 then
    failures := failures || 'FAILED: Admin could not read a staff thread about a client'::text;
  end if;
  if (select count(*) from public.messages where conversation_id = v_dm) <> 0 then
    failures := failures || 'FAILED: Admin read a private conversation between colleagues'::text;
  end if;
  if (select count(*) from public.conversation_participants where conversation_id = v_dm) <> 2 then
    failures := failures || 'FAILED: Admin could not see who is in a conversation'::text;
  else
    raise notice 'ok  Admin reads threads about a client, not private ones, and sees who is in each';
  end if;

  -- ── presence ───────────────────────────────────────────────
  perform set_config('request.jwt.claims', json_build_object('sub', v_a_uid, 'role', 'authenticated')::text, true);
  perform public.presence_heartbeat('online');
  begin
    perform public.presence_heartbeat('typing');
    failures := failures || 'FAILED: presence took a state other than online or away'::text;
  exception when check_violation then null;
  end;
  perform set_config('request.jwt.claims', json_build_object('sub', v_b_uid, 'role', 'authenticated')::text, true);
  if exists (select 1 from public.staff_presence where staff_id = v_a) then
    failures := failures || 'FAILED: somebody read a colleague''s heartbeat time'::text;
  end if;
  select status into v_status from public.staff_presence_status() where staff_id = v_a;
  if v_status <> 'online' or exists (select 1 from public.staff_presence_status() where status not in ('online', 'away', 'offline')) then
    failures := failures || format('FAILED: presence said %s', v_status)::text;
  end if;
  if pg_get_function_result('public.staff_presence_status()'::regprocedure) <> 'TABLE(staff_id uuid, status text)' then
    failures := failures || 'FAILED: presence returns more than who and which word'::text;
  else
    raise notice 'ok  presence is online, away or offline - one word, and the time is its owner''s alone';
  end if;

  -- ── with the client ────────────────────────────────────────
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);
  v_bundle := public.records_request_bundle(v_client, 'ZZ verify');
  if jsonb_array_length(coalesce(v_bundle -> 'conversations', '[]'::jsonb)) <> 2
     or not (v_bundle -> 'conversations')::text like '%ZZ about the client%' then
    failures := failures || 'FAILED: the client''s conversations were not in their records bundle'::text;
  end if;
  -- A client removed (the retention module decides when): a second one, whose
  -- file has not been produced - producing it writes to the access log, which
  -- rightly never lets go.
  perform set_config('role', 'postgres', true);
  insert into public.clients (name, stage, status) values ('ZZ Chat Gone', 'Closed', 'Closed') returning id into v_gone;
  insert into public.conversations (kind, client_id, external_address) values ('sms', v_gone, '+18015550199') returning id into v_gone_conv;
  insert into public.messages (conversation_id, sender_kind, body, status) values (v_gone_conv, 'client', 'ZZ gone', 'received');
  delete from public.clients where id = v_gone;
  if exists (select 1 from public.conversations where id = v_gone_conv)
     or exists (select 1 from public.messages where conversation_id = v_gone_conv) then
    failures := failures || 'FAILED: a conversation about a client outlived the client'::text;
  else
    raise notice 'ok  a conversation about a client goes into their file, and goes with them';
  end if;

  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'messages') then
    failures := failures || 'FAILED: messages are not delivered live'::text;
  end if;
  perform set_config('request.jwt.claims', '', true);
  if has_table_privilege('anon', 'public.messages', 'select')
     or has_table_privilege('anon', 'public.conversations', 'select')
     or has_function_privilege('anon', 'public.staff_presence_status()', 'execute')
     or has_function_privilege('authenticated', 'public.messages_digest_due()', 'execute') then
    failures := failures || 'FAILED: somebody not signed in, or not the digest, can reach messages'::text;
  else
    raise notice 'ok  messages go out live, and nobody signed out reads any of them';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- MESSAGING FOUNDATION VERIFIED ---';
end $$;

rollback;
