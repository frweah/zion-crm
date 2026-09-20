-- Zion Vocational Rehab CRM — the website chat (0107)
--
-- What has to hold, each tried from the direction that would break it:
--
--   A visitor is not signed in, and nothing is open to somebody who is not.
--   The four functions the widget's server calls are the service role's
--   alone, and the tables behind them are readable by nobody else.
--
--   The bubble does not work until the practice turns it on.
--
--   Live means somebody who takes web chats is online - and then the chat
--   goes to whichever of them has the least on. Nobody online is not a
--   refusal: the conversation is kept, a task is raised, and the visitor is
--   told when to expect an answer.
--
--   A number or an address already on file puts the conversation on that
--   client's record, and on their Activity. One that is not waits to be
--   matched, made into a referral, or marked spam.
--
--   Arriving by chat is not agreeing to be texted.
--
--   A visitor's tab reads its own conversation and no other, and one machine
--   cannot open conversations all afternoon.
--
-- Uses made-up staff and clients (ZZ). Runs inside a transaction that is
-- rolled back.

begin;

do $$
declare
  v_taker  uuid; v_taker_uid uuid := gen_random_uuid();
  v_bill   uuid; v_bill_uid  uuid := gen_random_uuid();
  v_known  uuid;
  v_conv   uuid;
  v_conv2  uuid;
  v_live   boolean;
  v_promise text;
  v_assigned text;
  v_client uuid;
  v_seq    bigint;
  v_n      integer;
  failures text[] := '{}';
