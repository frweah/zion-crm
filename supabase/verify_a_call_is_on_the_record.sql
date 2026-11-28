-- Zion Vocational Rehab CRM — a call is on the record (0394-0398)
--
-- The client line is moving into the browser, and a call is a thing that
-- happens whether or not anybody is there for it. What has to hold:
--
--   a call arriving is matched to whoever that number belongs to, the
--   client's own numbers before their contacts';
--
--   an answered call is a contact on the client's month and says who spoke
--   to them; a call nobody picked up is on the record and counts towards
--   nothing, because nothing happened;
--
--   a voicemail is **the client speaking**. It does not count as a contact -
--   nobody from the practice was there - and the threads board reads it as
--   somebody waiting for an answer rather than as the practice having
--   answered. That last one is the frightening half: a voicemail written as
--   the practice's own line would take the row *off* the board rather than
--   putting it on wrongly, which is the kind of mistake nobody reports;
--
--   a message from a number nobody has placed is still on the record;
--
--   a voicemail's own words reach its line when Azure reads it, and a
--   meeting recording's words still never leave the recording (the owner's
--   rule of 14 November);
--
--   whose desk rings is the practice's to set - nobody, Admin only, or
--   every seat that texts clients - and 'off' means no desk rings at all;
--
--   a records request carries the call row, the audio and the words **once**,
--   not the message twice;
--
--   and nothing on a screen can say a call happened.
--
-- Everything is rolled back.

begin;

do $$
declare
  failures   text[] := array[]::text[];
  v_mark     integer;
  v_counsel  uuid;
  v_client   uuid;
  v_quiet    uuid;
  v_stranger uuid;
  v_contact  uuid;
  v_staff    uuid;
  v_uid      uuid := gen_random_uuid();
  v_coach    uuid;
  v_call     uuid;
  v_line     uuid;
  v_att      uuid;
  v_rec      uuid;
  v_system   uuid;
  r          record;
  v_n        integer;
  v_said     text;
  v_hours    integer;
  v_other    uuid;
  v_bundle   jsonb;
