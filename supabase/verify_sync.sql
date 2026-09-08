-- Zion Vocational Rehab CRM — calendar and mail sync
--
-- The rules that matter here are about restraint. This integration can see a
-- staff member's whole mailbox, and almost all of what it can see it must not
-- keep: no body ever, nothing at all where no address matches somebody the
-- practice already knows, and nothing from a thread somebody has excluded.
--
-- The other rule is that a finished appointment never logs service hours by
-- itself. Hours are what USOR is billed for.
--
-- Runs inside a transaction that is rolled back. Nothing here is left behind.

begin;

do $$
declare
  v_admin    uuid;
  v_adm_uid  uuid;
  v_rei      uuid;
  v_rei_uid  uuid;
  v_marg     uuid;
  v_marg_uid uuid;
  v_client   uuid;
  v_counsel  uuid;
  v_event    uuid;
  v_logged   boolean;
  v_count    int;
  failures   text[] := '{}';
begin
  select id, user_id into v_admin, v_adm_uid  from public.staff where legacy_id = 's1';
  select id, user_id into v_rei,  v_rei_uid   from public.staff where legacy_id = 's2';
  select id, user_id into v_marg, v_marg_uid  from public.staff where legacy_id = 's3';
  select id into v_client   from public.clients order by created_at limit 1;
  select id into v_counsel  from public.counselors order by created_at limit 1;

  -- ── mail_log cannot be written by hand ─────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_rei_uid, 'role', 'authenticated')::text, true);

  begin
    insert into public.mail_log (staff_id, client_id, graph_message_id, subject,
                                 sent_at, direction, counterpart_email)
    values (v_rei, v_client, 'made-up', 'Invented', now(), 'Incoming', 'nobody@example.com');
    failures := failures || 'FAILED: a mail record was written by hand'::text;
  exception when insufficient_privilege then
    raise notice 'ok  a log of correspondence cannot be composed by hand';
  end;

  -- ── the logging function writes for the caller only ────────
  v_logged := public.log_mail_message(
    v_client, null, 'msg-1', 'thread-1', 'A real subject', now(), 'Incoming',
    'someone@example.com', 'https://outlook/1');

  if not v_logged then
    failures := failures || 'FAILED: a matched message was not logged'::text;
  else
    raise notice 'ok  a message matching a client is logged';
  end if;

  if not exists (select 1 from public.mail_log
                  where graph_message_id = 'msg-1' and staff_id = v_rei) then
    failures := failures || 'FAILED: the row was written against the wrong person'::text;
  else
    raise notice 'ok  the row belongs to the mailbox it came from';
  end if;

  -- The same message twice is one record, not two.
  v_logged := public.log_mail_message(
    v_client, null, 'msg-1', 'thread-1', 'A real subject', now(), 'Incoming',
    'someone@example.com', 'https://outlook/1');
  select count(*) into v_count from public.mail_log where graph_message_id = 'msg-1';
  if v_count <> 1 or v_logged then
    failures := failures || format('FAILED: re-running logged the same message again (%s rows)', v_count);
  else
    raise notice 'ok  a second sweep does not log the same message twice';
  end if;

  -- ── mail logged against nothing is refused ─────────────────
  begin
    perform public.log_mail_message(
      null, null, 'msg-2', 'thread-2', 'Matches nobody', now(), 'Incoming',
      'stranger@example.com', '');
    failures := failures || 'FAILED: mail matching nobody was logged'::text;
  exception when check_violation then
    raise notice 'ok  mail matching nobody is refused, not stored and hidden';
  end;

  -- ── excluding a thread removes it and keeps it out ─────────
  perform public.exclude_mail_thread('thread-1', 'personal');

  if exists (select 1 from public.mail_log where conversation_id = 'thread-1') then
    failures := failures || 'FAILED: excluding a thread left its messages logged'::text;
  else
    raise notice 'ok  excluding a thread removes what it already logged';
  end if;

  v_logged := public.log_mail_message(
    v_client, null, 'msg-3', 'thread-1', 'A reply', now(), 'Incoming',
    'someone@example.com', '');
  if v_logged or exists (select 1 from public.mail_log where conversation_id = 'thread-1') then
    failures := failures || 'FAILED: an excluded thread was logged again by a later sweep'::text;
  else
    raise notice 'ok  a reply on an excluded thread does not bring it back';
  end if;

  -- ── there is nowhere to put a body ─────────────────────────
  if exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'mail_log'
       and column_name in ('body', 'body_preview', 'content', 'body_content')
  ) then
    failures := failures || 'FAILED: mail_log has somewhere to put a message body'::text;
  else
    raise notice 'ok  mail_log has no column a body could be written to';
  end if;

  -- ── a finished appointment does not log hours ──────────────
  insert into public.calendar_events (client_id, staff_id, kind, title, starts_at, ends_at, origin)
  values (v_client, v_rei, 'Coaching visit', 'ZZ finished visit',
          now() - interval '3 hours', now() - interval '2 hours', 'CRM')
  returning id into v_event;

  select count(*) into v_count from public.service_entries
   where staff_id = v_rei and date = current_date;
  if v_count <> 0 then
    failures := failures || 'FAILED: a finished visit logged service hours by itself'::text;
  else
    raise notice 'ok  a finished visit logs no service hours by itself';
  end if;

  if (select hours_prompt_answered_at from public.calendar_events where id = v_event) is not null then
    failures := failures || 'FAILED: the offer was marked answered before anybody answered'::text;
  else
    raise notice 'ok  the offer to log hours starts unanswered';
  end if;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  -- ── a colleague cannot touch somebody else's appointment ───
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_marg_uid, 'role', 'authenticated')::text, true);

  update public.calendar_events set title = 'ZZ hijacked' where id = v_event;
  get diagnostics v_count = row_count;
  if v_count > 0 then
    failures := failures || 'FAILED: a colleague edited somebody else''s appointment'::text;
  else
    raise notice 'ok  an appointment is only editable by whose calendar it is';
  end if;

  -- Client appointments are client information, so seeing them is fine.
  if not exists (select 1 from public.calendar_events where id = v_event) then
    failures := failures || 'FAILED: a colleague cannot see a client appointment at all'::text;
  else
    raise notice 'ok  a colleague can see the appointment, as with any client record';
  end if;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  -- ── the sweep door is closed to signed-in people ───────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);

  begin
    perform public.get_microsoft_tokens_for_sync(v_rei);
    failures := failures || 'FAILED: Admin reached the unattended sweep''s token function'::text;
  exception when insufficient_privilege then
    raise notice 'ok  the sweep''s token function is closed to signed-in people, Admin included';
  end;

  begin
    perform public.log_mail_message_for_sync(
      v_rei, v_client, null, 'msg-9', 'thread-9', 'As somebody else', now(),
      'Incoming', 'x@example.com', '');
    failures := failures || 'FAILED: Admin logged mail as another person'::text;
  exception when insufficient_privilege then
    raise notice 'ok  nobody signed in can write a mail record as another person';
  end;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  if failures = '{}' then
    raise notice '';
    raise notice '--- CALENDAR AND MAIL SYNC VERIFIED ---';
  else
    raise notice '';
    raise notice '%  PROBLEM(S):', array_length(failures, 1);
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
