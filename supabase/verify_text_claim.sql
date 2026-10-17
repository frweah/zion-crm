-- Zion Vocational Rehab CRM — a scheduled text is claimed before it is sent (0209)
--
-- The bug: the sending run read every Scheduled text that was due, sent each
-- one, and then deleted the row. Two runs overlapping both read the same rows
-- and both sent them, and the client got the message twice.
--
-- The claim is a conditional update, and that is the one part of this which
-- a single session can test completely: the second claim has to come back
-- empty, because by then the row is no longer Scheduled. No second
-- connection is needed to show that - what two connections add is only that
-- Postgres serialises them, which it does by definition for one row.
--
-- What has to hold:
--
--   A due text can be claimed, once.
--
--   The second claim of the same text returns nothing. That is the double
--   send, prevented.
--
--   A claim leaves the row in Sending with the time it was taken, so a run
--   that dies can be noticed.
--
--   A claim left by a dead run is handed back and can then be claimed again,
--   because a text that is never sent is a worse failure than one sent twice.
--
--   A claim that is merely recent is NOT handed back - otherwise the handing
--   back becomes the double send it was meant to prevent.
--
--   A text that is not due, or already Sent, cannot be claimed at all.
--
--   And neither anon nor a signed-in member of staff may call any of it: the
--   sending run is the service role, behind the cron secret.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_client  uuid;
  v_staff   uuid;
  v_text    uuid;
  v_other   uuid;
  v_got     integer;
  v_status  text;
  v_claimed timestamptz;
  v_freed   integer;
  failures  text[] := '{}';
begin
  insert into public.staff (name, email, role, active)
  values ('ZZ Text Admin', 'zz-text@example.test', 'Admin', true) returning id into v_staff;
  insert into public.clients (name, stage, status, phone)
  values ('ZZ Text Client', 'Placement', 'Active', '+15555550123') returning id into v_client;

  -- Consent follows the number, and nothing can be sent without it (0050).
  insert into public.sms_consent_events (client_id, state, phone, method, staff_id, note)
  values (v_client, 'Granted', '+15555550123', 'Staff', v_staff, 'ZZ fixture consent');

  -- Scheduled ahead, because a text cannot be booked for a time that has
  -- passed, and then moved back: in production that is simply the hour going
  -- by between the booking and the sending run.
  insert into public.sms_messages (client_id, phone, body, kind, status, send_after, direction, created_by)
  values (v_client, '+15555550123', 'ZZ a scheduled message', 'Manual', 'Scheduled',
          public.next_text_window(now() + interval '5 minutes'), 'Outgoing', v_staff)
  returning id into v_text;
  update public.sms_messages set send_after = now() - interval '1 hour' where id = v_text;

  -- ── claimed once ──────────────────────────────────────────
  select count(*) into v_got from public.claim_scheduled_text(v_text);
  if v_got <> 1 then
    failures := failures || format('FAILED: claiming a due text returned %s rows, not 1', v_got)::text;
  else
    raise notice 'ok  a scheduled text that is due can be claimed';
  end if;

  select status, claimed_at into v_status, v_claimed from public.sms_messages where id = v_text;
  if v_status <> 'Sending' then
    failures := failures || format('FAILED: after claiming, the text is %s and not Sending', v_status)::text;
  elsif v_claimed is null then
    failures := failures || 'FAILED: a claimed text records no time, so a dead run could never be noticed'::text;
  else
    raise notice 'ok  and it is marked Sending, with the time it was taken';
  end if;

  -- ── and not twice. This is the double send ────────────────
  select count(*) into v_got from public.claim_scheduled_text(v_text);
  if v_got <> 0 then
    failures := failures ||
      format('FAILED: a second run claimed the same text and got %s rows - the client would be texted twice', v_got)::text;
  else
    raise notice 'ok  a second run claiming the same text gets nothing, so it is sent once';
  end if;

  -- ── a recent claim is left alone ──────────────────────────
  select public.release_stale_text_claims() into v_freed;
  select status into v_status from public.sms_messages where id = v_text;
  if v_status <> 'Sending' then
    failures := failures ||
      'FAILED: a claim made a moment ago was handed back, which is the double send by another route'::text;
  else
    raise notice 'ok  a claim made a moment ago is left alone';
  end if;

  -- ── a claim left by a dead run comes back ─────────────────
  update public.sms_messages set claimed_at = now() - interval '2 hours' where id = v_text;
  select public.release_stale_text_claims() into v_freed;
  if v_freed < 1 then
    failures := failures || 'FAILED: a two-hour-old claim was not handed back'::text;
  end if;

  select status, claimed_at into v_status, v_claimed from public.sms_messages where id = v_text;
  if v_status <> 'Scheduled' or v_claimed is not null then
    failures := failures || format('FAILED: a handed-back text is %s with claimed_at %s', v_status, v_claimed)::text;
  else
    raise notice 'ok  a claim left by a run that died is handed back, cleanly';
  end if;

  select count(*) into v_got from public.claim_scheduled_text(v_text);
  if v_got <> 1 then
    failures := failures || 'FAILED: a handed-back text could not be claimed again, so it would never be sent'::text;
  else
    raise notice 'ok  and can then be claimed and sent by the next run';
  end if;

  -- ── what cannot be claimed ────────────────────────────────
  -- Booked as a scheduled text and then marked sent, which is the order the
  -- real flow goes in. Inserting one already marked Sent is read as an
  -- immediate send and refused outside the 8am-9pm window, which would make
  -- this fixture fail in the evening and pass in the morning.
  insert into public.sms_messages (client_id, phone, body, kind, status, send_after, direction, created_by)
  values (v_client, '+15555550123', 'ZZ already sent', 'Manual', 'Scheduled',
          public.next_text_window(now() + interval '5 minutes'), 'Outgoing', v_staff)
  returning id into v_other;
  update public.sms_messages
     set status = 'Sent', send_after = now() - interval '1 hour' where id = v_other;

  select count(*) into v_got from public.claim_scheduled_text(v_other);
  if v_got <> 0 then
    failures := failures || 'FAILED: a text already Sent was claimed for sending'::text;
  else
    raise notice 'ok  a text that has already gone cannot be claimed again';
  end if;

  -- ── and nobody but the sending run may call it ────────────
  if has_function_privilege('anon', 'public.claim_scheduled_text(uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.claim_scheduled_text(uuid)', 'execute') then
    failures := failures || 'FAILED: anon or authenticated may claim a text for sending'::text;
  else
    raise notice 'ok  neither anon nor a signed-in person can claim a text';
  end if;

  if has_function_privilege('anon', 'public.release_stale_text_claims(interval)', 'execute')
     or has_function_privilege('authenticated', 'public.release_stale_text_claims(interval)', 'execute') then
    failures := failures || 'FAILED: anon or authenticated may hand back claims'::text;
  else
    raise notice 'ok  and neither can hand claims back';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- TEXT CLAIM VERIFIED ---';
end $$;

rollback;