begin
  -- ── the practice, in miniature ─────────────────────────────
  insert into public.staff (name, email, role, active)
  values ('ZZ Phones Admin', 'zz-phones-admin@example.test', 'Admin', true) returning id into v_staff;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data,
                          created_at, updated_at)
  values (v_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-phones-admin@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_uid where id = v_staff;

  -- A seat that does not text clients, so it should not be rung either.
  insert into public.staff (name, email, role, active)
  values ('ZZ Phones Coach', 'zz-phones-coach@example.test', 'Job Coach', true) returning id into v_coach;

  insert into public.counselors (name, email, office)
  values ('ZQ Phones Counselor', 'zq-phones@example.test', 'Salt Lake City') returning id into v_counsel;

  insert into public.clients (name, stage, status, counselor_id, phone, assigned_staff_id)
  values ('ZZ Phones Client', 'Job Development', 'Active', v_counsel, '+13855550301', v_staff)
  returning id into v_client;
  insert into public.clients (name, stage, status, counselor_id, phone)
  values ('ZZ Phones Quiet', 'Job Search', 'Active', v_counsel, '+13855550302')
  returning id into v_quiet;

  -- Their partner, with their own number: a text or a call from it is the
  -- client's record, but it is not the client speaking.
  insert into public.client_contacts (client_id, name, phone, relationship, may_speak_for)
  values (v_client, 'ZQ Phones Partner', '+13855550303', 'Partner', true) returning id into v_contact;

  /**
   * And somebody else's contact, on this client's own number.
   *
   * The case the owner's ordering rule exists for: a number that is one
   * client's own and another client's relative, where the wrong order labels
   * a caller as somebody else's daughter-in-law. It has to be another
   * client's contact - the database refuses a contact on the number the same
   * client is texted at, with "that is the number this client is texted at,
   * so it cannot be a contact as well", which is a better rule than the one
   * this fixture first tried to break.
   *
   * Without a number two records hold, reversing the order changes nothing
   * and a fault that reverses it passes. That is what happened on the first
   * run, and it is the same shape as the label cap that was never exercised
   * in the Friday work.
   */
  insert into public.clients (name, stage, status, counselor_id, phone)
  values ('ZZ Phones Neighbour', 'Intake', 'Active', v_counsel, '+13855550304')
  returning id into v_stranger;
  insert into public.client_contacts (client_id, name, phone, relationship, may_speak_for)
  values (v_stranger, 'ZQ Phones Daughter', '+13855550301', 'Daughter', true);

  -- ── 1. who is calling ──────────────────────────────────────
  v_mark := coalesce(array_length(failures, 1), 0);

  select * into r from public.who_is_calling('+13855550301');
  if r.client_id is distinct from v_client or r.contact_id is not null then
    failures := failures || 'FAILED: a call from the client''s own number was not placed as theirs'::text;
  elsif r.label is distinct from 'ZZ Phones Client' then
    failures := failures || format('FAILED: the client''s own call is labelled %L', r.label)::text;
  end if;

  select * into r from public.who_is_calling('+13855550303');
  if r.client_id is distinct from v_client or r.contact_id is distinct from v_contact then
    failures := failures || 'FAILED: a call from a contact''s number was not filed on the client'::text;
  elsif r.label not like '%Partner%' then
    failures := failures ||
      format('FAILED: a contact''s call is labelled %L, which does not say whose number it is', r.label)::text;
  end if;

  select * into r from public.who_is_calling('+13855559999');
  if r.client_id is not null then
    failures := failures || 'FAILED: a number nobody holds was matched to a client'::text;
  end if;

  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  a caller is named, their own number before their partner''s, and a stranger is a stranger';
  end if;

  -- ── 2. who is at their desk ────────────────────────────────
  --
  -- Asked with the line on 'all', because this section is about the
  -- freshness window and the roles. Whose desk the mode allows is section 2b,
  -- and the default is 'off' - which this section inherited on the first run
  -- and reported as "somebody who just said they were there is not on the
  -- phones".
  v_mark := coalesce(array_length(failures, 1), 0);
  update public.org_settings set voice_mode = 'all' where id = true;

  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
  perform public.voice_here();
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);

  select count(*) into v_n from public.staff_on_the_phones() where staff_id = v_staff;
  if v_n <> 1 then
    failures := failures || 'FAILED: somebody who just said they were there is not on the phones'::text;
  end if;

  -- A beat older than the window is not somebody at a desk. Ringing a
  -- browser that is not there is a caller waiting twenty-five seconds for a
  -- voicemail they could have had at once.
  update public.staff_voice_presence
     set at = now() - make_interval(secs => public.voice_presence_seconds() + 30)
   where staff_id = v_staff;
  select count(*) into v_n from public.staff_on_the_phones() where staff_id = v_staff;
  if v_n <> 0 then
    failures := failures || 'FAILED: a desk that stopped answering an hour ago is still rung'::text;
  end if;
  update public.staff_voice_presence set at = now() where staff_id = v_staff;

  -- And a seat that does not text clients is not rung either.
  insert into public.staff_voice_presence (staff_id) values (v_coach);
  select count(*) into v_n from public.staff_on_the_phones() where staff_id = v_coach;
  if v_n <> 0 then
    failures := failures ||
      'FAILED: the client line rings a seat that may not even text a client'::text;
  end if;

  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  a fresh beat is on the phones, a stale one is not, and only seats that text are rung';
  end if;

  -- ── 2b. and whose desk rings is the practice's to say ─────
  --
  -- Three modes, and 'off' is the one worth asserting hardest: the whole of
  -- part B was deployed with the line silent, so a mode that did not hold
  -- would have been a test number ringing the practice before anybody asked
  -- for it.
  v_mark := coalesce(array_length(failures, 1), 0);

  update public.org_settings set voice_mode = 'off' where id = true;
  select count(*) into v_n from public.staff_on_the_phones();
  if v_n <> 0 then
    failures := failures || format(
      'FAILED: the line is switched off and %s desk(s) still ring', v_n)::text;
  end if;

  -- Admin only: the owner's setting for running the proofs without the team
  -- watching a test line ring.
  update public.org_settings set voice_mode = 'admin' where id = true;
  select count(*) into v_n from public.staff_on_the_phones() where staff_id = v_staff;
  if v_n <> 1 then
    failures := failures || 'FAILED: the line rings Admin only and the Admin desk does not ring'::text;
  end if;
  insert into public.staff (name, email, role, active)
  values ('ZZ Phones Search', 'zz-phones-search@example.test', 'Job Search', true)
  returning id into v_other;
  insert into public.staff_voice_presence (staff_id) values (v_other);
  select count(*) into v_n from public.staff_on_the_phones() where staff_id = v_other;
  if v_n <> 0 then
    failures := failures ||
      'FAILED: the line rings Admin only and a Job Search desk rings too'::text;
  end if;

  -- And everybody, which is the cutover setting.
  update public.org_settings set voice_mode = 'all' where id = true;
  select count(*) into v_n from public.staff_on_the_phones() where staff_id = v_other;
  if v_n <> 1 then
    failures := failures || 'FAILED: the line rings everybody and a Job Search desk does not'::text;
  end if;
  select count(*) into v_n from public.staff_on_the_phones() where staff_id = v_coach;
  if v_n <> 0 then
    failures := failures ||
      'FAILED: even on "all" the line rings a seat that may not text a client'::text;
  end if;

  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  off rings nobody, admin rings Admin, and all still leaves out seats that do not text';
  end if;

  -- ── 3. an answered call is a contact; a missed one is not ──
  v_mark := coalesce(array_length(failures, 1), 0);

  perform public.record_call_started('CAzz0001', 'Inbound', '+13855550301', '+13854063432');
  perform public.record_call_answered('CAzz0001', v_staff::text);
  v_line := public.record_call_ended('CAzz0001', 95, null);

  select * into r from public.contact_log where id = v_line;
  if r.id is null then
    failures := failures || 'FAILED: an answered call left no line on the client''s month'::text;
  else
    if r.method is distinct from 'Call' then
      failures := failures || format('FAILED: an answered call is logged as %L', r.method)::text;
    end if;
    if r.direction is distinct from 'Inbound' then
      failures := failures || format('FAILED: an answered inbound call says direction %L',
                                     coalesce(r.direction, 'nothing'))::text;
    end if;
    if not public.is_real_contact(r.method) then
      failures := failures || 'FAILED: an answered call does not count as a contact on the month'::text;
    end if;
    if r.outcome not like '%ZZ Phones Admin%' then
      failures := failures ||
        format('FAILED: an answered call does not say who spoke to them: %L', r.outcome)::text;
    end if;
  end if;

  -- Twice, because Twilio retries. One call is one line.
  perform public.record_call_ended('CAzz0001', 95, null);
  select count(*) into v_n from public.contact_log where source = 'Call' and source_key = 'CAzz0001';
  if v_n <> 1 then
    failures := failures || format('FAILED: a retried webhook wrote %s lines for one call', v_n)::text;
  end if;

  perform public.record_call_started('CAzz0002', 'Inbound', '+13855550301', '+13854063432');
  perform public.record_call_ended('CAzz0002', 0, 'Missed');
  select count(*) into v_n from public.contact_log where source = 'Call' and source_key = 'CAzz0002';
  if v_n <> 0 then
    failures := failures ||
      'FAILED: a call nobody picked up was counted as a contact with the client'::text;
  end if;
  select state into v_said from public.voice_calls where call_sid = 'CAzz0002';
  if v_said is distinct from 'Missed' then
    failures := failures || format('FAILED: a missed call is on the record as %L', v_said)::text;
  end if;

  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  an answered call is a contact and says who spoke; a missed one counts towards nothing';
  end if;

  -- ── 4. a voicemail is the client speaking ──────────────────
  v_mark := coalesce(array_length(failures, 1), 0);

  perform public.record_call_started('CAzz0003', 'Inbound', '+13855550301', '+13854063432');
  v_line := public.record_voicemail('CAzz0003', 'REzz0003', 42);

  select * into r from public.contact_log where id = v_line;
  if r.id is null then
    failures := failures || 'FAILED: a voicemail left nothing on the client''s record'::text;
  else
    if r.method is distinct from 'Voicemail' then
      failures := failures || format('FAILED: a voicemail is logged as %L', r.method)::text;
    end if;
    if public.is_real_contact(r.method) then
      failures := failures ||
        'FAILED: a voicemail counts as a contact on the month, and nobody from the practice spoke'::text;
    end if;
    if r.direction is distinct from 'Inbound' then
      failures := failures || format('FAILED: a voicemail says direction %L',
                                     coalesce(r.direction, 'nothing'))::text;
    end if;
    if r.outcome not like '%not read yet%' then
      failures := failures ||
        format('FAILED: a voicemail nobody has read yet says %L', r.outcome)::text;
    end if;
  end if;

  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  a voicemail is on the record, in the client''s direction, and counts towards nothing';
  end if;

  -- ── 5. and the board knows they are waiting ────────────────
  --
  -- The half worth being frightened of. A voicemail read as the practice's
  -- own line takes the row off the board rather than putting it on wrongly,
  -- and a row that is not there is a client nobody is reminded about.
  v_mark := coalesce(array_length(failures, 1), 0);

  -- A client the practice has not spoken to, who leaves a message. Two
  -- things at once: they appear on the board at all, which before 0396 they
  -- did not, and they appear as waiting.
  perform public.record_call_started('CAzz0004', 'Inbound', '+13855550302', '+13854063432');
  perform public.record_voicemail('CAzz0004', 'REzz0004', 20);

  select count(*) into v_n from public.client_threads_board() where client_id = v_quiet;
  if v_n <> 1 then
    failures := failures ||
      'FAILED: a client whose only word to the practice is a voicemail is not on the board'::text;
  else
    select waiting_hours, grp, last_channel into r
      from public.client_threads_board() where client_id = v_quiet;
    if r.waiting_hours is null then
      failures := failures ||
        'FAILED: a client who left a message is not shown as waiting for a reply'::text;
    elsif r.grp is distinct from 'needs-reply' then
      failures := failures ||
        format('FAILED: a client who left a message is in the %L group', r.grp)::text;
    elsif r.last_channel is distinct from 'Voicemail' then
      failures := failures ||
        format('FAILED: the newest thing is a voicemail and the row says %L', r.last_channel)::text;
    end if;
  end if;

  -- And once somebody rings them back, they are not waiting any more. The
  -- same day-granular rule, read the other way up: an answered call dated
  -- today is the practice's answer to a message left today.
  perform public.record_call_started('CAzz0005', 'Outbound', '+13854063432', '+13855550302');
  perform public.record_call_answered('CAzz0005', v_staff::text);
  perform public.record_call_ended('CAzz0005', 120, null);
  select waiting_hours into r from public.client_threads_board() where client_id = v_quiet;
  if r.waiting_hours is not null then
    failures := failures ||
      'FAILED: the practice rang them back and the board still says they are waiting'::text;
  end if;

  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  a voicemail puts them on the board, and a call back takes them off it';
  end if;

  -- ── 6. a message from a number nobody has placed ──────────
  v_mark := coalesce(array_length(failures, 1), 0);

  perform public.record_call_started('CAzz0006', 'Inbound', '+13855559999', '+13854063432');
  v_line := public.record_voicemail('CAzz0006', 'REzz0006', 15);
  if v_line is not null then
    failures := failures ||
      'FAILED: a message from an unplaced number was put on somebody''s record'::text;
  end if;
  select client_id, state, recording_sid into r from public.voice_calls where call_sid = 'CAzz0006';
  if r.client_id is not null or r.state is distinct from 'Voicemail' or r.recording_sid is null then
    failures := failures ||
      'FAILED: a message from an unplaced number is not on the call record for somebody to place'::text;
  end if;

  begin
    perform public.file_voicemail('CAzz0006', 'zz/unplaced.mp3', 'ZZ unplaced.mp3', 'audio/mpeg', 1000);
    failures := failures ||
      'FAILED: a message with no client was filed in a client folder that does not exist'::text;
  exception when others then
    null;
  end;

  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  a message from a number nobody holds is on the record and on nobody''s file';
  end if;

  -- ── 7. the words, and only a voicemail's ──────────────────
  v_mark := coalesce(array_length(failures, 1), 0);

  select * into r from public.file_voicemail(
    'CAzz0003', 'zz/clients/voicemail.mp3', 'ZZ voicemail.mp3', 'audio/mpeg', 24000,
    'zzsha256voicemail', 42);
  v_att := r.filed_attachment;
  v_rec := r.filed_recording;

  select category, source into r from public.attachments where id = v_att;
  if r.category is distinct from 'Voicemail' then
    failures := failures || format('FAILED: a voicemail is filed as %L', r.category)::text;
  end if;
  if r.source is distinct from 'Phone' then
    failures := failures || format('FAILED: a voicemail is filed from %L', r.source)::text;
  end if;

  -- Read on the practice's own account, not on whoever was on the phones.
  select id into v_system from public.staff where is_system and active order by created_at limit 1;
  select staff_id, state into r from public.recordings where id = v_rec;
  if v_system is not null and r.staff_id is distinct from v_system then
    failures := failures ||
      'FAILED: reading a voicemail is charged to a person rather than to the practice'::text;
  end if;
  if r.state is distinct from 'Waiting' then
    failures := failures || format('FAILED: a filed voicemail is %L, so nothing will read it', r.state)::text;
  end if;

  -- Filed twice is filed once: the recording webhook is retried like any other.
  select * into r from public.file_voicemail(
    'CAzz0003', 'zz/clients/voicemail-again.mp3', 'ZZ voicemail.mp3', 'audio/mpeg', 24000,
    'zzsha256voicemail', 42);
  if r.filed_attachment is distinct from v_att then
    failures := failures || 'FAILED: a retried recording webhook filed the message twice'::text;
  end if;

  -- Azure answers, and the client's words land on their line.
  update public.recordings set transcript = 'ZZ it is too far by bus, can we talk Monday'
   where id = v_rec;
  select outcome into v_said from public.contact_log
   where source = 'Call' and source_key = 'CAzz0003';
  if v_said not like '%too far by bus%' then
    failures := failures ||
      format('FAILED: the message was read and the line still says %L', v_said)::text;
  end if;

  /**
   * And the other half of the 14 November rule.
   *
   * A meeting recording is an hour of somebody's life - their health, their
   * family, what the state pays them, what their lawyer said - and its
   * transcript never leaves the recording. The trigger that quotes a
   * voicemail must not quote one of those, which before 0397 was true only
   * because nothing happened to point a call at one.
   */
  insert into public.attachments
    (client_id, storage_path, filename, mime_type, size_bytes, category, uploaded_by, uploaded_by_name)
  values (v_client, 'zz/clients/meeting.m4a', 'ZZ meeting.m4a', 'audio/mp4', 700000,
          'Recording', v_staff, 'ZZ Phones Admin')
  returning id into v_att;
  insert into public.recordings (attachment_id, client_id, staff_id, state)
  values (v_att, v_client, v_staff, 'Reading') returning id into v_rec;
  -- Pointed at the voicemail's own call, which is the mistake being refused.
  update public.voice_calls set recording_id = v_rec where call_sid = 'CAzz0003';
  update public.recordings
     set transcript = 'ZZ her mother drove her and the new medication made mornings hard'
   where id = v_rec;
  select outcome into v_said from public.contact_log
   where source = 'Call' and source_key = 'CAzz0003';
  if v_said like '%medication%' then
    failures := failures ||
      'FAILED: an hour of somebody''s life was copied onto their contact log'::text;
  end if;

  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  a voicemail''s words reach its line, and a meeting''s words still never leave the recording';
  end if;

  -- ── 8. the calls are in the bundle ────────────────────────
  v_mark := coalesce(array_length(failures, 1), 0);

  -- As the Admin: only Admin produces a records request, and the function
  -- says so rather than quietly handing one over.
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
  v_bundle := public.records_request_bundle(v_client, 'ZZ verify');
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);

  select jsonb_array_length(coalesce(v_bundle -> 'calls', '[]'::jsonb)) into v_n;
  if coalesce(v_n, 0) = 0 then
    failures := failures ||
      'FAILED: a client asking for everything the practice holds is not told about their calls'::text;
  end if;

  /**
   * And the message once, not twice.
   *
   * `counselor_contacts` hands over the whole contact-log row, so a
   * voicemail's own words are already in the bundle as that line's outcome.
   * 0398 put them in the calls section as well, which answered a client with
   * their message twice; 0402 took them back out. The call row keeps what
   * only it knows - which way, when, how long - and the audio is in `files`,
   * because a voicemail is filed as an attachment like anything else.
   *
   * Counted across the whole document rather than per section, so moving the
   * duplication somewhere else does not pass.
   */
  select count(*) into v_n from regexp_matches(v_bundle::text, 'too far by bus', 'g');
  if v_n <> 1 then
    failures := failures || format(
      'FAILED: a records request carries the client''s message %s time(s), and it should carry it once',
      v_n)::text;
  end if;

  -- And the recording itself, as a file on their record: a client told about
  -- a message they cannot hear has not been told everything.
  if v_bundle::text not like '%Voicemail%' then
    failures := failures ||
      'FAILED: the recording is not in the bundle, so the client cannot hear what they said'::text;
  end if;

  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  a client''s calls answer a records request';
  end if;

  -- ── 9. and no screen says a call happened ─────────────────
  v_mark := coalesce(array_length(failures, 1), 0);

  select count(*) into v_n from information_schema.routine_privileges
   where routine_schema = 'public'
     and routine_name in ('record_call_started', 'record_call_answered', 'record_call_ended',
                          'record_voicemail', 'file_voicemail')
     and grantee in ('anon', 'public', 'authenticated');
  if v_n <> 0 then
    failures := failures || format(
      'FAILED: %s grant(s) let a screen say a call happened', v_n)::text;
  end if;

  -- A call is a thing that happened, so nothing writes the table by hand.
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
  -- The role, not just the claim: row level security does not apply to the
  -- table's owner, and a verify script on a direct connection is the owner.
  -- Without this the insert succeeds and the script reports a hole that is
  -- not there.
  perform set_config('role', 'authenticated', true);
  begin
    insert into public.voice_calls (call_sid, direction, from_phone, to_phone)
    values ('CAzz0099', 'Inbound', '+13855550301', '+13854063432');
    failures := failures || 'FAILED: a signed-in person wrote a call into the record by hand'::text;
  exception when others then
    null;
  end;
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);

  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  only the webhooks write a call, and nothing on a screen does';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception E'\n%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- A CALL IS ON THE RECORD VERIFIED ---';
end $$;

rollback;
