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
--   **A machine draft carries no health, legal, benefits or family detail**,
--   and is not kept at all when it does - from a transcript that is full of
--   all four, which is what a real meeting sounds like. A staff member may
--   write any of it: the judgement is theirs.
--
--   A draft runs to the cap or it is not kept.
--
--   **The transcript never leaves the recording.** What confirming writes is
--   the six parts the person had in front of them, and none of the words.
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
  v_att uuid; v_att2 uuid; v_pdf uuid; v_att4 uuid; v_att5 uuid;
  v_rec uuid; v_rec2 uuid; v_rec3 uuid; v_again uuid; v_rec4 uuid; v_rec5 uuid;
  v_att3 uuid;
  v_text text; v_n integer; v_state text; v_bool boolean; v_note text;
  v_case record;
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

  -- ── a reading, with everything a meeting really holds ──────
  --
  -- The transcript is deliberately full of the four kinds the rule names:
  -- her health, her family, the money the state pays her, and her lawyer.
  -- That is what an hour of conversation with somebody about their working
  -- life actually contains, and it is the case the rule exists for. The
  -- practice keeps the words - they are what was said - and what it refuses
  -- is a machine deciding they belong on a record.
  --
  -- Three recordings, one transcript. A draft that is refused leaves its
  -- recording where it was, so a case that goes the wrong way would leave
  -- the next one in a state it cannot be drafted from, and one exception
  -- would hide two answers. A script that stops has said less than it knew.
  insert into public.attachments
    (client_id, storage_path, filename, mime_type, size_bytes, category, uploaded_by, uploaded_by_name)
  values (v_client, 'zz/recording-four.m4a', 'ZZ a draft that says too much.m4a', 'audio/mp4', 700000,
          'Recording', v_admin, 'ZZ Recording Admin')
  returning id into v_att4;
  insert into public.attachments
    (client_id, storage_path, filename, mime_type, size_bytes, category, uploaded_by, uploaded_by_name)
  values (v_client, 'zz/recording-five.m4a', 'ZZ a draft that runs on.m4a', 'audio/mp4', 700000,
          'Recording', v_admin, 'ZZ Recording Admin')
  returning id into v_att5;
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_admin_uid, 'role', 'authenticated')::text, true);
  v_rec4 := public.start_recording(v_att4);
  v_rec5 := public.start_recording(v_att5);
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  perform public.recording_reading(v_rec4, 'https://example.test/jobs/zz4');
  perform public.recording_reading(v_rec5, 'https://example.test/jobs/zz5');

  for v_case in select unnest(array[v_rec, v_rec4, v_rec5]) as id loop
    perform public.recording_read(
      v_case.id,
      jsonb_build_array(
        jsonb_build_object('speaker', 1, 'at', 0, 'text', 'ZZ how did the week go'),
        jsonb_build_object('speaker', 2, 'at', 6,
          'text', 'ZZ my mother drove me and the new medication made mornings hard'),
        jsonb_build_object('speaker', 2, 'at', 14,
          'text', 'ZZ my attorney says the SSDI review is still open'),
        jsonb_build_object('speaker', 2, 'at', 20, 'text', 'ZZ I applied for two jobs')),
      'ZZ how did the week go. ZZ my mother drove me and the new medication made mornings hard. '
      || 'ZZ my attorney says the SSDI review is still open. ZZ I applied for two jobs.', 12.5);
  end loop;

  -- ── a draft that repeats it is not kept ────────────────────
  v_text := public.recording_drafted(v_rec4, jsonb_build_object(
    'kind', 'Planning meeting',
    'present', 'ZZ and the job coach',
    'discussed', 'ZZ her mother drove her and the new medication made mornings hard',
    'decisions', 'ZZ two more applications this week',
    'next', 'ZZ ring on Thursday',
    'question', 'ZZ how is the SSDI review going'));
  select g.state, g.summary, g.reason into v_case from public.recordings g where g.id = v_rec4;
  if v_text = '' then
    failures := failures ||
      'FAILED: a machine draft carrying health, family and benefits detail was kept'::text;
  elsif v_case.state <> 'Read' or v_case.summary is not null then
    failures := failures || format(
      'FAILED: a refused draft left the recording %s with a summary on it', v_case.state)::text;
  elsif v_case.reason not like '%detail%' then
    failures := failures || format(
      'FAILED: the draft was refused and the recording does not say why: "%s"', v_case.reason)::text;
  else
    raise notice 'ok  a machine draft carrying health, legal, benefits or family detail is not kept';
  end if;

  -- Each of the four on its own, so a list that quietly loses one is noticed
  -- rather than passing on the strength of the other three.
  for v_case in
    select * from (values
      ('health',   'ZZ the new medication made mornings hard'),
      ('legal',    'ZZ her attorney filed it last week'),
      ('benefits', 'ZZ the SSDI review is still open'),
      ('family',   'ZZ her mother drove her to the interview')
    ) as t(kind, line)
  loop
    if public.machine_draft_problem(v_case.line) not like v_case.kind || '%' then
      failures := failures || format(
        'FAILED: %s detail is not caught: "%s"', v_case.kind, v_case.line)::text;
    end if;
  end loop;
  raise notice 'ok  each of the four kinds is caught on its own';

  -- And the other half of it. A guard that refuses everything is no guard:
  -- this practice places people in hospitals and clinics, "disability" is
  -- its subject and "benefits" is a thing an employer offers.
  if public.machine_draft_problem(
       'ZZ applied at the hospital and the clinic, and asked what benefits the employer offers'
     ) <> '' then
    failures := failures ||
      'FAILED: an ordinary note about looking for work was refused as sensitive detail'::text;
  else
    raise notice 'ok  and ordinary work - hospitals, clinics, an employer''s benefits - is not refused';
  end if;

  -- ── and a draft that runs past the cap is not kept ─────────
  v_text := public.recording_drafted(v_rec5, jsonb_build_object(
    'kind', 'Planning meeting',
    'present', 'ZZ and the job coach',
    'discussed', btrim(repeat('ZZ applications ', 200)),
    'decisions', '', 'next', '', 'question', ''));
  select g.state, g.summary into v_case from public.recordings g where g.id = v_rec5;
  if v_text = '' then
    failures := failures || 'FAILED: a draft of 400 words was kept against a cap of 120'::text;
  elsif v_case.state <> 'Read' or v_case.summary is not null then
    failures := failures || format(
      'FAILED: an over-long draft left the recording %s with a summary on it', v_case.state)::text;
  elsif v_text not like '%words%' then
    failures := failures || format('FAILED: refused, but not for its length: "%s"', v_text)::text;
  else
    raise notice 'ok  a draft past the cap is not kept, and says how long it ran';
  end if;

  -- ── the same transcript, drafted properly, is kept ─────────
  --
  -- Which is the point: the words are not the problem and the recording is
  -- not refused for holding them. What is asked is of the draft.
  v_text := public.recording_drafted(v_rec, jsonb_build_object(
    'kind', 'Planning meeting',
    'present', 'ZZ and the job coach',
    'discussed', 'ZZ the week''s applications and the shift pattern at the warehouse',
    'decisions', 'ZZ two more applications this week',
    'next', 'ZZ the coach rings on Thursday morning',
    'question', 'ZZ did the warehouse reply'));
  select g.state, g.summary, g.reason into v_case from public.recordings g where g.id = v_rec;
  if v_text <> '' then
    failures := failures || format('FAILED: a clean draft was refused: %s', v_text)::text;
  elsif v_case.state <> 'Drafted' or v_case.summary is null or v_case.reason <> '' then
    failures := failures || format(
      'FAILED: a clean draft left the recording %s', v_case.state)::text;
  else
    raise notice 'ok  a clean draft of the same transcript is kept, words and all';
  end if;

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
    perform public.confirm_recording(
      v_rec3, 'Planning meeting', null::date, 'ZZ and the coach', 'ZZ about',
      '', '', '', 'General progress');
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

  -- ── what a record of a meeting has to say ──────────────────
  --
  -- Three of the six parts are not optional: what kind of contact it was,
  -- who was there, and what was discussed. Without them it is not a record
  -- of a meeting, it is a file with a date on it. Each is asked for
  -- separately so that one of the three going missing is reported rather
  -- than hidden behind the first.
  for v_case in
    select * from (values
      ('a type of contact nobody uses', 'Catch-up', 'ZZ and the coach', 'ZZ the job search'),
      ('nobody present',                'Phone',    '   ',              'ZZ the job search'),
      ('nothing discussed',             'Phone',    'ZZ and the coach', '   ')
    ) as t(what, kind, present, discussed)
  loop
    v_text := '';
    begin
      perform public.confirm_recording(
        v_rec, v_case.kind, null::date, v_case.present, v_case.discussed, '', '', '', 'General progress');
      v_text := 'allowed';
    exception when check_violation then
      v_text := sqlerrm;
    end;
    if v_text = 'allowed' then
      failures := failures || format(
        'FAILED: a recording was confirmed with %s', v_case.what)::text;
    end if;
  end loop;
  raise notice 'ok  the type of contact, who was there and what was discussed are all asked for';

  -- ── confirming ─────────────────────────────────────────────
  perform public.confirm_recording(
    v_rec, 'Planning meeting', null::date, 'ZZ and the job coach',
    'ZZ catch-up on the job search', 'ZZ two more applications this week',
    'ZZ the coach rings on Thursday morning', 'ZZ did the warehouse reply', 'Job search');

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
  if r.method <> 'Planning meeting' or r.topic not like 'ZZ catch-up%' then
    failures := failures || format('FAILED: the contact log says %s / %s', r.method, r.topic)::text;
  elsif r.outcome not like '%Next: ZZ the coach rings on Thursday morning%' then
    failures := failures || format(
      'FAILED: what happens next is not in the outcome: "%s"', r.outcome)::text;
  elsif r.staff_id is distinct from v_admin then
    failures := failures || 'FAILED: the contact log entry is not under the confirming person'::text;
  else
    raise notice 'ok  and it is the type of contact, in the words the person confirmed';
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

  -- ── the note is the six parts, and the words stay behind ───
  --
  -- The transcript is a machine's record of a conversation about somebody's
  -- life, and it is readable by the people who may open the audio and nobody
  -- else. What goes on the record is what a person read and agreed to. So
  -- the note is asserted both ways: it is in the shape, and it carries none
  -- of the four things the transcript said that the draft left out.
  select n.text into v_note from public.notes n
   where n.id = (select g.note_id from public.recordings g where g.id = v_rec);
  if v_note like '%mother%' or v_note like '%medication%'
     or v_note like '%SSDI%' or v_note like '%attorney%' then
    failures := failures || 'FAILED: the transcript reached the note'::text;
  elsif v_note not like 'Planning meeting, %' or v_note not like '%Present: ZZ and the job coach%'
     or v_note not like '%Discussed: ZZ catch-up%' or v_note not like '%Next steps: %'
     or v_note not like '%Follow-up question: ZZ did the warehouse reply%' then
    failures := failures || format('FAILED: the note is not in the shape: "%s"', v_note)::text;
  else
    raise notice 'ok  the note is the six parts, and none of the transcript';
  end if;

  select l.topic || ' ' || l.outcome into v_text from public.contact_log l
   where l.id = (select g.contact_log_id from public.recordings g where g.id = v_rec);
  if v_text like '%mother%' or v_text like '%medication%'
     or v_text like '%SSDI%' or v_text like '%attorney%' then
    failures := failures || 'FAILED: the transcript reached the contact log'::text;
  else
    raise notice 'ok  and none of it reached the contact log either';
  end if;

  -- ── but a staff member may write any of it ─────────────────
  --
  -- The rule is about a machine deciding what belongs on somebody's record,
  -- not about what the practice may record. A member of staff who judges
  -- that the attorney and the SSDI review are the reason this meeting
  -- happened writes them, and nothing here argues.
  perform public.confirm_recording(
    v_rec3, 'Phone', null::date, 'ZZ and her mother', 'ZZ the SSDI review and her attorney',
    'ZZ she will send the letter', '', '', 'General progress');
  select n.text into v_note from public.notes n
   where n.id = (select g.note_id from public.recordings g where g.id = v_rec3);
  if v_note is null or v_note not like '%attorney%' or v_note not like '%mother%' then
    failures := failures ||
      'FAILED: a staff member could not put on the record what they judged belonged there'::text;
  else
    raise notice 'ok  and a staff member writes whatever they judge belongs on the record';
  end if;

  -- ── and a recorded phone call is a phone call ──────────────
  -- The note types are what somebody filters a client's notes by. v_rec3 was
  -- confirmed as Phone just above; v_rec was a planning meeting.
  select n.type into v_text from public.notes n
   where n.id = (select g.note_id from public.recordings g where g.id = v_rec3);
  if v_text <> 'Phone call' then
    failures := failures || format('FAILED: a recorded phone call is a note of type %s', v_text)::text;
  else
    raise notice 'ok  a recorded phone call is filed as a phone call, a meeting as a meeting';
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


  -- -- the bucket takes what the form offers (0349) ----------
  --
  -- The live test on 14 Nov found the client record offering a WAV and
  -- storage refusing it, because the file picker had been widened and the
  -- bucket had not. check-upload-types asks this of the migrations at every
  -- build; this asks it of the database, which is the one that refuses the
  -- upload and the one somebody can change in a console.
  --
  -- The audio types are the ones a recording actually arrives as: what a
  -- phone browser records in, and what a handheld recorder writes.
  for r in
    select m from unnest(array[
      'audio/webm', 'audio/mp4', 'audio/mpeg', 'audio/mp3', 'audio/ogg',
      'audio/aac', 'audio/x-m4a', 'audio/m4a',
      'audio/wav', 'audio/x-wav', 'audio/wave',
      'audio/flac', 'audio/x-flac'
    ]) as m
  loop
    if not exists (
      select 1 from storage.buckets b
       where b.id = 'client-files' and r.m = any (b.allowed_mime_types)
    ) then
      failures := failures || format(
        'FAILED: the client-files bucket refuses %s, which the file picker offers', r.m)::text;
    end if;
  end loop;
  if not exists (select 1 from unnest(failures) as f where f like '%bucket refuses%') then
    raise notice 'ok  the bucket takes every recording type the file picker offers';
  end if;

  perform set_config('request.jwt.claims', '', true);

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, chr(10));
  end if;
end $$;

rollback;
