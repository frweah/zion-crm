-- The provider answers (0287)
--
-- What has to hold:
--
--   A status from GoHighLevel lands on the text its receipt names, and on
--   nothing else.
--
--   'Delivered' is the end of the story. Nothing a provider says afterwards
--   makes a phone not have the message, and a delivered text must never be
--   left looking retryable.
--
--   Below that, a later word wins: a carrier reporting a drop twenty minutes
--   on is telling the practice something it needs.
--
--   A word nobody has seen before is not guessed at. Reading an unknown
--   status as a failure would tell somebody a text did not go when nobody
--   said so.
--
--   A status for a message the practice has no row for is not an error - that
--   is a text sent from GoHighLevel's own screens - and nothing on a screen
--   can call this at all.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_staff uuid; v_client uuid;
  v_a uuid; v_b uuid; v_in uuid;
  r record;
  failures text[] := '{}';
begin
  insert into public.staff (name, email, role, active)
  values ('ZZ Status Sender', 'zz-status@example.test', 'Job Search', true) returning id into v_staff;
  insert into public.clients (name, stage, status, phone, assigned_staff_id)
  values ('ZZ Status Client', 'Job Search', 'Active', '+13850000782', v_staff) returning id into v_client;
  insert into public.sms_consent_events (client_id, state, phone, method, note)
  values (v_client, 'Granted', '+13850000782', 'Intake form', 'ZQ agreed at intake');

  -- ── writing an outgoing text at any hour ──────────────────
  --
  -- The gate (0050) refuses an immediate outgoing text outside 8am-9pm Utah,
  -- which is the rule and is right. It also made this script pass only during
  -- office hours: the suite failed at 9:13 one evening because of it, and a
  -- check that depends on when it runs is a check somebody will learn to
  -- ignore.
  --
  -- So each fixture is written as scheduled for the next window, which the
  -- gate accepts at any hour, and then put back to the state it is about. The
  -- gate is BEFORE INSERT, so the second statement is not refused - and the
  -- state being tested is a row that is already queued and already old, which
  -- is not something the gate has any view about.

  insert into public.sms_messages (client_id, direction, phone, body, kind, status, created_by,
                                   provider_message_id, send_after)
  values (v_client, 'Outgoing', '+13850000782', 'ZQ one', 'Manual', 'Scheduled', v_staff, 'zq-receipt-a', public.next_text_window(now()))
  returning id into v_a;
  update public.sms_messages set status = 'Sent', send_after = null where id = v_a;
  insert into public.sms_messages (client_id, direction, phone, body, kind, status, created_by,
                                   provider_message_id, send_after)
  values (v_client, 'Outgoing', '+13850000782', 'ZQ two', 'Manual', 'Scheduled', v_staff, 'zq-receipt-b', public.next_text_window(now()))
  returning id into v_b;
  update public.sms_messages set status = 'Sent', send_after = null where id = v_b;
  insert into public.sms_messages (client_id, direction, phone, body, kind, status,
                                   provider_message_id)
  values (v_client, 'Incoming', '+13850000782', 'ZQ hello', 'Reply', 'Received', 'zq-receipt-in')
  returning id into v_in;

  -- ── the right row ─────────────────────────────────────────
  select * into r from public.record_text_status('zq-receipt-a', 'delivered', null, '{"zq": 1}'::jsonb);
  if not r.matched or r.status <> 'Delivered' then
    failures := failures || 'FAILED: a delivery report did not land on the text it names'::text;
  elsif (select status from public.sms_messages where id = v_a) <> 'Delivered' then
    failures := failures || 'FAILED: the text was not recorded as delivered'::text;
  elsif (select status from public.sms_messages where id = v_b) <> 'Sent' then
    failures := failures || 'FAILED: the report landed on another text as well'::text;
  else
    raise notice 'ok  a delivery report lands on the text its receipt names, and on nothing else';
  end if;

  -- ── delivered is the end of it ────────────────────────────
  perform public.record_text_status('zq-receipt-a', 'failed', 'ZQ the carrier changed its mind');
  if (select status from public.sms_messages where id = v_a) <> 'Delivered' then
    failures := failures || 'FAILED: a text the phone already had was turned back into a failure'::text;
  elsif (select error from public.sms_messages where id = v_a) <> '' then
    failures := failures || 'FAILED: a delivered text was given a failure to show'::text;
  else
    raise notice 'ok  and delivered is the end of the story';
  end if;

  -- ── but below that, the later word wins ───────────────────
  perform public.record_text_status('zq-receipt-b', 'undelivered', 'ZQ the carrier dropped it');
  if (select status from public.sms_messages where id = v_b) <> 'Failed' then
    failures := failures || 'FAILED: a carrier reporting a drop was ignored'::text;
  elsif (select error from public.sms_messages where id = v_b) not like 'ZQ the carrier dropped it%' then
    failures := failures || 'FAILED: the drop does not say what the carrier said'::text;
  else
    raise notice 'ok  a drop reported later is recorded, in the carrier''s words';
  end if;

  -- A failure with no words still says something a person can read.
  perform public.record_text_status('zq-receipt-b', 'failed', null);
  if coalesce((select error from public.sms_messages where id = v_b), '') = '' then
    failures := failures || 'FAILED: a failure with no reason left the text with nothing to show'::text;
  else
    raise notice 'ok  and a failure with no reason still reads as something';
  end if;

  -- ── a word nobody has seen ────────────────────────────────
  select * into r from public.record_text_status('zq-receipt-b', 'flibbertigibbet');
  if r.matched then
    failures := failures || 'FAILED: a status nobody recognises was acted on'::text;
  elsif (select status from public.sms_messages where id = v_b) <> 'Failed' then
    failures := failures || 'FAILED: an unrecognised status changed the text anyway'::text;
  else
    raise notice 'ok  a word nobody has seen before is not guessed at';
  end if;

  -- ── somebody else's message ───────────────────────────────
  select * into r from public.record_text_status('zq-not-ours', 'delivered');
  if r.matched then
    failures := failures || 'FAILED: a receipt the practice does not hold matched something'::text;
  else
    raise notice 'ok  a status for a text the practice has no row for is answered, not refused';
  end if;

  -- An incoming text is not something the practice sent.
  select * into r from public.record_text_status('zq-receipt-in', 'delivered');
  if r.matched then
    failures := failures || 'FAILED: a delivery report landed on a text that came in'::text;
  else
    raise notice 'ok  and a text that came in is not something a delivery report is about';
  end if;

  -- ── and nothing on a screen can call it ───────────────────
  if exists (
    select 1 from information_schema.routine_privileges
     where routine_schema = 'public' and routine_name = 'record_text_status'
       and grantee in ('anon', 'authenticated')
  ) then
    failures := failures || 'FAILED: a browser can tell the practice what a carrier reported'::text;
  else
    raise notice 'ok  only the webhook says what a carrier reported';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- THE PROVIDER ANSWERS VERIFIED ---';
end $$;

rollback;
