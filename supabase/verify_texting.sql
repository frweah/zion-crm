-- Zion Vocational Rehab CRM — client texting, two ways (0105)
--
-- What has to hold, each tried from the direction that would break it:
--
--   The gate is where it always was. No consent, no text; the wrong number,
--   no text; outside 8am-9pm, no text - and the new way in does not get round
--   any of it. A message may instead be written for the next window, and only
--   for a time inside it.
--
--   Every text, in both directions, is in the client's thread the moment it is
--   written down - a reminder the nightly job sent as much as a reply typed on
--   a screen - and STOP and START appear there too.
--
--   A text from a number nobody knows is kept, and sits in the inbox as
--   unmatched until somebody matches it, makes a referral of it, or marks it
--   spam. Only the roles that work texts may do any of that. (The inbox holds
--   website chats as well since 0107, which is why the five functions behind
--   it no longer say "text" - the rules here are unchanged.)
--
-- Uses a made-up client and made-up staff (ZZ). Runs inside a transaction
-- that is rolled back.

begin;

do $$
declare
  v_client uuid;
  v_other  uuid;
  v_staff  uuid; v_staff_uid uuid := gen_random_uuid();
  v_bill   uuid; v_bill_uid uuid := gen_random_uuid();
  v_conv   uuid;
  v_unknown uuid;
  v_ref    uuid;
  v_n      integer;
  v_body   text;
  failures text[] := '{}';
