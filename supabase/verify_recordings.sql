-- Zion Vocational Rehab CRM — a recording is read, and then confirmed
-- (0344, 0345)
--
-- What has to hold:
--
--   **Nothing a machine made of a conversation is on the client's record
--   until a person confirms it.** A recording that has been read and drafted
--   has no contact log entry and no note against it, and confirming writes
--   exactly one of each, under the name of whoever confirmed.
--
--   A recording is restricted, whatever the form said, and only the people
--   who may open a client's restricted documents may read a transcript or
--   confirm one.
--
--   The cost guard holds a recording before Azure is paid, says why, and
--   holding one costs nothing. Letting a held one through is Admin's.
--
--   An empty reading is a reading. A failure is not, and three failures stop
--   the asking.
--
--   Setting one aside needs a reason, and a confirmed one cannot be undone
--   that way.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_admin uuid; v_admin_uid uuid := gen_random_uuid();
  v_coach uuid; v_coach_uid uuid := gen_random_uuid();
  v_client uuid;
  v_att uuid; v_att2 uuid; v_pdf uuid;
  v_rec uuid; v_rec2 uuid; v_rec3 uuid; v_again uuid;
  v_att3 uuid;
  v_text text; v_n integer; v_state text; v_bool boolean;
  v_allowed integer;
  r record;
  failures text[] := '{}';
