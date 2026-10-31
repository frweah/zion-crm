-- Team chat (0272-0275)
--
-- The brief's definition of done, in order, plus the owner's addition:
--
--   A non-member cannot read or write a thread.
--   Inactive staff loses access.
--   There is no delete path.
--   File to client makes the note with the category chosen.
--   A hidden message is invisible to anybody but Admin.
--   Files are restricted to the people in the thread.
--   The Everyone group's membership is `is_active_staff` and nothing else.
--
-- And the three rules the owner kept rather than replaced: a file is attached
-- by reference, taking your own message back leaves the marker, and a client
-- is named by reference so the record can link to the thread without carrying
-- what was said.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_admin uuid; v_admin_uid uuid := gen_random_uuid();
  v_mine  uuid; v_mine_uid  uuid := gen_random_uuid();
  v_out   uuid; v_out_uid   uuid := gen_random_uuid();
  v_client uuid; v_conv uuid; v_everyone uuid;
  v_msg uuid; v_note uuid; v_file uuid; v_body text;
  v_n integer; v_limit integer; v_att uuid;
  failures text[] := '{}';
begin
  insert into public.staff (name, email, role, active)
  values ('ZZ Team Admin', 'zz-team-admin@example.test', 'Admin', true) returning id into v_admin;
  insert into public.staff (name, email, role, active)
  values ('ZZ Team Member', 'zz-team-member@example.test', 'Job Search', true) returning id into v_mine;
  insert into public.staff (name, email, role, active)
  values ('ZZ Team Outsider', 'zz-team-outsider@example.test', 'Job Search', true) returning id into v_out;

  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_admin_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-team-admin@example.test',    '{}', '{}', now(), now()),
         (v_mine_uid,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-team-member@example.test',   '{}', '{}', now(), now()),
         (v_out_uid,   '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-team-outsider@example.test', '{}', '{}', now(), now());

  insert into public.clients (name, stage, status) values ('ZZ Team Client', 'Job Search', 'Active')
  returning id into v_client;

  select id into v_everyone from public.conversations where system_key = 'everyone';
  if v_everyone is null then
    raise exception 'FAILED: there is no Everyone group, so none of the rest of this means anything';
  end if;

  -- ── the Everyone group is the staff list ──────────────────
  select count(*) into v_n
    from public.conversation_participants p
    join public.staff s on s.id = p.staff_id
   where p.conversation_id = v_everyone and (p.left_at is null) <> s.active;
  if v_n > 0 then
    failures := failures || format('FAILED: %s people are in the Everyone group when they are not staff, or out of it when they are', v_n);
  elsif (select count(*) from public.conversation_participants
          where conversation_id = v_everyone and left_at is null)
        <> (select count(*) from public.staff where active) then
    failures := failures || 'FAILED: the Everyone group and the staff list are different lengths'::text;
  else
    raise notice 'ok  the Everyone group holds exactly the active staff';
  end if;

  -- Hiring and offboarding, which is what makes the line above a rule rather
  -- than a coincidence on the day it was written.
  update public.staff set active = false where id = v_out;
  if exists (select 1 from public.conversation_participants
              where conversation_id = v_everyone and staff_id = v_out and left_at is null) then
    failures := failures || 'FAILED: somebody offboarded is still in the Everyone group'::text;
  else
    raise notice 'ok  offboarding takes somebody out of it the same minute';
  end if;
  update public.staff set active = true where id = v_out;
  if (select count(*) from public.conversation_participants
       where conversation_id = v_everyone and staff_id = v_out and left_at is null) <> 1 then
    failures := failures || 'FAILED: rehiring did not put them back, or put them back twice'::text;
  else
    raise notice 'ok  and rehiring puts them back, once';
  end if;

  -- ── a thread, and somebody not in it ──────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin_uid, 'role', 'authenticated')::text, true);
  v_conv := public.start_direct_conversation(v_mine);
  v_msg := public.post_message(v_conv, 'ZQ the referral came in this morning');

  perform set_config('request.jwt.claims', json_build_object('sub', v_out_uid, 'role', 'authenticated')::text, true);
  if exists (select 1 from public.messages where id = v_msg) then
    failures := failures || 'FAILED: somebody not in the thread can read it'::text;
  elsif exists (select 1 from public.conversations where id = v_conv) then
    failures := failures || 'FAILED: somebody not in the thread can see the thread'::text;
  else
    raise notice 'ok  a non-member reads neither the thread nor what is in it';
  end if;

  begin
    perform public.post_message(v_conv, 'ZQ butting in');
    failures := failures || 'FAILED: somebody not in the thread wrote to it'::text;
  exception when insufficient_privilege then
    raise notice 'ok  and cannot write to it';
  end;

  -- ── somebody who has left the practice ────────────────────
  perform set_config('role', 'postgres', true);
  update public.staff set active = false where id = v_mine;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_mine_uid, 'role', 'authenticated')::text, true);
  if exists (select 1 from public.messages where id = v_msg) then
    failures := failures || 'FAILED: somebody who has left can still read the thread they were in'::text;
  else
    raise notice 'ok  somebody who has left reads none of it';
  end if;
  begin
    perform public.post_message(v_conv, 'ZQ still here');
    failures := failures || 'FAILED: somebody who has left can still write'::text;
  exception when insufficient_privilege then null;
  end;
  perform set_config('role', 'postgres', true);
  update public.staff set active = true where id = v_mine;
  perform set_config('role', 'authenticated', true);

  -- ── there is no delete path ───────────────────────────────
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin_uid, 'role', 'authenticated')::text, true);
  begin
    delete from public.messages where id = v_msg;
    failures := failures || 'FAILED: a message was deleted'::text;
  exception when insufficient_privilege then null;
  end;
  begin
    delete from public.conversations where id = v_conv;
    failures := failures || 'FAILED: a thread was deleted'::text;
  exception when insufficient_privilege then null;
  end;
  if has_table_privilege('authenticated', 'public.messages', 'DELETE')
     or has_table_privilege('authenticated', 'public.messages', 'TRUNCATE')
     or has_table_privilege('authenticated', 'public.conversations', 'TRUNCATE') then
    failures := failures || 'FAILED: messages or threads are granted DELETE or TRUNCATE, so only a policy stands in the way'::text;
  elsif not exists (select 1 from public.messages where id = v_msg) then
    failures := failures || 'FAILED: the message is gone'::text;
  else
    raise notice 'ok  there is no delete path to a message or a thread, by grant or by policy';
  end if;

  -- Taking your own words back leaves the marker rather than a hole, which is
  -- the rule the owner kept.
  v_msg := public.post_message(v_conv, 'ZQ ignore that, wrong client');
  perform public.remove_message(v_msg);
  if not exists (select 1 from public.messages where id = v_msg) then
    failures := failures || 'FAILED: removing your own message deleted the row'::text;
  elsif (select body from public.messages where id = v_msg) <> '' then
    failures := failures || 'FAILED: removing your own message left the words'::text;
  elsif (select removed_at from public.messages where id = v_msg) is null then
    failures := failures || 'FAILED: a removed message does not say it was removed'::text;
  else
    raise notice 'ok  taking your own words back leaves the marker and not a hole';
  end if;

  -- ── File to client ────────────────────────────────────────
  v_msg := public.post_message(v_conv, 'ZQ he starts at the warehouse on Monday');
  v_note := public.file_message_to_client(v_msg, v_client, 'Job placement');
  if (select category from public.notes where id = v_note) <> 'Job placement' then
    failures := failures || 'FAILED: filing a message did not keep the category chosen'::text;
  elsif (select text from public.notes where id = v_note) not like '%warehouse on Monday%' then
    failures := failures || 'FAILED: the note does not say what the message said'::text;
  elsif (select client_id from public.notes where id = v_note) <> v_client then
    failures := failures || 'FAILED: the note is on the wrong client'::text;
  elsif not exists (select 1 from public.messages where id = v_msg and body <> '') then
    failures := failures || 'FAILED: filing a message took it out of the thread'::text;
  else
    raise notice 'ok  File to client makes the note, with the category chosen, and the message stays';
  end if;

  -- The category is one of the eight and not whatever was typed.
  begin
    perform public.file_message_to_client(v_msg, v_client, 'Whatever');
    failures := failures || 'FAILED: a category that is not one of the eight was filed'::text;
  exception when check_violation then
    raise notice 'ok  and only one of the eight categories';
  end;

  -- Somebody not in the thread cannot file what was said in it.
  perform set_config('request.jwt.claims', json_build_object('sub', v_out_uid, 'role', 'authenticated')::text, true);
  begin
    perform public.file_message_to_client(v_msg, v_client, 'Job search');
    failures := failures || 'FAILED: somebody outside the thread filed a message from it on a client'::text;
  exception when insufficient_privilege then
    raise notice 'ok  and only by somebody in the thread';
  end;

  -- ── a client is named by reference ────────────────────────
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin_uid, 'role', 'authenticated')::text, true);
  v_msg := public.post_message(v_conv, 'ZQ can you look at this before Friday', '[]'::jsonb,
                               '{}'::uuid[], array[v_client]::uuid[]);
  if not exists (select 1 from public.client_chat_mentions
                  where client_id = v_client and message_id = v_msg) then
    failures := failures || 'FAILED: a # chip does not reach the client record'::text;
  elsif exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'client_chat_mentions'
                   and column_name in ('body', 'text')) then
    failures := failures || 'FAILED: what was said is in the client-mention view, and it should be a link'::text;
  else
    raise notice 'ok  a client is named by reference, and the record gets a link and not the words';
  end if;

  -- ── a hidden message ──────────────────────────────────────
  perform public.hide_message(v_msg, true, 'ZQ named a client in a group that should not have had it');
  if not exists (select 1 from public.messages where id = v_msg) then
    failures := failures || 'FAILED: hiding a message is Admin reading it, and Admin cannot'::text;
  else
    raise notice 'ok  Admin can still read a message they have taken down';
  end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_mine_uid, 'role', 'authenticated')::text, true);
  if exists (select 1 from public.messages where id = v_msg) then
    failures := failures || 'FAILED: a hidden message is still on a non-Admin screen'::text;
  else
    raise notice 'ok  and nobody else can';
  end if;

  -- Search is the one that would otherwise hand it back, because it runs as
  -- its owner and the policy above does not reach inside it.
  select count(*) into v_n from public.search_messages('before Friday', 50);
  if v_n <> 0 then
    failures := failures || 'FAILED: searching returns a message that has been taken down'::text;
  else
    raise notice 'ok  and searching does not hand it back';
  end if;
  if exists (select 1 from public.client_chat_mentions where message_id = v_msg) then
    failures := failures || 'FAILED: a hidden message still names a client on their record'::text;
  else
    raise notice 'ok  nor does the client record';
  end if;

  -- Only Admin, and only with a reason, and the log says so.
  begin
    perform public.hide_message(v_msg, false, 'ZQ putting it back');
    failures := failures || 'FAILED: somebody who is not Admin put a hidden message back'::text;
  exception when insufficient_privilege then null;
  end;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin_uid, 'role', 'authenticated')::text, true);
  begin
    perform public.hide_message(v_msg, false, '   ');
    failures := failures || 'FAILED: a message was put back with no reason given'::text;
  exception when check_violation then null;
  end;
  perform public.hide_message(v_msg, false, 'ZQ the complaint was about the wrong thread');
  if (select count(*) from public.message_moderation where message_id = v_msg) <> 2 then
    failures := failures || 'FAILED: the log does not hold both decisions'::text;
  elsif (select reason from public.message_moderation
          where message_id = v_msg order by at desc limit 1) not like 'ZQ the complaint%' then
    failures := failures || 'FAILED: the log does not say why'::text;
  else
    raise notice 'ok  only Admin hides or restores, only with a reason, and the log holds each decision';
  end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_mine_uid, 'role', 'authenticated')::text, true);
  if exists (select 1 from public.message_moderation where message_id = v_msg) then
    failures := failures || 'FAILED: who moderated whom is readable by everybody'::text;
  else
    raise notice 'ok  and who moderated whom is Admin''s to read';
  end if;

  perform set_config('role', 'postgres', true);
  begin
    update public.message_moderation set reason = 'ZQ rewritten' where message_id = v_msg;
    failures := failures || 'FAILED: a privileged caller rewrote the moderation log'::text;
  exception when insufficient_privilege then null;
  end;
  if has_table_privilege('authenticated', 'public.message_moderation', 'TRUNCATE') then
    failures := failures || 'FAILED: anybody signed in can empty the moderation log in one statement'::text;
  else
    raise notice 'ok  the moderation log cannot be rewritten or emptied';
  end if;

  -- ── files ─────────────────────────────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin_uid, 'role', 'authenticated')::text, true);
  v_file := public.record_chat_file(v_conv, 'threads/' || v_conv || '/zz-team.pdf', 'zz-team.pdf',
                                    'application/pdf', 2048);

  perform set_config('request.jwt.claims', json_build_object('sub', v_out_uid, 'role', 'authenticated')::text, true);
  if exists (select 1 from public.chat_files where id = v_file) then
    failures := failures || 'FAILED: somebody not in the thread can see a file sent in it'::text;
  else
    raise notice 'ok  a file sent in a thread is readable only by the people in it';
  end if;
  begin
    perform public.record_chat_file(v_conv, 'threads/' || v_conv || '/zz-theirs.pdf', 'zz-theirs.pdf',
                                    'application/pdf', 2048);
    failures := failures || 'FAILED: somebody not in the thread sent a file into it'::text;
  exception when insufficient_privilege then null;
  end;

  perform set_config('role', 'postgres', true);
  if has_table_privilege('authenticated', 'public.chat_files', 'INSERT')
     or has_table_privilege('authenticated', 'public.chat_files', 'UPDATE')
     or has_table_privilege('authenticated', 'public.chat_files', 'TRUNCATE') then
    failures := failures || 'FAILED: a file row can be written or emptied from the browser'::text;
  elsif has_table_privilege('anon', 'public.chat_files', 'SELECT') then
    failures := failures || 'FAILED: somebody not signed in can read what files were sent'::text;
  else
    raise notice 'ok  and the rows are written by the function that checks the rules, and nothing else';
  end if;

  -- Still by reference: a file the practice does not take, and a file from
  -- another thread, are both refused rather than half-accepted.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin_uid, 'role', 'authenticated')::text, true);
  begin
    perform public.post_message(v_conv, 'ZQ see this',
      jsonb_build_array(jsonb_build_object('kind', 'chat_file', 'id', gen_random_uuid())));
    failures := failures || 'FAILED: a message attached a file that was never sent in this thread'::text;
  exception when no_data_found then
    raise notice 'ok  a file is attached by reference, and only one from this thread';
  end;

  -- ── a dropped file, filed on a client ─────────────────────
  -- The bytes are copied by the screen, because storage cannot be copied from
  -- SQL. This is the half that checks the rules and writes the row, and it is
  -- called by a screen now rather than only by a test.
  v_att := public.file_chat_file_to_client(
    v_file, v_client, 'clients/' || v_client || '/zz-team.pdf', 'Other');
  if (select client_id from public.attachments where id = v_att) <> v_client then
    failures := failures || 'FAILED: filing a dropped file did not put it on the client'::text;
  elsif (select filename from public.attachments where id = v_att) <> 'zz-team.pdf' then
    failures := failures || 'FAILED: the filed document is not the file that was sent'::text;
  elsif (select note from public.attachments where id = v_att) not like '%Team chat%' then
    failures := failures || 'FAILED: the record does not say where the document came from'::text;
  elsif not exists (select 1 from public.chat_files where id = v_file) then
    failures := failures || 'FAILED: filing a dropped file took it out of the thread'::text;
  else
    raise notice 'ok  a dropped file is filed on a client, says where it came from, and stays in the thread';
  end if;

  -- And not by somebody outside the thread, who should not have been able to
  -- read it in the first place.
  perform set_config('request.jwt.claims', json_build_object('sub', v_out_uid, 'role', 'authenticated')::text, true);
  begin
    perform public.file_chat_file_to_client(
      v_file, v_client, 'clients/' || v_client || '/zz-theirs.pdf', 'Other');
    failures := failures || 'FAILED: somebody outside the thread filed its file on a client'::text;
  exception when insufficient_privilege then
    raise notice 'ok  and only by somebody in the thread';
  end;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin_uid, 'role', 'authenticated')::text, true);

  -- ── and the rate limit ────────────────────────────────────
  select per_minute into v_limit from public.chat_rate_limit();
  begin
    for i in 1..(v_limit + 2) loop
      perform public.post_message(v_conv, 'ZQ ' || i);
    end loop;
    failures := failures || 'FAILED: one person sent past the limit in a minute'::text;
  exception when check_violation then
    raise notice 'ok  one person is stopped after % messages in a minute', v_limit;
  end;

  -- ── realtime is on, which is what makes it instant ────────
  perform set_config('role', 'postgres', true);
  for v_body in select t from unnest(array['conversations', 'messages', 'read_receipts']) t loop
    if not exists (select 1 from pg_publication_tables
                    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = v_body) then
      failures := failures || format('FAILED: %s is not published for realtime, so a message is not instant', v_body);
    end if;
  end loop;
  for v_body in select t from unnest(array['conversations', 'conversation_participants', 'messages',
                                           'read_receipts', 'chat_files', 'message_moderation']) t loop
    if not (select relrowsecurity from pg_class where oid = ('public.' || v_body)::regclass) then
      failures := failures || format('FAILED: row-level security is off on %s', v_body);
    end if;
  end loop;
  raise notice 'ok  realtime is on where it has to be, and row-level security on all six tables';

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- TEAM CHAT VERIFIED ---';
end $$;

rollback;
