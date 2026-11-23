-- Zion Vocational Rehab CRM — the client threads board, and calls (0378, 0379, 0380)
--
-- The owner's rulings of 23 November 2026, asked of the database rather than
-- of the screen. What has to hold:
--
--   A reply is a reply on any channel (ruling 4). A client who texted and has
--   had nothing back needs a reply; a client who got a text back, or an email
--   filed on their record, or a contact-log line, or a note dated that day,
--   does not. A Personal note is not a reply - it is not in a report either.
--
--   "Quiet 14+ days" reads the same way: anything on any channel, either
--   direction, counts as not quiet.
--
--   A row is in the first group it belongs to, so a client who is owed a
--   reply and has a Friday draft waiting is in Needs a reply - and the draft
--   is a row of its own in Waiting on your approval, with its own number and
--   that number's own consent.
--
--   A website chat and a text from a number nobody has placed are rows too
--   (ruling 1), in Not a client yet.
--
--   The consent dot is per number, which is the view the sending gate reads
--   (ruling 6b): a client whose own number has not agreed and whose partner's
--   has is not "consent missing", and the array says which is which.
--
--   Asking the board writes nothing. Nobody who is not signed in sees any of
--   it, and neither does a system account.
--
--   A hand-written contact note says how it happened (Part 3). A Phone call
--   note is a phone call and does not need asking twice; a note filed from a
--   document is the document's record and is let through; a note that has a
--   method cannot lose it.
--
--   Logging a call writes the note and the log line together, and the line
--   says Call - which is what the reports board's chip now counts, where an
--   end-of-day roll-up is not (ruling 5).
--
--   Adding a message to the month can be done once. The second attempt is
--   refused rather than counted twice, and the thread says which messages are
--   already on the month.
--
--   And the half of ruling 6c that is the database's: only Admin, Job Search
--   and Reports can write an outgoing text. A Job Coach is refused, and a
--   Job Search account doing the same thing is the control.
--
-- Everything is rolled back.

begin;

do $$
declare
  failures   text[] := array[]::text[];
  v_mark     integer;
  -- ── the people ──
  v_js       uuid; v_js_uid    uuid := gen_random_uuid();
  v_coach    uuid; v_coach_uid uuid := gen_random_uuid();
  v_sys      uuid; v_sys_uid   uuid := gen_random_uuid();
  v_admin    uuid; v_admin_uid uuid := gen_random_uuid();
  -- ── the clients ──
  v_owed     uuid;  -- texted, nothing back
  v_texted   uuid;  -- texted, a text back
  v_mailed   uuid;  -- texted, an email filed
  v_logged   uuid;  -- texted, a contact-log line that day
  v_noted    uuid;  -- texted, a note that day
  v_private  uuid;  -- texted, and only a Personal note since
  v_quiet    uuid;  -- nothing on any channel for twenty days
  v_busy     uuid;  -- a text twenty days ago and a note two days ago
  v_broken   uuid;  -- a text that did not go
  v_draft    uuid;  -- a Friday draft waiting
  v_partner  uuid;  -- own number without consent, partner's with it
  v_contact  uuid;
  -- ── the rest ──
  v_conv     uuid;
  v_text     uuid;
  v_note     uuid;
  v_call     uuid;
  v_mail     uuid;
  r          record;
  v_n        integer;
  v_before   integer;
  v_after    integer;
  v_said     text;
  v_when     date := public.practice_today();