begin
  insert into public.staff (name, email, role, active) values ('ZZ Web Taker', 'zz-web-taker@example.test', 'Job Search', true) returning id into v_taker;
  insert into public.staff (name, email, role, active) values ('ZZ Web Billing', 'zz-web-billing@example.test', 'Billing', true) returning id into v_bill;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_taker_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-web-taker@example.test', '{}', '{}', now(), now()),
         (v_bill_uid,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-web-billing@example.test', '{}', '{}', now(), now());
  insert into public.clients (name, phone, stage, status, assigned_staff_id)
  values ('ZZ Web Known', '801-555-0166', 'Intake', 'Active', v_taker) returning id into v_known;

  -- ── nothing is open to somebody not signed in ──────────────
  if has_function_privilege('anon', 'public.start_web_chat(text, text, text, text, text)', 'execute')
     or has_function_privilege('anon', 'public.post_visitor_message(uuid, text)', 'execute')
     or has_function_privilege('anon', 'public.web_chat_thread(uuid, bigint)', 'execute')
     or has_function_privilege('anon', 'public.web_chat_session(text)', 'execute')
     or has_function_privilege('anon', 'public.web_chat_config()', 'execute')
     or has_table_privilege('anon', 'public.web_chats', 'select')
     or has_table_privilege('anon', 'public.web_chat_sessions', 'select') then
    failures := failures || 'FAILED: a visitor could reach the website chat without the server'::text;
  end if;
  -- Staff are not the server either: a token is a key.
  if has_function_privilege('authenticated', 'public.start_web_chat(text, text, text, text, text)', 'execute')
     or has_function_privilege('authenticated', 'public.web_chat_session(text)', 'execute')
     or has_table_privilege('authenticated', 'public.web_chat_sessions', 'select') then
    failures := failures || 'FAILED: a signed-in staff member could mint or read a visitor session'::text;
  else
    raise notice 'ok  the visitor''s way in is the server''s alone; nobody signed out reads any of it';
  end if;

  -- ── off until the practice turns it on ─────────────────────
  update public.org_settings set web_chat_enabled = false;
  begin
    perform public.start_web_chat('ZZ Visitor', 'zz-visitor@example.test', 'ZZ notice', 'zz-hash-off', '');
    failures := failures || 'FAILED: a chat started while the bubble was switched off'::text;
  exception when check_violation then null;
  end;

  update public.org_settings
     set web_chat_enabled = true,
         web_chat_takers = array[v_taker],
         web_chat_days = '{1,2,3,4,5,6,7}'::integer[],
         web_chat_open = '00:00', web_chat_close = '23:59',
         web_chat_promise = 'by the end of the next business day';

  -- ── nobody there: a contact form, not a closed door ────────
  delete from public.staff_presence where staff_id = v_taker;
  select conversation_id, live, promise into v_conv, v_live, v_promise
    from public.start_web_chat('ZZ Visitor One', 'zz-one@example.test', 'By chatting you agree to be contacted at this address.', 'zz-hash-1', 'zz-ip-a');
  if v_live then
    failures := failures || 'FAILED: the bubble said somebody was there when nobody was online'::text;
  end if;
  if v_promise is null or v_promise = '' then
    failures := failures || 'FAILED: a visitor was not told when to expect an answer'::text;
  end if;
  if not exists (select 1 from public.tasks where title like 'Website chat - answer ZZ Visitor One%' and status = 'Open') then
    failures := failures || 'FAILED: nobody was given the job of answering a chat that arrived out of hours'::text;
  end if;
  if (select client_id from public.conversations where id = v_conv) is not null then
    failures := failures || 'FAILED: a visitor nobody knows was attached to a client'::text;
  end if;
  -- The consent line is kept with the conversation, and said in the thread.
  if (select consent_text from public.web_chats where conversation_id = v_conv) not like 'By chatting%' then
    failures := failures || 'FAILED: what the visitor agreed to was not kept with the conversation'::text;
  elsif not exists (select 1 from public.messages where conversation_id = v_conv and sender_kind = 'system' and body like '%agreed:%') then
    failures := failures || 'FAILED: the thread does not say what was agreed'::text;
  else
    raise notice 'ok  with nobody online the chat is kept, a task is raised, the visitor is told when - and the consent is on the record';
  end if;

  -- ── somebody there: it goes to them ────────────────────────
  insert into public.staff_presence (staff_id, state, last_seen) values (v_taker, 'online', now())
  on conflict (staff_id) do update set state = 'online', last_seen = now();
  if not public.web_chat_live() then
    failures := failures || 'FAILED: the bubble was not live with a taker online inside the hours'::text;
  end if;
  select conversation_id, live, assigned_name into v_conv2, v_live, v_assigned
    from public.start_web_chat('ZZ Visitor Two', '801-555-0166', 'By chatting you agree to be contacted at this number.', 'zz-hash-2', 'zz-ip-b');
  if not v_live or v_assigned <> 'ZZ Web Taker' then
    failures := failures || 'FAILED: a live chat did not go to the person who was online'::text;
  end if;
  -- That number is already somebody's.
  if (select client_id from public.conversations where id = v_conv2) <> v_known then
    failures := failures || 'FAILED: a visitor already on file was not attached to their record'::text;
  end if;

  -- ── what the visitor says, and reads back ──────────────────
  v_seq := public.post_visitor_message(v_conv2, 'ZZ I would like to ask about job coaching');
  begin
    perform public.post_visitor_message(v_conv2, '');
    failures := failures || 'FAILED: an empty message from a visitor went through'::text;
  exception when check_violation then null;
  end;
  begin
    perform public.post_visitor_message(v_conv2, repeat('z', 2001));
    failures := failures || 'FAILED: a visitor could send a message of any length'::text;
  exception when check_violation then null;
  end;
  select count(*) into v_n from public.web_chat_thread(v_conv2, 0);
  if v_n <> 2 then
    failures := failures || format('FAILED: the visitor''s own thread showed %s of its two lines', v_n)::text;
  end if;
  if exists (select 1 from public.web_chat_thread(v_conv2, 0) where body like 'ZZ Visitor One%') then
    failures := failures || 'FAILED: a visitor could read another visitor''s conversation'::text;
  end if;
  if public.web_chat_session('zz-hash-2') <> v_conv2 then
    failures := failures || 'FAILED: a token did not open its own conversation'::text;
  elsif public.web_chat_session('zz-hash-nonsense') is not null then
    failures := failures || 'FAILED: a token nobody issued opened a conversation'::text;
  else
    raise notice 'ok  a live chat goes to whoever is online, attaches to the record it belongs to, and each tab reads only its own';
  end if;

  -- ── answering, from the inbox ──────────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_bill_uid, 'role', 'authenticated')::text, true);
  begin
    perform public.post_web_reply(v_conv, 'ZZ Billing answering');
    failures := failures || 'FAILED: a role that does not work the inbox answered a website chat'::text;
  exception when insufficient_privilege then null;
  end;

  perform set_config('request.jwt.claims', json_build_object('sub', v_taker_uid, 'role', 'authenticated')::text, true);
  perform public.post_web_reply(v_conv, 'ZZ We can help with that - somebody will call you.');
  if (select assigned_staff_id from public.conversations where id = v_conv) <> v_taker then
    failures := failures || 'FAILED: answering an unassigned chat did not put it in the answerer''s hands'::text;
  end if;
  -- And the visitor's tab sees the reply, as a first name only.
  perform set_config('role', 'postgres', true);
  if not exists (select 1 from public.web_chat_thread(v_conv, 0) where who = 'them' and sender_label = 'ZZ') then
    failures := failures || 'FAILED: the visitor cannot see the reply, or is given more of a name than they need'::text;
  end if;
  perform set_config('role', 'authenticated', true);

  -- ── both kinds in the one inbox ────────────────────────────
  select count(*) into v_n from public.message_inbox('web');
  if v_n < 2 then
    failures := failures || format('FAILED: the inbox showed %s of the website chats', v_n)::text;
  end if;
  if exists (select 1 from public.message_inbox('texts') where kind = 'web') then
    failures := failures || 'FAILED: the texts view of the inbox held a website chat'::text;
  end if;
  if not exists (select 1 from public.message_inbox('unmatched') where conversation_id = v_conv) then
    failures := failures || 'FAILED: a chat from somebody nobody knows was not waiting in the inbox'::text;
  else
    raise notice 'ok  texts and website chats sit in the one inbox, and only the roles that work it may answer';
  end if;

  -- ── a new person, asking on the website ────────────────────
  v_client := public.referral_from_conversation(v_conv, 'ZZ Asked Online');
  if (select stage from public.clients where id = v_client) <> 'Referral' then
    failures := failures || 'FAILED: a referral from the website did not start at Referral'::text;
  elsif (select email from public.clients where id = v_client) <> 'zz-one@example.test' then
    failures := failures || 'FAILED: the address they gave did not go onto their record'::text;
  elsif not exists (select 1 from public.tasks where client_id = v_client and title = 'Intake call - asked on the website') then
    failures := failures || 'FAILED: a referral from the website left no intake task'::text;
  elsif (select can_text from public.client_sms_consent where client_id = v_client) then
    failures := failures || 'FAILED: chatting on the website was taken as agreeing to be texted'::text;
  end if;
  -- And it is on their Activity, like a text or a logged email.
  if not exists (select 1 from public.client_activity where client_id = v_client and kind = 'Website') then
    failures := failures || 'FAILED: a website chat on somebody''s record is not on their Activity'::text;
  else
    raise notice 'ok  a stranger on the website becomes a referral with an intake task, on their Activity - and not consent to be texted';
  end if;

  -- ── one machine, a handful an hour ─────────────────────────
  perform set_config('role', 'postgres', true);
  for v_n in 1..4 loop
    perform public.start_web_chat('ZZ Flood ' || v_n, 'zz-flood-' || v_n || '@example.test', 'ZZ notice', 'zz-hash-f' || v_n, 'zz-ip-a');
  end loop;
  begin
    perform public.start_web_chat('ZZ Flood 5', 'zz-flood-5@example.test', 'ZZ notice', 'zz-hash-f5', 'zz-ip-a');
    failures := failures || 'FAILED: one machine could open conversations all afternoon'::text;
  exception when check_violation then
    raise notice 'ok  one machine gets a handful of chats an hour and is then asked to ring instead';
  end;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- WEBSITE CHAT VERIFIED ---';
end $$;

rollback;
