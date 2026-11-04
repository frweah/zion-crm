-- A text that never went says so (0280, 0281)
--
-- What has to hold:
--
--   An outgoing text that has heard nothing for five minutes becomes 'Not
--   delivered' and says so to whoever wrote it. Once, not once a quarter hour.
--
--   A scheduled text that has not reached its window is not late.
--
--   Retry re-sends the same row and never makes a second one. It is refused
--   on a text the provider took, on one that went, and on one still going.
--
--   A thread about a client belongs to whoever the client belongs to, unless
--   somebody says otherwise.
--
--   An inbound picture's URL is kept, and a picture with no words in it does
--   not read as a keyword - "withdrew consent by sending a photograph" would
--   be a bad afternoon.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_staff uuid; v_uid uuid := gen_random_uuid();
  v_other uuid;
  v_client uuid; v_late uuid; v_fresh uuid; v_future uuid; v_taken uuid;
  v_conv uuid; v_in uuid;
  v_n integer; v_before integer;
  failures text[] := '{}';
begin
  insert into public.staff (name, email, role, active)
  values ('ZZ Text Sender', 'zz-sender@example.test', 'Job Search', true) returning id into v_staff;
  insert into public.staff (name, email, role, active)
  values ('ZZ Text Other', 'zz-other@example.test', 'Job Search', true) returning id into v_other;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-sender@example.test', '{}', '{}', now(), now());

  insert into public.clients (name, stage, status, phone, assigned_staff_id)
  values ('ZZ Text Client', 'Job Search', 'Active', '+13850000777', v_other)
  returning id into v_client;

  -- The consent gate (0050) refuses an outgoing text to a client who has not
  -- agreed, which is the rule and is why it is recorded here rather than
  -- worked around.
  insert into public.sms_consent_events (client_id, state, phone, method, note)
  values (v_client, 'Granted', '+13850000777', 'Intake form', 'ZQ agreed at intake');

  -- ── a thread belongs to whoever the client does ───────────
  insert into public.conversations (kind, client_id, external_address)
  values ('sms', v_client, '+13850000777') returning id into v_conv;
  if (select assigned_staff_id from public.conversations where id = v_conv) <> v_other then
    failures := failures || 'FAILED: a new thread about a client did not go to the client''s staff member'::text;
  else
    raise notice 'ok  a thread about a client belongs to whoever the client belongs to';
  end if;

  -- And somebody saying otherwise still wins.
  update public.conversations set assigned_staff_id = v_staff where id = v_conv;
  if (select assigned_staff_id from public.conversations where id = v_conv) <> v_staff then
    failures := failures || 'FAILED: the default overrode somebody''s choice'::text;
  else
    raise notice 'ok  and somebody saying otherwise still wins';
  end if;

  -- ── the five minutes ──────────────────────────────────────
  insert into public.sms_messages (client_id, direction, phone, body, kind, status, created_by, created_at)
  values (v_client, 'Outgoing', '+13850000777', 'ZQ this one hung', 'Manual', 'Queued', v_staff,
          now() - interval '20 minutes')
  returning id into v_late;

  insert into public.sms_messages (client_id, direction, phone, body, kind, status, created_by, created_at)
  values (v_client, 'Outgoing', '+13850000777', 'ZQ this one is new', 'Manual', 'Queued', v_staff, now())
  returning id into v_fresh;

  -- A scheduled text waiting for 8am is not late, however long it waits.
  insert into public.sms_messages (client_id, direction, phone, body, kind, status, created_by,
                                   created_at, send_after)
  values (v_client, 'Outgoing', '+13850000777', 'ZQ in the morning', 'Manual', 'Scheduled', v_staff,
          now() - interval '20 minutes',
          -- The practice's own next window, not a number of hours from now: the
          -- gate thinks in Utah hours and now() is UTC, so "eight hours from
          -- now" lands outside the window for most of the day.
          public.next_text_window(now() + interval '1 hour'))
  returning id into v_future;

  select count(*) into v_before from public.notifications where kind = 'text_not_delivered';
  v_n := public.mark_texts_not_delivered();

  if (select status from public.sms_messages where id = v_late) <> 'Not delivered' then
    failures := failures || 'FAILED: a text that heard nothing for twenty minutes still reads as going'::text;
  elsif (select error from public.sms_messages where id = v_late) <> 'no status received from GHL' then
    failures := failures || 'FAILED: the text does not say that nothing came back'::text;
  elsif (select status from public.sms_messages where id = v_fresh) <> 'Queued' then
    failures := failures || 'FAILED: a text written a moment ago was given up on'::text;
  elsif (select status from public.sms_messages where id = v_future) <> 'Scheduled' then
    failures := failures || 'FAILED: a text waiting for its window was called not delivered'::text;
  else
    raise notice 'ok  five minutes of silence is Not delivered; a new one and a waiting one are not';
  end if;

  if (select count(*) from public.notifications where kind = 'text_not_delivered') <= v_before then
    failures := failures || 'FAILED: nobody was told the text did not go'::text;
  else
    raise notice 'ok  and whoever wrote it is told';
  end if;

  -- Once, not once a quarter hour.
  v_before := (select count(*) from public.notifications where kind = 'text_not_delivered');
  if public.mark_texts_not_delivered() <> 0 then
    failures := failures || 'FAILED: the sweep gave up on the same text twice'::text;
  elsif (select count(*) from public.notifications where kind = 'text_not_delivered') <> v_before then
    failures := failures || 'FAILED: the sweep told somebody twice about one text'::text;
  else
    raise notice 'ok  said once, however often the sweep runs';
  end if;

  -- ── retry ─────────────────────────────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);

  select count(*) into v_before from public.sms_messages;
  perform public.retry_text(v_late);
  if (select count(*) from public.sms_messages) <> v_before then
    failures := failures || 'FAILED: retrying a text made a second row, so the record says it was sent twice'::text;
  elsif (select status from public.sms_messages where id = v_late) <> 'Queued' then
    failures := failures || 'FAILED: retrying did not put the text back to be sent'::text;
  elsif (select error from public.sms_messages where id = v_late) <> '' then
    failures := failures || 'FAILED: retrying kept the old failure on the row'::text;
  else
    raise notice 'ok  retry re-sends the same row, and never a second one';
  end if;

  -- Still going: nothing to retry yet.
  begin
    perform public.retry_text(v_late);
    failures := failures || 'FAILED: a text that is going was retried'::text;
  exception when check_violation then null;
  end;

  -- The provider took it: retrying would text them twice.
  perform set_config('role', 'postgres', true);
  insert into public.sms_messages (client_id, direction, phone, body, kind, status, created_by,
                                   created_at, provider_message_id)
  values (v_client, 'Outgoing', '+13850000777', 'ZQ the provider has this', 'Manual', 'Not delivered',
          v_staff, now() - interval '20 minutes', 'ghl-abc-123')
  returning id into v_taken;
  perform set_config('role', 'authenticated', true);
  begin
    perform public.retry_text(v_taken);
    failures := failures || 'FAILED: a text the provider accepted was sent again'::text;
  exception when check_violation then
    raise notice 'ok  and is refused on one still going, and on one the provider took';
  end;

  -- An inbound text is not a thing to retry.
  perform set_config('role', 'postgres', true);
  insert into public.sms_messages (client_id, direction, phone, body, kind, status, media_url)
  values (v_client, 'Incoming', '+13850000777', '', 'Reply', 'Received',
          'https://example.test/zz-picture.jpg')
  returning id into v_in;
  perform set_config('role', 'authenticated', true);
  begin
    perform public.retry_text(v_in);
    failures := failures || 'FAILED: a text that came in was retried'::text;
  exception when check_violation then
    raise notice 'ok  and there is nothing to retry about a text that came in';
  end;

  -- ── a picture ─────────────────────────────────────────────
  perform set_config('role', 'postgres', true);
  if (select media_url from public.sms_messages where id = v_in) is null then
    failures := failures || 'FAILED: a picture sent with a text was not kept'::text;
  else
    raise notice 'ok  a picture sent with a text is kept, as the provider''s URL';
  end if;

  -- A picture with no words must not read as a keyword. This is the one that
  -- would be a bad afternoon: an empty body stripped to letters is an empty
  -- string, and an empty string matching STOP would withdraw consent because
  -- somebody sent a photograph.
  select count(*) into v_n from public.sms_consent_events where client_id = v_client;
  perform public.record_incoming_sms('+13850000777', '', null, null,
                                     'https://example.test/zz-second.jpg', 'image/jpeg');
  if (select count(*) from public.sms_consent_events where client_id = v_client) <> v_n then
    failures := failures || 'FAILED: a picture with no words changed the client''s consent'::text;
  elsif not exists (select 1 from public.sms_messages
                     where client_id = v_client and media_url like '%zz-second%') then
    failures := failures || 'FAILED: the picture that arrived was not recorded'::text;
  else
    raise notice 'ok  a picture with no words in it is not read as a keyword';
  end if;

  -- And a real STOP still is.
  perform public.record_incoming_sms('+13850000777', 'STOP', null, null, null, null);
  if not exists (select 1 from public.sms_consent_events
                  where client_id = v_client and state = 'Withdrawn') then
    failures := failures || 'FAILED: a real STOP no longer withdraws consent'::text;
  else
    raise notice 'ok  and a real STOP still withdraws consent';
  end if;

  -- ── the five minutes are one number ───────────────────────
  if public.text_lapse_minutes() <> 5 then
    failures := failures || format('FAILED: the database gives up after %s minutes and the owner said five',
                                   public.text_lapse_minutes());
  else
    raise notice 'ok  five minutes, from one function the sweep and the screen both read';
  end if;

  -- ── and the inbox is told the same thing ──────────────────
  -- The client's record and the inbox read different tables - sms_messages on
  -- one and the mirror in messages on the other - so "it says In and who sent
  -- it" has to be true of both or the same text is described two ways, which
  -- is what 1a is about (0284).
  perform set_config('role', 'postgres', true);
  if (select sender_kind from public.messages where source_sms_id = v_in) <> 'client' then
    failures := failures || 'FAILED: a text from the client reaches the inbox as somebody else'::text;
  elsif (select media_url from public.messages where source_sms_id = v_in) is null then
    failures := failures || 'FAILED: the picture did not reach the inbox'::text;
  elsif (select sender_label from public.messages where source_sms_id = v_late) <> 'ZZ Text Sender' then
    failures := failures || 'FAILED: an outgoing text does not say in the inbox who sent it'::text;
  else
    raise notice 'ok  the inbox is told the direction, who sent it, and the picture';
  end if;

  -- v_late was given up on by the sweep above and then retried, so it is
  -- queued again; one that stays given up on is what the inbox has to show as
  -- failed rather than as still going.
  if (select status from public.messages where source_sms_id = v_taken) <> 'failed' then
    failures := failures || format('FAILED: a text the practice gave up on reads as %s in the inbox',
                                   (select status from public.messages where source_sms_id = v_taken));
  else
    raise notice 'ok  and a text the practice gave up on is not still going there';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- TEXTS VERIFIED ---';
end $$;

rollback;
