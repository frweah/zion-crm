-- Zion Vocational Rehab CRM — "To file" (0317-0318)
--
-- Item E, and the two things the owner's definition of done asks this script
-- to prove:
--
--   **Unconfirmed never appears in a report.** Not filtered out of one -
--   never in it. An item waiting in somebody's inbox puts nothing on the
--   client's record: no contact, no note, no calendar event. So there is
--   nothing for a report to leave out, and nothing for a new report template
--   to accidentally include.
--
--   **Discard leaves no contact-log trace.** The item is marked discarded so
--   the sweep does not offer it again; the client's record is untouched.
--
-- And the rest of what the brief says:
--
--   Confirming is the only way onto a record, it needs a client, and it
--   records who decided. "Wrong client" is not a decision about the item: it
--   removes the guess and leaves it waiting.
--
--   An item is its owner's. Somebody else cannot confirm, assign or discard
--   it; Admin can, because somebody has to be able to clear an inbox while
--   its owner is away.
--
--   The sweeps may only offer. to_file_offer is the service role's and is
--   idempotent, so a sixty-day first look followed by a nightly run offers
--   the same appointment once and does not undo a decision.
--
--   Mail that names an active client is offered to whoever the mail belongs
--   to; mail that names nobody is not. And a Personal contact is not in a
--   report, the way a Personal note is not.
--
-- Runs inside a transaction that is rolled back. Nothing here is left behind.

begin;

do $$
declare
  v_mine    uuid;
  v_mine_u  uuid := gen_random_uuid();
  v_other   uuid;
  v_other_u uuid := gen_random_uuid();
  v_admin   uuid;
  v_admin_u uuid := gen_random_uuid();
  v_client  uuid;
  v_else    uuid;
  v_cal     uuid;
  v_mail    uuid;
  v_contact uuid;
  v_counselor uuid;
  v_n       integer;
  failures  text[] := '{}';