begin
  select o.recording_hours_per_person into v_allowed from public.org_settings o limit 1;

  insert into public.staff (name, email, role, active)
  values ('ZZ Recording Admin', 'zz-recording-admin@example.test', 'Admin', true) returning id into v_admin;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_admin_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-recording-admin@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_admin_uid where id = v_admin;

  insert into public.staff (name, email, role, active)
  values ('ZZ Recording Coach', 'zz-recording-coach@example.test', 'Job Coach', true) returning id into v_coach;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_coach_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-recording-coach@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_coach_uid where id = v_coach;

  -- Assigned to the Admin, so the coach is somebody with no claim on this
  -- client's restricted documents.
  insert into public.clients (name, stage, status, assigned_staff_id, phone)
  values ('ZZ Recorded Person', 'Job Search', 'Active', v_admin, '+13855550501') returning id into v_client;

  -- ── a recording is restricted, whatever the form said ──────
  insert into public.attachments
    (client_id, storage_path, filename, mime_type, size_bytes, category, restricted, uploaded_by, uploaded_by_name)
  values (v_client, 'zz/recording-one.m4a', 'ZZ meeting.m4a', 'audio/mp4', 1200000,
          'Other', false, v_admin, 'ZZ Recording Admin')
  returning id into v_att;

  select a.restricted into v_bool from public.attachments a where a.id = v_att;
  if not v_bool then
    failures := failures || 'FAILED: an audio attachment was recorded as not restricted'::text;
  else
    raise notice 'ok  a recording is restricted, whatever the form said';
  end if;

  -- And a document that is not audio is left alone.
  insert into public.attachments
    (client_id, storage_path, filename, mime_type, size_bytes, category, restricted, uploaded_by, uploaded_by_name)
  values (v_client, 'zz/not-audio.pdf', 'ZZ letter.pdf', 'application/pdf', 1000,
          'Other', false, v_admin, 'ZZ Recording Admin')
  returning id into v_pdf;
  select a.restricted into v_bool from public.attachments a where a.id = v_pdf;
  if v_bool then
    failures := failures || 'FAILED: a PDF was restricted by the recording rule'::text;
  else
    raise notice 'ok  and a document that is not audio is left as it was filed';
  end if;

  -- ── the queue ──────────────────────────────────────────────
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_admin_uid, 'role', 'authenticated')::text, true);

  v_rec := public.start_recording(v_att);
  v_again := public.start_recording(v_att);
  select count(*) into v_n from public.recordings g where g.attachment_id = v_att;
  if v_rec is distinct from v_again or v_n <> 1 then
    failures := failures || format('FAILED: uploading the same recording twice made %s rows', v_n)::text;
  else
    raise notice 'ok  the same recording twice is one row, which is what the phone retrying needs';
  end if;

  v_text := '';
  begin
    perform public.start_recording(v_pdf);
    v_text := 'allowed';
  exception when check_violation then
    v_text := sqlerrm;
  end;
  if v_text = 'allowed' then
    failures := failures || 'FAILED: a PDF was queued to be transcribed'::text;
  else
    raise notice 'ok  only a recording joins the queue';
  end if;

  -- ── the cost guard, before Azure is paid ───────────────────
  perform set_config('request.jwt.claims', '', true);
  update public.org_settings set recording_hours_per_person = 0;

  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  select count(*) into v_n from public.recordings_to_read() q where q.id = v_rec;
  select g.state, g.reason into v_state, v_text from public.recordings g where g.id = v_rec;
  if v_n <> 0 then
    failures := failures || 'FAILED: a recording over the month''s hours was handed to Azure'::text;
  elsif v_state <> 'Held' then
    failures := failures || format('FAILED: a recording over the month''s hours is %s', v_state)::text;
  elsif coalesce(btrim(v_text), '') = '' then
    failures := failures || 'FAILED: a held recording does not say why'::text;
  elsif (select g.minutes from public.recordings g where g.id = v_rec) is not null then
    failures := failures || 'FAILED: a held recording was counted as minutes read'::text;
  else
    raise notice 'ok  over the month''s hours it is held, with the reason, and nothing is paid for';
  end if;

  -- ── and letting one through is Admin''s ────────────────────
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_coach_uid, 'role', 'authenticated')::text, true);
  v_text := '';
  begin
    perform public.read_held_recording(v_rec);
    v_text := 'allowed';
  exception when insufficient_privilege then
    v_text := sqlerrm;
  end;
  if v_text = 'allowed' then
    failures := failures || 'FAILED: a Job Coach paid to read a held recording'::text;
  else
    raise notice 'ok  paying to read a held recording is Admin''s';
  end if;

  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_admin_uid, 'role', 'authenticated')::text, true);
  -- Caught, because with the guard gone there is nothing held to release and
  -- the refusal would stop the script instead of letting it report.
  v_text := '';
  begin
    perform public.read_held_recording(v_rec);
  exception when check_violation then
    v_text := sqlerrm;
  end;
  select g.state into v_state from public.recordings g where g.id = v_rec;
  if v_state <> 'Waiting' then
    failures := failures || format('FAILED: a released recording is %s (%s)', v_state, v_text)::text;
  else
    raise notice 'ok  and Admin can let one through';
  end if;

  update public.org_settings set recording_hours_per_person = coalesce(v_allowed, 20);

  -- ── an empty reading is a reading ──────────────────────────
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  perform public.recording_reading(v_rec, 'https://example.test/jobs/zz');
  perform public.recording_read(v_rec, '[]'::jsonb, '', 0.4);
  select g.state, g.reason into v_state, v_text from public.recordings g where g.id = v_rec;
  if v_state <> 'Read' then
    failures := failures || format('FAILED: a recording read with no words in it is %s', v_state)::text;
  elsif v_text not like '%no words%' then
    failures := failures || format('FAILED: an empty reading says "%s"', v_text)::text;
  else
    raise notice 'ok  a recording read with nothing in it is read, and says so';
  end if;

  -- ── a failure is not a reading ─────────────────────────────
  insert into public.attachments
    (client_id, storage_path, filename, mime_type, size_bytes, category, uploaded_by, uploaded_by_name)
  values (v_client, 'zz/recording-two.m4a', 'ZZ second meeting.m4a', 'audio/mp4', 900000,
          'Recording', v_admin, 'ZZ Recording Admin')
  returning id into v_att2;
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_admin_uid, 'role', 'authenticated')::text, true);
  v_rec2 := public.start_recording(v_att2);

  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  perform public.recording_reading(v_rec2, 'https://example.test/jobs/zz2');
  perform public.recording_failed(v_rec2, 'ZZ Azure said the audio was too quiet');
  select g.state into v_state from public.recordings g where g.id = v_rec2;
  if v_state <> 'Waiting' then
    failures := failures || format('FAILED: one failure left the recording %s, not waiting', v_state)::text;
  else
    raise notice 'ok  one failure is tried again rather than recorded as a reading';
  end if;

  perform public.recording_reading(v_rec2, 'https://example.test/jobs/zz2');
  perform public.recording_failed(v_rec2, 'ZZ again');
  perform public.recording_reading(v_rec2, 'https://example.test/jobs/zz2');
  perform public.recording_failed(v_rec2, 'ZZ and again');
  select g.state, g.reason into v_state, v_text from public.recordings g where g.id = v_rec2;
  if v_state <> 'Failed' then
    failures := failures || format('FAILED: three failures left the recording %s', v_state)::text;
  elsif v_text not like 'ZZ%' then
    failures := failures || 'FAILED: a failed recording does not carry what Azure said'::text;
  else
    raise notice 'ok  three failures stop the asking, and the recording carries what Azure said';
  end if;

  -- ── a reading, and a draft ─────────────────────────────────
  perform public.recording_read(
    v_rec,
    jsonb_build_array(
      jsonb_build_object('speaker', 1, 'at', 0, 'text', 'ZZ how did the week go'),
      jsonb_build_object('speaker', 2, 'at', 6, 'text', 'ZZ I applied for two jobs')),
    'ZZ how did the week go. ZZ I applied for two jobs.', 12.5);
  perform public.recording_drafted(v_rec, jsonb_build_object(
    'about', 'ZZ catch-up on the job search',
    'agreed', 'ZZ two more applications this week',
    'next', 'ZZ ring on Thursday',
    'note', 'ZZ applied for two jobs and will do two more.'));

  -- ── nothing is on the record yet ───────────────────────────
  select count(*) into v_n from public.contact_log where client_id = v_client;
  if v_n <> 0 then
    failures := failures || format('FAILED: %s contact log entries exist before anybody confirmed', v_n)::text;
  end if;
  select count(*) into v_n from public.notes where client_id = v_client;
  if v_n <> 0 then
    failures := failures || format('FAILED: %s notes exist before anybody confirmed', v_n)::text;
  else
    raise notice 'ok  a recording read and drafted is on nobody''s record until a person confirms it';
  end if;

  -- ── and only somebody who could have heard it ──────────────
  -- Its own recording, so that a permission check taken out confirms *this*
  -- one and leaves the cases below to report their own answers. A script that
  -- stops has said less than it knew.
  insert into public.attachments
    (client_id, storage_path, filename, mime_type, size_bytes, category, uploaded_by, uploaded_by_name)
  values (v_client, 'zz/recording-three.m4a', 'ZZ third meeting.m4a', 'audio/mp4', 800000,
          'Recording', v_admin, 'ZZ Recording Admin')
  returning id into v_att3;
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_admin_uid, 'role', 'authenticated')::text, true);
  v_rec3 := public.start_recording(v_att3);
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  perform public.recording_reading(v_rec3, 'https://example.test/jobs/zz3');
  perform public.recording_read(v_rec3, '[]'::jsonb, 'ZZ a third meeting', 3.0);

  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_coach_uid, 'role', 'authenticated')::text, true);
  v_text := '';
  begin
    perform public.confirm_recording(v_rec3, 'ZZ about', '', '', 'ZZ note', 'General progress');
    v_text := 'allowed';
  exception when insufficient_privilege then
    v_text := sqlerrm;
  end;
  if v_text = 'allowed' then
    failures := failures || 'FAILED: somebody who may not open the recording confirmed what it said'::text;
  elsif v_text not like '%restricted%' then
    failures := failures || format('FAILED: refused, but not in a sentence: %s', v_text)::text;
  else
    raise notice 'ok  only the people who may open a restricted document confirm what it said';
  end if;

  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_admin_uid, 'role', 'authenticated')::text, true);

  -- ── the note is not optional ───────────────────────────────
  v_text := '';
  begin
    perform public.confirm_recording(v_rec, 'ZZ about', '', '', '   ', 'General progress');
    v_text := 'allowed';
  exception when check_violation then
    v_text := sqlerrm;
  end;
  if v_text = 'allowed' then
    failures := failures || 'FAILED: a recording was confirmed with no note on the record'::text;
  else
    raise notice 'ok  the note is what goes on the record, so it is asked for';
  end if;

  -- ── confirming ─────────────────────────────────────────────
  perform public.confirm_recording(
    v_rec, 'ZZ catch-up on the job search', 'ZZ two more applications this week',
    'ZZ ring on Thursday', 'ZZ applied for two jobs and will do two more.', 'Job search');

  select g.state, g.contact_log_id, g.note_id, g.confirmed_by into r
    from public.recordings g where g.id = v_rec;
  select count(*) into v_n from public.contact_log where client_id = v_client;
  if r.state <> 'Confirmed' then
    failures := failures || format('FAILED: a confirmed recording is %s', r.state)::text;
  elsif v_n <> 1 then
    failures := failures || format('FAILED: confirming wrote %s contact log entries', v_n)::text;
  elsif r.contact_log_id is null or r.note_id is null then
    failures := failures || 'FAILED: a confirmed recording does not say what it became'::text;
  elsif r.confirmed_by is distinct from v_admin then
    failures := failures || 'FAILED: the contact log entry is not under the name of whoever confirmed'::text;
  else
    raise notice 'ok  confirming writes one contact log entry and one note, and the recording says which';
  end if;

  select l.method, l.topic, l.outcome, l.staff_id into r
    from public.contact_log l
   where l.id = (select g.contact_log_id from public.recordings g where g.id = v_rec);
  if r.method <> 'Meeting' or r.topic not like 'ZZ catch-up%' then
    failures := failures || format('FAILED: the contact log says %s / %s', r.method, r.topic)::text;
  elsif r.outcome not like '%Next: ZZ ring on Thursday%' then
    failures := failures || format(
      'FAILED: what happens next is not in the outcome: "%s"', r.outcome)::text;
  elsif r.staff_id is distinct from v_admin then
    failures := failures || 'FAILED: the contact log entry is not under the confirming person'::text;
  else
    raise notice 'ok  and it is a Meeting, in the words the person confirmed';
  end if;

  select n.type, n.category, n.attachment_id into r
    from public.notes n
   where n.id = (select g.note_id from public.recordings g where g.id = v_rec);
  if r.type <> 'Meeting' then
    failures := failures || format('FAILED: the note is a %s', r.type)::text;
  elsif r.attachment_id is distinct from v_att then
    failures := failures || 'FAILED: the note does not point at the recording it came from'::text;
  else
    raise notice 'ok  the note points at the recording, so anybody reading it can hear what it came from';
  end if;

  -- ── and a confirmed one is not undone by setting it aside ──
  v_text := '';
  begin
    perform public.set_recording_aside(v_rec, 'ZZ changed my mind');
    v_text := 'allowed';
  exception when check_violation then
    v_text := sqlerrm;
  end;
  if v_text = 'allowed' then
    failures := failures || 'FAILED: a recording already on the record was set aside'::text;
  else
    raise notice 'ok  one already on the record is not taken off it by setting it aside';
  end if;

  -- ── setting one aside says why ─────────────────────────────
  v_text := '';
  begin
    perform public.set_recording_aside(v_rec2, '  ');
    v_text := 'allowed';
  exception when check_violation then
    v_text := sqlerrm;
  end;
  if v_text = 'allowed' then
    failures := failures || 'FAILED: a recording was set aside with no reason'::text;
  else
    raise notice 'ok  setting one aside says why';
  end if;

  perform set_config('request.jwt.claims', '', true);

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, chr(10));
  end if;
end $$;

rollback;