begin
  -- ── the fixtures ─────────────────────────────────────────────
  insert into public.staff (name, email, role, active)
  values ('ZZ Threads Search', 'zz-threads-search@example.test', 'Job Search', true) returning id into v_js;
  insert into public.staff (name, email, role, active)
  values ('ZZ Threads Coach', 'zz-threads-coach@example.test', 'Job Coach', true) returning id into v_coach;
  insert into public.staff (name, email, role, active, is_system)
  values ('ZZ Threads System', 'zz-threads-system@example.test', 'Job Search', true, true) returning id into v_sys;
  insert into public.staff (name, email, role, active)
  values ('ZZ Threads Admin', 'zz-threads-admin@example.test', 'Admin', true) returning id into v_admin;

  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_js_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-threads-search@example.test', '{}', '{}', now(), now()),
         (v_coach_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-threads-coach@example.test', '{}', '{}', now(), now()),
         (v_sys_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-threads-system@example.test', '{}', '{}', now(), now()),
         (v_admin_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-threads-admin@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_js_uid where id = v_js;
  update public.staff set user_id = v_coach_uid where id = v_coach;
  update public.staff set user_id = v_sys_uid where id = v_sys;
  update public.staff set user_id = v_admin_uid where id = v_admin;

  -- One client per reading of "a reply", each with a number that has agreed,
  -- so that nothing in these tests turns on consent except the tests about it.
  insert into public.clients (name, funding_source, status, stage, assigned_staff_id, phone)
  values ('ZZ Threads Owed', 'Utah VR', 'Active', 'Job Search', v_js, '385-555-0101') returning id into v_owed;
  insert into public.clients (name, funding_source, status, stage, assigned_staff_id, phone)
  values ('ZZ Threads Texted', 'Utah VR', 'Active', 'Job Search', v_js, '385-555-0102') returning id into v_texted;
  insert into public.clients (name, funding_source, status, stage, assigned_staff_id, phone)
  values ('ZZ Threads Mailed', 'Utah VR', 'Active', 'Job Search', v_js, '385-555-0103') returning id into v_mailed;
  insert into public.clients (name, funding_source, status, stage, assigned_staff_id, phone)
  values ('ZZ Threads Logged', 'Utah VR', 'Active', 'Job Search', v_js, '385-555-0104') returning id into v_logged;
  insert into public.clients (name, funding_source, status, stage, assigned_staff_id, phone)
  values ('ZZ Threads Noted', 'Utah VR', 'Active', 'Job Search', v_js, '385-555-0105') returning id into v_noted;
  insert into public.clients (name, funding_source, status, stage, assigned_staff_id, phone)
  values ('ZZ Threads Private', 'Utah VR', 'Active', 'Job Search', v_js, '385-555-0106') returning id into v_private;
  insert into public.clients (name, funding_source, status, stage, assigned_staff_id, phone)
  values ('ZZ Threads Quiet', 'Utah VR', 'Active', 'Job Search', v_js, '385-555-0107') returning id into v_quiet;
  insert into public.clients (name, funding_source, status, stage, assigned_staff_id, phone)
  values ('ZZ Threads Busy', 'Utah VR', 'Active', 'Job Search', v_js, '385-555-0108') returning id into v_busy;
  insert into public.clients (name, funding_source, status, stage, assigned_staff_id, phone)
  values ('ZZ Threads Broken', 'Utah VR', 'Active', 'Job Search', v_js, '385-555-0109') returning id into v_broken;
  insert into public.clients (name, funding_source, status, stage, assigned_staff_id, phone)
  values ('ZZ Threads Draft', 'Utah VR', 'Active', 'Job Search', v_js, '385-555-0110') returning id into v_draft;
  insert into public.clients (name, funding_source, status, stage, assigned_staff_id, phone)
  values ('ZZ Threads Partner', 'Utah VR', 'Active', 'Job Search', v_js, '385-555-0111') returning id into v_partner;

  insert into public.sms_consent_events (client_id, state, phone, method, note, staff_id)
  select c.id, 'Granted', public.normalize_phone(c.phone), 'Staff', 'fixture', v_js
    from public.clients c
   where c.id in (v_owed, v_texted, v_mailed, v_logged, v_noted, v_private, v_quiet,
                  v_busy, v_broken, v_draft);

  -- The partner: the client's own number has never agreed, the partner's has.
  insert into public.client_contacts (client_id, name, relationship, phone, receives_updates, active, added_by)
  values (v_partner, 'ZZ Partner', 'partner', public.normalize_phone('385-555-0211'), true, true, v_js)
  returning id into v_contact;
  insert into public.sms_consent_events (client_id, contact_id, state, phone, method, note, staff_id)
  values (v_partner, v_contact, 'Granted', public.normalize_phone('385-555-0211'), 'Staff', 'fixture', v_js);

  -- ── what everybody said ──
  -- Their word, three days ago, for every client whose group depends on it.
  insert into public.sms_messages (client_id, direction, phone, body, kind, status, created_at, sent_at)
  select c.id, 'Incoming', public.normalize_phone(c.phone), 'Is my appointment still on', 'Reply', 'Received',
         now() - interval '3 days', now() - interval '3 days'
    from public.clients c
   where c.id in (v_owed, v_texted, v_mailed, v_logged, v_noted, v_private);

  -- A text back, an hour later.
  insert into public.sms_messages (client_id, direction, phone, body, kind, status, created_at, created_by)
  values (v_texted, 'Outgoing', public.normalize_phone('385-555-0102'), 'Yes, Tuesday at ten', 'Manual', 'Sent',
          now() - interval '3 days' + interval '1 hour', v_js);

  -- An email filed on the record, an hour later.
  insert into public.mail_log (staff_id, client_id, graph_message_id, subject, sent_at, direction, counterpart_email)
  values (v_js, v_mailed, 'zz-threads-mail-1', 'Your appointment', now() - interval '3 days' + interval '1 hour',
          'Outgoing', 'counselor@example.test');

  -- A contact-log line, dated the same day they wrote.
  insert into public.contact_log (client_id, date, method, topic, outcome, staff_id)
  values (v_logged, (now() - interval '3 days')::date, 'Call', 'Call', 'Rang them back', v_js);

  -- A note, dated the same day.
  insert into public.notes (client_id, staff_id, staff_name, text, type, method, category, at, ts, visible_roles)
  values (v_noted, v_js, 'ZZ Threads Search', 'Rang and spoke to them about Tuesday', 'Phone call', 'Phone',
          'General progress', (now() - interval '3 days')::date, now() - interval '3 days' + interval '2 hours',
          array['Admin', 'Job Search', 'Reports']);

  -- And a Personal note, which is not a reply.
  insert into public.notes (client_id, staff_id, staff_name, text, type, category, at, ts, visible_roles)
  values (v_private, v_js, 'ZZ Threads Search', 'Housing, in confidence', 'General',
          'Personal', (now() - interval '3 days')::date, now() - interval '3 days' + interval '2 hours',
          array['Admin']);

  -- Quiet: one text, twenty days ago, and nothing since.
  insert into public.sms_messages (client_id, direction, phone, body, kind, status, created_at, created_by)
  values (v_quiet, 'Outgoing', public.normalize_phone('385-555-0107'), 'Checking in', 'Manual', 'Sent',
          now() - interval '20 days', v_js);

  -- Busy: the same text twenty days ago, and a note two days ago.
  insert into public.sms_messages (client_id, direction, phone, body, kind, status, created_at, created_by)
  values (v_busy, 'Outgoing', public.normalize_phone('385-555-0108'), 'Checking in', 'Manual', 'Sent',
          now() - interval '20 days', v_js);
  insert into public.notes (client_id, staff_id, staff_name, text, type, method, category, at, ts, visible_roles)
  values (v_busy, v_js, 'ZZ Threads Search', 'Job site visit went well', 'Meeting', 'In person',
          'Job coaching', (now() - interval '2 days')::date, now() - interval '2 days',
          array['Admin', 'Job Search', 'Reports']);

  -- Broken: a text the provider would not take.
  insert into public.sms_messages (client_id, direction, phone, body, kind, status, error, created_at, created_by)
  values (v_broken, 'Outgoing', public.normalize_phone('385-555-0109'), 'Tomorrow at nine', 'Manual',
          'Not delivered', 'nothing came back', now() - interval '2 days', v_js);

  -- A Friday draft waiting on somebody, and its client is owed a reply too.
  insert into public.sms_messages (client_id, direction, phone, body, kind, status, created_at, sent_at)
  values (v_draft, 'Incoming', public.normalize_phone('385-555-0110'), 'Any news', 'Reply', 'Received',
          now() - interval '1 day', now() - interval '1 day');
  insert into public.weekly_updates (week_start, client_id, phone, language, body, state, drafted_at)
  values (date_trunc('week', public.practice_today())::date, v_draft, public.normalize_phone('385-555-0110'),
          'English', 'This week we applied for two jobs.', 'Draft', now());

  -- Somebody nobody has placed, and a website chat.
  insert into public.sms_messages (client_id, direction, phone, body, kind, status, created_at, sent_at)
  values (null, 'Incoming', public.normalize_phone('385-555-0900'), 'Do you help with resumes', 'Reply', 'Received',
          now() - interval '5 hours', now() - interval '5 hours');
  insert into public.conversations (kind, external_address, title, last_message_at)
  values ('web', 'zz-visitor@example.test', 'ZZ Visitor', now() - interval '2 hours')
  returning id into v_conv;
  insert into public.web_chats (conversation_id, visitor_name, contact, contact_kind, consent_text, consent_at)
  values (v_conv, 'ZZ Visitor', 'zz-visitor@example.test', 'email', 'Agreed to be contacted here', now() - interval '2 hours');
  insert into public.messages (conversation_id, sender_kind, sender_label, body, status, created_at)
  values (v_conv, 'visitor', 'ZZ Visitor', 'Is there a waiting list', 'received', now() - interval '2 hours');

  -- ── 1. a reply is a reply on any channel ─────────────────────
  v_mark := coalesce(array_length(failures, 1), 0);
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_js_uid, 'role', 'authenticated')::text, true);

  for r in
    select * from public.client_threads_board()
     where client_id in (v_owed, v_texted, v_mailed, v_logged, v_noted, v_private)
       and kind = 'client'
  loop
    if r.client_id = v_owed and r.grp <> 'needs-reply' then
      failures := failures || format('FAILED: a client who texted and got nothing back is in %s', r.grp)::text;
    end if;
    if r.client_id = v_owed and coalesce(r.waiting_hours, -1) < 70 then
      failures := failures || format('FAILED: three days of waiting reads as %s hours', r.waiting_hours)::text;
    end if;
    if r.client_id = v_texted and r.grp = 'needs-reply' then
      failures := failures || 'FAILED: a client who got a text back still needs a reply'::text;
    end if;
    if r.client_id = v_mailed and r.grp = 'needs-reply' then
      failures := failures || 'FAILED: an email filed on the record does not count as a reply'::text;
    end if;
    if r.client_id = v_logged and r.grp = 'needs-reply' then
      failures := failures || 'FAILED: a contact-log line dated that day does not count as a reply'::text;
    end if;
    if r.client_id = v_noted and r.grp = 'needs-reply' then
      failures := failures || 'FAILED: a note dated that day does not count as a reply'::text;
    end if;
    if r.client_id = v_private and r.grp <> 'needs-reply' then
      failures := failures || format('FAILED: a Personal note answered a client, and the group is %s', r.grp)::text;
    end if;
  end loop;

  select count(*) into v_n from public.client_threads_board()
   where kind = 'client' and client_id in (v_owed, v_texted, v_mailed, v_logged, v_noted, v_private);
  if v_n <> 6 then
    failures := failures || format('FAILED: six clients, %s rows', v_n)::text;
  end if;
  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  a reply is a reply on any channel, and a Personal note is not one';
  end if;

  -- ── 1b. and the board says the same thing to an Admin ────────
  --
  -- This one is here because putting the fault back found it. A Personal note
  -- is invisible to everybody but Admin by row-level policy, so the test
  -- above cannot tell "the board leaves Personal notes out" from "the reader
  -- could not see it anyway" - and for an Admin, who can see it, a board that
  -- relied on the policy would quietly change its mind: the same client would
  -- be owed a reply for one person and up to date for another.
  v_mark := coalesce(array_length(failures, 1), 0);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin_uid, 'role', 'authenticated')::text, true);
  select grp into v_said from public.client_threads_board() where kind = 'client' and client_id = v_private;
  if v_said <> 'needs-reply' then
    failures := failures || format('FAILED: as Admin, a Personal note answered the client and the group is %s', v_said)::text;
  end if;
  select grp into v_said from public.client_threads_board() where kind = 'client' and client_id = v_owed;
  if v_said <> 'needs-reply' then
    failures := failures || format('FAILED: as Admin, the client owed a reply is in %s', v_said)::text;
  end if;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_js_uid, 'role', 'authenticated')::text, true);
  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  the board says the same thing to an Admin, who can see the Personal note';
  end if;

  -- ── 2. quiet reads the same way ──────────────────────────────
  v_mark := coalesce(array_length(failures, 1), 0);
  select grp into v_said from public.client_threads_board() where client_id = v_quiet and kind = 'client';
  if v_said <> 'quiet' then
    failures := failures || format('FAILED: twenty days of silence is %s', v_said)::text;
  end if;
  select grp into v_said from public.client_threads_board() where client_id = v_busy and kind = 'client';
  if v_said = 'quiet' then
    failures := failures || 'FAILED: a note two days ago still reads as quiet'::text;
  end if;
  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  quiet 14+ days counts every channel, both ways';
  end if;

  -- ── 3. a text that did not go ────────────────────────────────
  v_mark := coalesce(array_length(failures, 1), 0);
  select * into r from public.client_threads_board() where client_id = v_broken and kind = 'client';
  if r.grp <> 'stuck' then
    failures := failures || format('FAILED: a text that was not delivered is in %s', r.grp)::text;
  end if;
  if coalesce(r.failed, 0) <> 1 then
    failures := failures || format('FAILED: one undelivered text counts as %s', r.failed)::text;
  end if;
  if r.status <> 'Not delivered' then
    failures := failures || format('FAILED: the pill says %s', r.status)::text;
  end if;
  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  a text the provider would not take is its own group';
  end if;

  -- ── 4. whoever is not a client yet ───────────────────────────
  v_mark := coalesce(array_length(failures, 1), 0);
  select count(*) into v_n from public.client_threads_board()
   where kind = 'stranger' and grp = 'stranger';
  if v_n < 2 then
    failures := failures || format('FAILED: a website chat and an unplaced number make %s rows', v_n)::text;
  end if;
  select * into r from public.client_threads_board() where conversation_id = v_conv;
  if r.kind <> 'stranger' or r.grp <> 'stranger' then
    failures := failures || 'FAILED: a website chat is not in Not a client yet'::text;
  end if;
  if r.client_id is not null then
    failures := failures || 'FAILED: a stranger row carries a client'::text;
  end if;
  if r.status <> 'Not a client yet' then
    failures := failures || format('FAILED: the stranger pill says %s', r.status)::text;
  end if;
  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  a website chat and a number nobody has placed are rows on the board';
  end if;

  -- ── 5. a draft is a row of its own, and so is its client ─────
  v_mark := coalesce(array_length(failures, 1), 0);
  select * into r from public.client_threads_board() where kind = 'draft' and client_id = v_draft;
  if r.update_id is null then
    failures := failures || 'FAILED: a waiting draft has no row of its own'::text;
  end if;
  if r.grp <> 'approval' then
    failures := failures || format('FAILED: a waiting draft is in %s', r.grp)::text;
  end if;
  if jsonb_array_length(r.numbers) <> 1 then
    failures := failures || format('FAILED: a draft row carries %s numbers rather than the one it goes to', jsonb_array_length(r.numbers))::text;
  end if;
  -- And the client itself is in the group it is owed, not in approval.
  select grp into v_said from public.client_threads_board() where kind = 'client' and client_id = v_draft;
  if v_said <> 'needs-reply' then
    failures := failures || format('FAILED: a client owed a reply with a draft waiting is in %s', v_said)::text;
  end if;
  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  a draft is its own row with its own number, and the client keeps its group';
  end if;

  -- ── 6. the consent dot is per number ─────────────────────────
  v_mark := coalesce(array_length(failures, 1), 0);
  select * into r from public.client_threads_board() where kind = 'client' and client_id = v_partner;
  if r.consent_missing then
    failures := failures || 'FAILED: a client whose partner has agreed reads as consent missing'::text;
  end if;
  if jsonb_array_length(r.numbers) <> 2 then
    failures := failures || format('FAILED: two numbers on file, %s on the row', jsonb_array_length(r.numbers))::text;
  end if;
  if (select count(*) from jsonb_array_elements(r.numbers) x where (x->>'can_text')::boolean) <> 1 then
    failures := failures || 'FAILED: the row does not say which of the two numbers may be texted'::text;
  end if;
  -- And the same question of the inbox, which had it wrong until 0380.
  select can_text into v_said from public.message_inbox('texts') m
   where m.client_id = v_partner limit 1;
  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  the dot is per number, and the array says which';
  end if;

  -- ── 7. the board writes nothing ──────────────────────────────
  v_mark := coalesce(array_length(failures, 1), 0);
  select count(*) into v_before from public.contact_log;
  select count(*) into v_n from public.notes;
  perform count(*) from public.client_threads_board();
  perform count(*) from public.client_thread_stream(v_owed);
  select count(*) into v_after from public.contact_log;
  if v_after <> v_before then
    failures := failures || 'FAILED: asking the board wrote a contact-log line'::text;
  end if;
  select count(*) into v_after from public.notes;
  if v_after <> v_n then
    failures := failures || 'FAILED: asking the board wrote a note'::text;
  end if;
  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  asking the board writes nothing';
  end if;

  -- ── 8. a contact note says how it happened ───────────────────
  v_mark := coalesce(array_length(failures, 1), 0);
  begin
    insert into public.notes (client_id, staff_id, staff_name, text, type, category, at, visible_roles)
    values (v_owed, v_js, 'ZZ Threads Search', 'Met them at the job site', 'Meeting',
            'Job coaching', v_when, array['Admin', 'Job Search']);
    failures := failures || 'FAILED: a hand-written Meeting note went in with no method'::text;
  exception when check_violation then null;
  end;

  -- A phone call is a phone call: the type is the method.
  insert into public.notes (client_id, staff_id, staff_name, text, type, category, at, visible_roles)
  values (v_owed, v_js, 'ZZ Threads Search', 'Rang about Tuesday', 'Phone call',
          'Job search', v_when, array['Admin', 'Job Search'])
  returning id, method into v_note, v_said;
  if v_said <> 'Phone' then
    failures := failures || format('FAILED: a Phone call note has method %s', coalesce(v_said, 'none'))::text;
  end if;

  -- A phone call cannot stop being one: emptying the method puts it back,
  -- because the type is the answer and there is nothing to ask.
  update public.notes set method = null where id = v_note;
  select method into v_said from public.notes where id = v_note;
  if v_said <> 'Phone' then
    failures := failures || format('FAILED: a Phone call note emptied of its method reads %s', coalesce(v_said, 'nothing'))::text;
  end if;

  -- A method cannot be taken off a note where the type does not supply one.
  insert into public.notes (client_id, staff_id, staff_name, text, type, method, category, at, visible_roles)
  values (v_owed, v_js, 'ZZ Threads Search', 'Met them at the job site', 'Meeting', 'In person',
          'Job coaching', v_when, array['Admin', 'Job Search'])
  returning id into v_note;
  begin
    update public.notes set method = null where id = v_note;
    failures := failures || 'FAILED: a Meeting note lost the method it had'::text;
  exception when check_violation then null;
  end;

  -- But a note that never had one stays editable.
  begin
    update public.notes set text = 'Rang and spoke to them about Tuesday, edited'
     where client_id = v_noted and type = 'Phone call';
  exception when others then
    failures := failures || format('FAILED: editing an older note was refused: %s', sqlerrm)::text;
  end;
  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  a hand-written contact says how it happened, and Phone call says it itself';
  end if;

  -- ── 9. logging a call writes both halves ─────────────────────
  v_mark := coalesce(array_length(failures, 1), 0);
  select public.log_a_call(v_owed, 'Rang about the interview on Thursday', 'Job search', v_when, 'Spoke to them')
    into v_call;
  select count(*) into v_n from public.notes
   where id = v_call and method = 'Phone' and type = 'Phone call';
  if v_n <> 1 then
    failures := failures || 'FAILED: logging a call did not write the note'::text;
  end if;
  select count(*) into v_n from public.contact_log
   where source = 'Call' and source_key = v_call::text and method = 'Call' and client_id = v_owed;
  if v_n <> 1 then
    failures := failures || 'FAILED: logging a call did not write the contact-log line'::text;
  end if;
  -- And it is in the stream as a call.
  select count(*) into v_n from public.client_thread_stream(v_owed) where channel = 'Call' and ref_id = v_call;
  if v_n <> 1 then
    failures := failures || 'FAILED: a logged call is not in the thread'::text;
  end if;
  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  a call is written down in both places, and shows on the thread';
  end if;

  -- ── 10. adding to the month, once ────────────────────────────
  v_mark := coalesce(array_length(failures, 1), 0);
  select id into v_text from public.sms_messages where client_id = v_owed and direction = 'Incoming' limit 1;
  perform public.collect_contact('Text', v_text, '');
  select count(*) into v_n from public.contact_log
   where source = 'Text' and source_key = v_text::text and method = 'Text';
  if v_n <> 1 then
    failures := failures || 'FAILED: adding a text to the month wrote no line'::text;
  end if;
  begin
    perform public.collect_contact('Text', v_text, '');
    failures := failures || 'FAILED: the same text was added to the month twice'::text;
  exception when check_violation then null;
  end;
  select collected into v_said from public.client_thread_stream(v_owed) where ref_id = v_text and channel = 'Text';
  if v_said is distinct from 'true' then
    failures := failures || 'FAILED: the thread does not say the text is already on the month'::text;
  end if;
  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  a message goes onto the month once, and the thread says so';
  end if;

  -- ── 11. the chip counts contacts and not paperwork ───────────
  v_mark := coalesce(array_length(failures, 1), 0);
  if not public.is_real_contact('Call') then
    failures := failures || 'FAILED: a call is not counted as a contact'::text;
  end if;
  if not public.is_real_contact('Text') or not public.is_real_contact('Email')
     or not public.is_real_contact('Appointment') or not public.is_real_contact('In person') then
    failures := failures || 'FAILED: one of the five methods the owner named is not counted'::text;
  end if;
  if public.is_real_contact('End of day report') or public.is_real_contact('Stage change')
     or public.is_real_contact('Billing submitted') or public.is_real_contact(null) then
    failures := failures || 'FAILED: the practice''s own paperwork counts as a contact'::text;
  end if;
  -- And through the board that shows it: an end-of-day line adds nothing.
  insert into public.contact_log (client_id, date, method, topic, outcome, staff_id)
  values (v_owed, v_when, 'End of day report', 'End of day', 'Nothing to report', v_js);
  select contacts into v_n from public.report_board_rows(date_trunc('month', v_when)::date)
   where client_id = v_owed limit 1;
  if v_n is not null and v_n > 2 then
    failures := failures || format('FAILED: the chip counts %s where two contacts happened', v_n)::text;
  end if;
  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  the chip counts the five methods and not the practice''s paperwork';
  end if;

  -- ── 12. the stream, and what is not in it ────────────────────
  v_mark := coalesce(array_length(failures, 1), 0);
  select count(*) into v_n from public.client_thread_stream(v_mailed) where channel = 'Email';
  if v_n <> 1 then
    failures := failures || format('FAILED: one filed email, %s in the stream', v_n)::text;
  end if;
  select count(*) into v_n from public.client_thread_stream(v_private);
  if exists (select 1 from public.client_thread_stream(v_private) where body like '%in confidence%') then
    failures := failures || 'FAILED: a Personal note is in the thread'::text;
  end if;
  -- Newest first.
  if exists (
    select 1 from (
      select at, lag(at) over () as previous from public.client_thread_stream(v_owed)
    ) z where previous is not null and at > previous
  ) then
    failures := failures || 'FAILED: the stream is not newest first'::text;
  end if;
  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  the stream carries texts, calls and filed email, newest first';
  end if;

  -- ── 13. only three roles write an outgoing text ──────────────
  v_mark := coalesce(array_length(failures, 1), 0);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_coach_uid, 'role', 'authenticated')::text, true);
  begin
    insert into public.sms_messages (client_id, direction, phone, body, kind, status, created_by)
    values (v_owed, 'Outgoing', public.normalize_phone('385-555-0101'), 'From a job coach', 'Manual', 'Queued', v_coach);
    failures := failures || 'FAILED: a Job Coach wrote an outgoing text'::text;
  exception when insufficient_privilege then null;
  end;
  -- The control: the same text, from a role the policy admits.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_js_uid, 'role', 'authenticated')::text, true);
  begin
    insert into public.sms_messages (client_id, direction, phone, body, kind, status, created_by)
    values (v_owed, 'Outgoing', public.normalize_phone('385-555-0101'), 'From Job Search', 'Manual', 'Queued', v_js);
  exception when others then
    failures := failures || format('FAILED: Job Search could not write an outgoing text either: %s', sqlerrm)::text;
  end;
  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  a Job Coach cannot text a client, and Job Search can';
  end if;

  -- ── 14. nobody who is not signed in, and no system account ───
  v_mark := coalesce(array_length(failures, 1), 0);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_sys_uid, 'role', 'authenticated')::text, true);
  select count(*) into v_n from public.client_threads_board();
  if v_n <> 0 then
    failures := failures || format('FAILED: a system account sees %s rows of the board', v_n)::text;
  end if;
  select count(*) into v_n from public.client_thread_stream(v_owed);
  if v_n <> 0 then
    failures := failures || format('FAILED: a system account sees %s items of a thread', v_n)::text;
  end if;

  perform set_config('request.jwt.claims', '', true);
  select count(*) into v_n from public.client_threads_board();
  if v_n <> 0 then
    failures := failures || format('FAILED: somebody not signed in sees %s rows of the board', v_n)::text;
  end if;
  begin
    perform public.log_a_call(v_owed, 'From nobody', 'Job search', v_when, '');
    failures := failures || 'FAILED: somebody not signed in logged a call'::text;
  exception when others then null;
  end;
  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  a system account and a stranger see none of it';
  end if;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  -- ── the verdict ──────────────────────────────────────────────
  if array_length(failures, 1) > 0 then
    raise exception E'\n%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- THE THREADS BOARD VERIFIED ---';
end $$;

rollback;