begin
  insert into public.staff (name, email, role, active) values ('ZZ Text Worker', 'zz-text-worker@example.test', 'Job Search', true) returning id into v_staff;
  insert into public.staff (name, email, role, active) values ('ZZ Text Billing', 'zz-text-billing@example.test', 'Billing', true) returning id into v_bill;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_staff_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-text-worker@example.test', '{}', '{}', now(), now()),
         (v_bill_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-text-billing@example.test', '{}', '{}', now(), now());
  insert into public.clients (name, phone, stage, status) values ('ZZ Texting Client', '801-555-0142', 'Intake', 'Active') returning id into v_client;
  insert into public.clients (name, phone, stage, status) values ('ZZ Other Client', '801-555-0143', 'Intake', 'Active') returning id into v_other;

  -- ── the gate ───────────────────────────────────────────────
  begin
    insert into public.sms_messages (client_id, direction, phone, body, kind, created_by)
    values (v_client, 'Outgoing', '801-555-0142', 'ZZ before consent', 'Manual', v_staff);
    failures := failures || 'FAILED: a text went to somebody who has not agreed to be texted'::text;
  exception when check_violation then null;
  end;

  insert into public.sms_consent_events (client_id, state, phone, method, note)
  values (v_client, 'Granted', public.normalize_phone('801-555-0142'), 'Verbal', 'ZZ consent for the test');

  begin
    insert into public.sms_messages (client_id, direction, phone, body, kind, created_by)
    values (v_client, 'Outgoing', '801-555-0999', 'ZZ to another number', 'Manual', v_staff);
    failures := failures || 'FAILED: a text went to a number the client never agreed to'::text;
  exception when check_violation then null;
  end;

  -- Written for the next window, which is what somebody is offered at night.
  -- Tomorrow night, not a fixed date: a date written into the check went
  -- into the past on 21 Sept 2026 and the send was rightly refused.
  insert into public.sms_messages (client_id, direction, phone, body, kind, status, send_after, created_by)
  values (v_client, 'Outgoing', '801-555-0142', 'ZZ in the morning', 'Manual', 'Scheduled',
          public.next_text_window(((public.practice_today() + 1) + time '22:30') at time zone 'America/Denver'), v_staff);
  begin
    insert into public.sms_messages (client_id, direction, phone, body, kind, status, send_after, created_by)
    values (v_client, 'Outgoing', '801-555-0142', 'ZZ at midnight', 'Manual', 'Scheduled',
            ((public.practice_today() + 2) + time '00:30') at time zone 'America/Denver', v_staff);
    failures := failures || 'FAILED: a text was scheduled for the middle of the night'::text;
  exception when check_violation then null;
  end;
  if not public.sms_within_sending_hours(public.next_text_window(((public.practice_today() + 1) + time '22:30') at time zone 'America/Denver')) then
    failures := failures || 'FAILED: the next window offered is outside sending hours'::text;
  else
    raise notice 'ok  no consent, the wrong number and the middle of the night are all still refused; the next window is offered instead';
  end if;

  -- ── the thread ─────────────────────────────────────────────
  -- A reminder going out. Which way this goes depends on the hour the check
  -- is run at, and both are the rule working: in the window it goes, outside
  -- it is refused and written for the morning instead.
  if public.sms_within_sending_hours(now()) then
    insert into public.sms_messages (client_id, direction, phone, body, kind, status, sent_at)
    values (v_client, 'Outgoing', public.normalize_phone('801-555-0142'), 'ZZ reminder from the nightly job', 'Reminder', 'Queued', now());
  else
    begin
      insert into public.sms_messages (client_id, direction, phone, body, kind, status, sent_at)
      values (v_client, 'Outgoing', public.normalize_phone('801-555-0142'), 'ZZ reminder at the wrong hour', 'Reminder', 'Queued', now());
      failures := failures || 'FAILED: a text went out outside 8am-9pm'::text;
    exception when check_violation then null;
    end;
    insert into public.sms_messages (client_id, direction, phone, body, kind, status, send_after)
    values (v_client, 'Outgoing', public.normalize_phone('801-555-0142'), 'ZZ reminder for the morning', 'Reminder', 'Scheduled', public.next_text_window(now()));
  end if;
  perform public.record_incoming_sms('801-555-0142', 'ZZ thanks, see you then', 'zz-provider-1', null);

  select id into v_conv from public.conversations where kind = 'sms' and client_id = v_client;
  if v_conv is null then
    failures := failures || 'FAILED: the client has no text thread'::text;
  else
    select count(*) into v_n from public.messages where conversation_id = v_conv;
    -- scheduled + reminder + reply + the consent line
    if v_n <> 4 then
      failures := failures || format('FAILED: the thread holds %s of the four things said', v_n)::text;
    end if;
    if not exists (select 1 from public.messages where conversation_id = v_conv and sender_kind = 'client' and body like 'ZZ thanks%')
       or not exists (select 1 from public.messages where conversation_id = v_conv and sender_kind = 'system' and body like 'Texting agreed%') then
      failures := failures || 'FAILED: the reply or the consent line is missing from the thread'::text;
    end if;
  end if;

  -- STOP, in the thread and in force.
  perform public.record_incoming_sms('801-555-0142', 'STOP', 'zz-provider-2', null);
  if (select can_text from public.client_sms_consent where client_id = v_client) then
    failures := failures || 'FAILED: STOP did not stop the texting'::text;
  elsif not exists (select 1 from public.messages where conversation_id = v_conv and body like 'Texting stopped%') then
    failures := failures || 'FAILED: the thread does not show why texting stopped'::text;
  else
    raise notice 'ok  reminders, replies, STOP and START are all in the one thread, and STOP still stops it';
  end if;

  -- ── a number nobody knows ──────────────────────────────────
  perform public.record_incoming_sms('801-555-0177', 'ZZ hello, I was given your number', 'zz-provider-3', null);
  select id into v_unknown from public.conversations where kind = 'sms' and client_id is null and external_address = public.normalize_phone('801-555-0177');
  if v_unknown is null then
    failures := failures || 'FAILED: a text from an unknown number did not reach the inbox'::text;
  end if;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_bill_uid, 'role', 'authenticated')::text, true);
  begin
    perform public.match_conversation(v_unknown, v_other);
    failures := failures || 'FAILED: a role that does not work texts matched one to a client'::text;
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.mark_conversation_spam(v_unknown);
    failures := failures || 'FAILED: a role that does not work texts marked one spam'::text;
  exception when insufficient_privilege then null;
  end;
  select count(*) into v_n from public.message_inbox('unmatched');
  if v_n < 1 then
    failures := failures || 'FAILED: Billing cannot see the texts inbox at all'::text;
  end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_staff_uid, 'role', 'authenticated')::text, true);
  perform public.assign_conversation(v_unknown, v_staff);
  select count(*) into v_n from public.message_inbox('mine');
  if v_n <> 1 then
    failures := failures || format('FAILED: "mine" showed %s conversations after assigning one', v_n)::text;
  end if;

  v_ref := public.referral_from_conversation(v_unknown, 'ZZ Walked In');
  if (select stage from public.clients where id = v_ref) <> 'Referral' then
    failures := failures || 'FAILED: a referral from a text did not start at Referral'::text;
  elsif not exists (select 1 from public.tasks where client_id = v_ref and title like 'Intake call%') then
    failures := failures || 'FAILED: a referral from a text left no intake task'::text;
  elsif (select client_id from public.conversations where id = v_unknown) <> v_ref then
    failures := failures || 'FAILED: the texts did not move onto the new referral'::text;
  elsif (select count(*) from public.sms_messages where client_id = v_ref) <> 1 then
    failures := failures || 'FAILED: the texts themselves were not put on the referral'::text;
  elsif (select can_text from public.client_sms_consent where client_id = v_ref) then
    failures := failures || 'FAILED: texting somebody back was allowed just because they texted in'::text;
  else
    raise notice 'ok  an unknown number waits in the inbox, and becomes a referral with its texts and an intake task - but not consent';
  end if;

  -- Spam is kept, not deleted, and only while nobody owns it.
  perform set_config('role', 'postgres', true);
  perform public.record_incoming_sms('801-555-0188', 'ZZ win a free cruise', 'zz-provider-4', null);
  perform set_config('role', 'authenticated', true);
  select id into v_unknown from public.conversations where kind = 'sms' and client_id is null and external_address = public.normalize_phone('801-555-0188');
  perform public.mark_conversation_spam(v_unknown);
  select count(*) into v_n from public.message_inbox('open');
  if exists (select 1 from public.message_inbox('open') where conversation_id = v_unknown) then
    failures := failures || 'FAILED: something marked spam was still in the open inbox'::text;
  elsif not exists (select 1 from public.message_inbox('spam') where conversation_id = v_unknown) then
    failures := failures || 'FAILED: something marked spam was lost rather than set aside'::text;
  elsif not exists (select 1 from public.messages m join public.conversations c on c.id = m.conversation_id where c.id = v_unknown) then
    failures := failures || 'FAILED: the spam text itself was deleted'::text;
  else
    raise notice 'ok  spam is set aside and kept, and only Admin, Job Search and Reports work the inbox';
  end if;

  perform set_config('request.jwt.claims', '', true);
  if has_function_privilege('anon', 'public.message_inbox(text)', 'execute')
     or has_function_privilege('anon', 'public.referral_from_conversation(uuid, text)', 'execute') then
    failures := failures || 'FAILED: somebody not signed in can work the texts inbox'::text;
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- CLIENT TEXTING VERIFIED ---';
end $$;

rollback;
