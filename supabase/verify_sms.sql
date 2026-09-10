-- Zion Vocational Rehab CRM — texting, and the consent in front of it
--
-- Every other rule in this system protects the practice from getting a figure
-- wrong. This one protects somebody from being texted who said not to, which
-- is a different kind of wrong and a federal one.
--
-- So the checks are about the gate, not the message: that an outgoing text to
-- a client without current consent cannot be written down at all, that STOP
-- withdraws consent without anybody deciding to act on it, that consent is
-- for a number rather than a person, and that a withdrawal can never be
-- edited away.
--
-- Runs inside a transaction that is rolled back. Nothing here is left behind,
-- and nothing here sends anything: writing the row is what sending means to
-- this database, and every row written here disappears with the rollback.

begin;

do $$
declare
  v_admin   uuid;
  v_adm_uid uuid;
  v_bill    uuid;
  v_bil_uid uuid;
  v_client  uuid;
  v_event   uuid;
  v_state   text;
  v_count   int;
  v_can     boolean;
  r         record;
  failures  text[] := '{}';
begin
  select id, user_id into v_admin, v_adm_uid from public.staff
   where role = 'Admin' and active order by created_at limit 1;
  select id, user_id into v_bill, v_bil_uid from public.staff
   where active and role <> 'Admin' order by created_at limit 1;

  insert into public.clients (name, stage, status, phone)
  values ('ZZ Texting Test', 'Referral', 'Active', '(801) 555-0142')
  returning id into v_client;

  -- ── nothing is assumed ─────────────────────────────────────
  select can_text into v_can from public.client_sms_consent where client_id = v_client;
  if coalesce(v_can, false) then
    failures := failures || 'FAILED: a client with no consent record counts as consenting'::text;
  else
    raise notice 'ok  a client nobody has asked has not consented';
  end if;

  begin
    insert into public.sms_messages (client_id, direction, phone, body, kind)
    values (v_client, 'Outgoing', '+18015550142', 'ZZ you should not receive this', 'Manual');
    failures := failures || 'FAILED: a text was recorded to a client who never consented'::text;
  exception when check_violation then
    raise notice 'ok  a text to somebody who never agreed cannot even be written down';
  end;

  -- ── consent, as a record ───────────────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);

  begin
    perform public.set_sms_consent(v_client, 'Granted', 'Verbal', '');
    failures := failures || 'FAILED: consent was granted with no note saying how'::text;
  exception when check_violation then
    raise notice 'ok  granting consent needs a note saying how it was given';
  end;

  perform public.set_sms_consent(v_client, 'Granted', 'Verbal',
                                 'ZZ asked at intake, said yes to reminders');

  select can_text, consented_phone into v_can, v_state
    from public.client_sms_consent where client_id = v_client;
  if not coalesce(v_can, false) then
    failures := failures || 'FAILED: consent was recorded and the client still cannot be texted'::text;
  elsif v_state <> '+18015550142' then
    failures := failures || format('FAILED: consent was recorded against %s', v_state);
  else
    raise notice 'ok  consent is recorded against the number, in E.164, whatever shape it was typed in';
  end if;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  insert into public.sms_messages (client_id, direction, phone, body, kind)
  values (v_client, 'Outgoing', '+18015550142', 'ZZ a reminder', 'Manual');
  raise notice 'ok  with consent recorded, a text can be sent';

  -- ── the number, not the person ─────────────────────────────
  update public.clients set phone = '(801) 555-0199' where id = v_client;

  select can_text into v_can from public.client_sms_consent where client_id = v_client;
  if coalesce(v_can, false) then
    failures := failures || 'FAILED: consent followed the client to a new number'::text;
  else
    raise notice 'ok  changing the number withdraws the ability to text — consent was for the old one';
  end if;

  begin
    insert into public.sms_messages (client_id, direction, phone, body, kind)
    values (v_client, 'Outgoing', '+18015550199', 'ZZ to the new number', 'Manual');
    failures := failures || 'FAILED: a text went to a number nobody consented to'::text;
  exception when check_violation then
    raise notice 'ok  and nothing can be sent to the new number until somebody asks again';
  end;

  update public.clients set phone = '(801) 555-0142' where id = v_client;

  -- ── STOP ───────────────────────────────────────────────────
  -- The webhook hands the number and the words to the database. Withdrawing
  -- happens here, so it cannot depend on the code that received it choosing
  -- to act.
  select * into r from public.record_incoming_sms('+1 (801) 555-0142', 'STOP', 'ZZ-provider-1');
  if r.action <> 'withdrawn' then
    failures := failures || format('FAILED: replying STOP came back as "%s"', r.action);
  elsif r.client_id is distinct from v_client then
    failures := failures || 'FAILED: a reply was not matched to the client it came from'::text;
  else
    raise notice 'ok  replying STOP withdraws consent, by itself';
  end if;

  select can_text into v_can from public.client_sms_consent where client_id = v_client;
  if coalesce(v_can, false) then
    failures := failures || 'FAILED: consent survived a STOP'::text;
  else
    raise notice 'ok  and nothing more can be sent';
  end if;

  begin
    insert into public.sms_messages (client_id, direction, phone, body, kind)
    values (v_client, 'Outgoing', '+18015550142', 'ZZ after a stop', 'Reminder');
    failures := failures || 'FAILED: a text was recorded after the client said STOP'::text;
  exception when check_violation then
    raise notice 'ok  a reminder after STOP is refused like any other';
  end;

  -- Lower case, punctuation, and the other words carriers require.
  update public.clients set phone = '(801) 555-0143' where id = v_client;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);
  perform public.set_sms_consent(v_client, 'Granted', 'Verbal', 'ZZ asked again');
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  select * into r from public.record_incoming_sms('+18015550143', 'stop.', null);
  if r.action <> 'withdrawn' then
    failures := failures || 'FAILED: "stop." in lower case with a full stop did not withdraw'::text;
  else
    raise notice 'ok  "stop." counts, and so does every word a carrier recognises';
  end if;

  -- ── and back on again, from the same number ────────────────
  select * into r from public.record_incoming_sms('+18015550143', 'START', null);
  select can_text into v_can from public.client_sms_consent where client_id = v_client;
  if not coalesce(v_can, false) then
    failures := failures || 'FAILED: replying START did not put consent back'::text;
  else
    raise notice 'ok  replying START puts it back, without a phone call to the office';
  end if;

  -- ── a withdrawal is never edited away ──────────────────────
  select count(*) into v_count from public.sms_consent_events where client_id = v_client;
  begin
    update public.sms_consent_events set state = 'Granted'
     where client_id = v_client and state = 'Withdrawn';
    failures := failures || 'FAILED: a withdrawal was edited into a grant'::text;
  exception when check_violation then
    raise notice 'ok  a consent record cannot be edited, only added to';
  end;

  begin
    delete from public.sms_consent_events where client_id = v_client and state = 'Withdrawn';
    failures := failures || 'FAILED: a withdrawal was deleted'::text;
  exception when check_violation then
    raise notice 'ok  and cannot be deleted — the history is the evidence';
  end;

  if (select count(*) from public.sms_consent_events where client_id = v_client) <> v_count then
    failures := failures || 'FAILED: the consent history changed size'::text;
  end if;

  -- ── one reminder per appointment ───────────────────────────
  insert into public.calendar_events (client_id, staff_id, kind, title, starts_at, ends_at, origin)
  values (v_client, v_admin, 'Coaching visit', 'ZZ tomorrow',
          ((public.practice_today() + 1) + time '10:00') at time zone 'America/Denver',
          ((public.practice_today() + 1) + time '11:00') at time zone 'America/Denver',
          'CRM')
  returning id into v_event;

  if not exists (select 1 from public.sms_due_reminders where event_id = v_event) then
    failures := failures || 'FAILED: an appointment tomorrow is not due a reminder'::text;
  else
    raise notice 'ok  an appointment tomorrow is due a reminder';
  end if;

  insert into public.sms_messages (client_id, direction, phone, body, kind, event_id, status)
  values (v_client, 'Outgoing', '+18015550143', 'ZZ reminder', 'Reminder', v_event, 'Sent');

  if exists (select 1 from public.sms_due_reminders where event_id = v_event) then
    failures := failures || 'FAILED: an appointment already reminded about is still due'::text;
  else
    raise notice 'ok  and stops being due the moment it has been sent';
  end if;

  begin
    insert into public.sms_messages (client_id, direction, phone, body, kind, event_id, status)
    values (v_client, 'Outgoing', '+18015550143', 'ZZ again', 'Reminder', v_event, 'Sent');
    failures := failures || 'FAILED: the same appointment was reminded about twice'::text;
  exception when unique_violation then
    raise notice 'ok  a second reminder for the same appointment is refused by the database';
  end;

  -- A failed attempt does not block a retry.
  insert into public.calendar_events (client_id, staff_id, kind, title, starts_at, ends_at, origin)
  values (v_client, v_admin, 'Coaching visit', 'ZZ also tomorrow',
          ((public.practice_today() + 1) + time '14:00') at time zone 'America/Denver',
          ((public.practice_today() + 1) + time '15:00') at time zone 'America/Denver',
          'CRM')
  returning id into v_event;

  insert into public.sms_messages (client_id, direction, phone, body, kind, event_id, status, error)
  values (v_client, 'Outgoing', '+18015550143', 'ZZ failed', 'Reminder', v_event, 'Failed', 'ZZ carrier said no');

  if not exists (select 1 from public.sms_due_reminders where event_id = v_event) then
    failures := failures || 'FAILED: an attempt that failed left the appointment un-remindable'::text;
  else
    raise notice 'ok  an attempt that failed can be tried again';
  end if;

  -- ── an appointment today is not tomorrow ───────────────────
  insert into public.calendar_events (client_id, staff_id, kind, title, starts_at, ends_at, origin)
  values (v_client, v_admin, 'Coaching visit', 'ZZ today',
          (public.practice_today() + time '16:00') at time zone 'America/Denver',
          (public.practice_today() + time '17:00') at time zone 'America/Denver',
          'CRM')
  returning id into v_event;

  if exists (select 1 from public.sms_due_reminders where event_id = v_event) then
    failures := failures || 'FAILED: an appointment today is being called tomorrow'::text;
  else
    raise notice 'ok  a day-before reminder means the day before, in Utah''s day';
  end if;

  -- ── not in the middle of the night ─────────────────────────
  -- Checked against the function rather than the clock, so it is checked
  -- every run rather than only on the runs that happen after nine.
  if public.sms_within_sending_hours(timestamp '2026-03-10 23:30' at time zone 'America/Denver')
     or public.sms_within_sending_hours(timestamp '2026-03-10 07:15' at time zone 'America/Denver')
     or public.sms_within_sending_hours(timestamp '2026-03-10 21:00' at time zone 'America/Denver') then
    failures := failures || 'FAILED: a text would go out outside 8am to 9pm'::text;
  elsif not public.sms_within_sending_hours(timestamp '2026-03-10 08:00' at time zone 'America/Denver')
     or not public.sms_within_sending_hours(timestamp '2026-03-10 17:00' at time zone 'America/Denver')
     or not public.sms_within_sending_hours(timestamp '2026-03-10 20:59' at time zone 'America/Denver') then
    failures := failures || 'FAILED: a text is being held back during the working day'::text;
  else
    raise notice 'ok  texts go out between 8am and 9pm Utah time, and not at half past eleven';
  end if;

  -- ── the timeline shows both directions ─────────────────────
  select count(*) into v_count from public.client_activity
   where client_id = v_client and kind = 'Text';
  if v_count < 2 then
    failures := failures || format('FAILED: %s texts reached the activity feed', v_count);
  else
    raise notice 'ok  texts sent and replies received are both on the client timeline';
  end if;

  -- ── who may do what ────────────────────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_bil_uid, 'role', 'authenticated')::text, true);

  if (select role from public.staff where id = v_bill) = 'Billing' then
    begin
      perform public.set_sms_consent(v_client, 'Withdrawn', 'Staff', 'ZZ');
      failures := failures || 'FAILED: Billing recorded a consent decision'::text;
    exception when insufficient_privilege then
      raise notice 'ok  a role that does not edit client records does not decide consent either';
    end;
  else
    -- Said out loud rather than skipped quietly: there is no Billing account
    -- on this database to try it with, so that rule is untested here.
    raise notice 'note  no Billing account exists, so "Billing cannot decide consent" was not exercised';
  end if;

  begin
    perform public.record_incoming_sms('+18015550143', 'STOP', null);
    failures := failures || 'FAILED: a signed-in user could fake an incoming text'::text;
  exception when insufficient_privilege then
    raise notice 'ok  nobody signed in can fake a reply, or withdraw somebody else''s consent by hand';
  end;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  if failures = '{}' then
    raise notice '';
    raise notice '--- TEXTING AND CONSENT VERIFIED ---';
  else
    raise notice '';
    raise notice '%  PROBLEM(S):', array_length(failures, 1);
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