begin
  insert into public.staff (name, email, role, active)
  values ('ZZ File Owner', 'zz-file-owner@example.test', 'Job Search', true) returning id into v_mine;
  insert into public.staff (name, email, role, active)
  values ('ZZ File Colleague', 'zz-file-colleague@example.test', 'Job Search', true) returning id into v_other;
  insert into public.staff (name, email, role, active)
  values ('ZZ File Admin', 'zz-file-admin@example.test', 'Admin', true) returning id into v_admin;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_mine_u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-file-owner@example.test', '{}', '{}', now(), now()),
         (v_other_u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-file-colleague@example.test', '{}', '{}', now(), now()),
         (v_admin_u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-file-admin@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_mine_u where id = v_mine;
  update public.staff set user_id = v_other_u where id = v_other;
  update public.staff set user_id = v_admin_u where id = v_admin;

  insert into public.clients (name, stage, status, assigned_staff_id, phone)
  values ('ZZ Filed Person', 'Job Coaching', 'Active', v_mine, '(801) 555-0180') returning id into v_client;
  insert into public.clients (name, stage, status, assigned_staff_id, phone)
  values ('ZZ Someone Else Entirely', 'Job Coaching', 'Active', v_mine, '(801) 555-0181') returning id into v_else;

  -- ── only the sweep offers ──────────────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_mine_u, 'role', 'authenticated')::text, true);
  begin
    perform public.to_file_offer(v_mine, 'Calendar', 'ZQ-EVENT-BY-HAND', 'ZQ by hand');
    failures := failures || 'FAILED: a signed-in person put something in an inbox'::text;
  exception when insufficient_privilege then
    raise notice 'ok  only the nightly sweep offers something to file';
  end;

  -- ── as the sweep ───────────────────────────────────────────
  perform set_config('role', 'service_role', true);
  perform set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);

  v_cal := public.to_file_offer(v_mine, 'Calendar', 'ZQ-EVENT-1', 'ZQ Meeting with ZZ Filed Person',
                                'Zion office', timestamptz '2026-11-03 17:00+00', v_client, 'named');
  -- The same event again, which is what a sixty-day first look followed by a
  -- nightly sweep does.
  if public.to_file_offer(v_mine, 'Calendar', 'ZQ-EVENT-1', 'ZQ Meeting with ZZ Filed Person',
                          'Zion office', timestamptz '2026-11-03 17:00+00', v_client, 'named') <> v_cal then
    failures := failures || 'FAILED: the same appointment was offered twice'::text;
  elsif (select count(*) from public.to_file where staff_id = v_mine and source = 'Calendar') <> 1 then
    failures := failures || 'FAILED: two rows for one appointment'::text;
  else
    raise notice 'ok  an appointment is offered once, however often the sweep runs';
  end if;

  -- ── and nothing is on the client's record ─────────────────
  if exists (select 1 from public.contact_log where client_id = v_client)
     or exists (select 1 from public.notes where client_id = v_client)
     or exists (select 1 from public.calendar_events where client_id = v_client) then
    failures := failures || 'FAILED: something unconfirmed is already on the client''s record'::text;
  else
    raise notice 'ok  an unconfirmed item is on nobody''s record, so no report can carry it';
  end if;

  -- ── mail that names somebody ──────────────────────────────
  -- A mail_log row names a client or a counselor; "unfiled" is a row with a
  -- counselor and no client, which is what a message about somebody looks
  -- like before anybody files it.
  insert into public.counselors (name, email)
  values ('ZQ File Counselor', 'zq-file-counselor@example.test') returning id into v_counselor;
  insert into public.mail_log
    (staff_id, counselor_id, graph_message_id, subject, sent_at, direction, counterpart_email, filed_at)
  values (v_mine, v_counselor, 'ZQ-MSG-1', 'ZQ update on ZZ Filed Person', now() - interval '1 day',
          'Incoming', 'zq-file-counselor@example.test', now());
  insert into public.mail_log
    (staff_id, counselor_id, graph_message_id, subject, sent_at, direction, counterpart_email, filed_at)
  values (v_mine, v_counselor, 'ZQ-MSG-2', 'ZQ a newsletter about nothing', now() - interval '1 day',
          'Incoming', 'zq-news@example.test', now());

  v_n := public.to_file_from_mail(public.practice_today() - 7);
  if not exists (select 1 from public.to_file f
                  where f.staff_id = v_mine and f.source = 'Email' and f.source_key = 'ZQ-MSG-1'
                    and f.client_id = v_client) then
    failures := failures || 'FAILED: mail naming a client was not offered to its owner'::text;
  elsif exists (select 1 from public.to_file f where f.source_key = 'ZQ-MSG-2') then
    failures := failures || 'FAILED: mail naming nobody was offered anyway'::text;
  else
    raise notice 'ok  unfiled mail that names an active client is offered, and mail that names nobody is not';
  end if;
  select id into v_mail from public.to_file where source_key = 'ZQ-MSG-1';

  -- Run again: the same mail is not offered twice.
  -- Counted over this script's own messages. The sweep is asked about every
  -- mailbox in the window, and the practice's real mail is in that window:
  -- a bare count here would be counting the practice, not the rule.
  v_n := public.to_file_from_mail(public.practice_today() - 7);
  if (select count(*) from public.to_file where source = 'Email' and source_key like 'ZQ-MSG-%') <> 1 then
    failures := failures || 'FAILED: the same email was offered twice'::text;
  else
    raise notice 'ok  and not a second time the next night';
  end if;

  -- ── an item is its owner's ────────────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_other_u, 'role', 'authenticated')::text, true);
  if exists (select 1 from public.to_file where id = v_cal) then
    failures := failures || 'FAILED: a colleague can read somebody else''s inbox'::text;
  else
    raise notice 'ok  an inbox is one person''s, and a colleague does not see it';
  end if;
  begin
    perform public.to_file_confirm(v_cal, 'happened');
    failures := failures || 'FAILED: a colleague confirmed something in somebody else''s inbox'::text;
  exception when insufficient_privilege then
    raise notice 'ok  nor confirm anything in it';
  end;

  -- ── the three answers ─────────────────────────────────────
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_mine_u, 'role', 'authenticated')::text, true);

  -- Wrong client: the guess goes and the item waits.
  perform public.to_file_confirm(v_cal, 'wrong client');
  if (select state from public.to_file where id = v_cal) <> 'Waiting'
     or (select client_id from public.to_file where id = v_cal) is not null then
    failures := failures || 'FAILED: "wrong client" filed a judgment about the wrong client'::text;
  else
    raise notice 'ok  "wrong client" removes the guess and leaves it waiting';
  end if;

  -- And confirming needs to know whose it was.
  begin
    perform public.to_file_confirm(v_cal, 'happened');
    failures := failures || 'FAILED: something was confirmed onto nobody'::text;
  exception when check_violation then
    raise notice 'ok  confirming needs a client first';
  end;

  perform public.to_file_assign(v_cal, v_else);
  if (select client_id from public.to_file where id = v_cal) <> v_else then
    failures := failures || 'FAILED: assigning it to a client did nothing'::text;
  else
    raise notice 'ok  a person says whose it was, and that is what is kept';
  end if;

  -- It happened: one contact-log entry, with the category, and the item says
  -- what it made.
  v_contact := public.to_file_confirm(v_cal, 'happened', 'ZQ met at the office', 'Job coaching');
  if v_contact is null then
    failures := failures || 'FAILED: confirming it made no contact-log entry'::text;
  elsif (select count(*) from public.contact_log where client_id = v_else) <> 1 then
    failures := failures || 'FAILED: confirming it made more than one entry, or none'::text;
  elsif not exists (select 1 from public.contact_log c
                     where c.id = v_contact and c.category = 'Job coaching'
                       and c.method = 'Appointment' and c.staff_id = v_mine
                       and c.date = date '2026-11-03') then
    failures := failures || 'FAILED: the entry does not carry the category, the method, the day and who'::text;
  elsif not exists (select 1 from public.to_file f
                     where f.id = v_cal and f.state = 'Confirmed' and f.outcome = 'happened'
                       and f.contact_id = v_contact and f.decided_by = v_mine
                       and f.decided_at is not null) then
    failures := failures || 'FAILED: the item does not say who confirmed it or what it made'::text;
  else
    raise notice 'ok  confirming it writes one contact-log entry, and the item says who and what';
  end if;

  -- Twice is refused, which is what stops a second contact for one meeting.
  begin
    perform public.to_file_confirm(v_cal, 'happened');
    failures := failures || 'FAILED: an item was confirmed twice'::text;
  exception when check_violation then
    raise notice 'ok  and it cannot be confirmed a second time';
  end;

  -- ── discard leaves no trace ───────────────────────────────
  select count(*) into v_n from public.contact_log where client_id = v_client;
  perform public.to_file_discard(v_mail, 'ZQ not about the work');
  if (select state from public.to_file where id = v_mail) <> 'Discarded' then
    failures := failures || 'FAILED: discarding it left it waiting'::text;
  elsif (select count(*) from public.contact_log where client_id = v_client) <> v_n then
    failures := failures || 'FAILED: discarding something wrote to the contact log'::text;
  elsif exists (select 1 from public.notes where client_id = v_client)
     or exists (select 1 from public.calendar_events where client_id = v_client) then
    failures := failures || 'FAILED: discarding something wrote to the client''s record'::text;
  else
    raise notice 'ok  discarding it leaves nothing on anybody''s record';
  end if;

  -- ── Admin can clear an inbox ──────────────────────────────
  perform set_config('role', 'service_role', true);
  perform set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
  perform public.to_file_offer(v_mine, 'Calendar', 'ZQ-EVENT-2', 'ZQ another meeting',
                               '', timestamptz '2026-11-04 17:00+00', v_client, 'named');
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_admin_u, 'role', 'authenticated')::text, true);
  perform public.to_file_discard(
    (select id from public.to_file where source_key = 'ZQ-EVENT-2'), 'ZQ cleared while she was away');
  if (select state from public.to_file where source_key = 'ZQ-EVENT-2') <> 'Discarded' then
    failures := failures || 'FAILED: Admin cannot clear an inbox'::text;
  else
    raise notice 'ok  Admin can clear somebody''s inbox while they are away';
  end if;

  -- ── and nobody writes it directly ─────────────────────────
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  if has_table_privilege('authenticated', 'public.to_file', 'insert')
     or has_table_privilege('authenticated', 'public.to_file', 'update')
     or has_table_privilege('authenticated', 'public.to_file', 'delete')
     or has_table_privilege('anon', 'public.to_file', 'select')
     or has_function_privilege('authenticated',
          'public.to_file_offer(uuid, text, text, text, text, timestamptz, uuid, text)', 'execute')
     or has_function_privilege('authenticated', 'public.to_file_from_mail(date)', 'execute') then
    failures := failures || 'FAILED: the inbox can be written without going through a function'::text;
  else
    raise notice 'ok  the inbox is only written through the functions that say who did it';
  end if;

  if array_length(failures, 1) > 0 then
    raise notice '';
    raise notice '%  PROBLEM(S):', array_length(failures, 1);
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '';
  raise notice '--- NOTHING IS FILED UNTIL SOMEBODY SAYS SO ---';
end $$;

rollback;
