-- Zion Vocational Rehab CRM — client email (0233-0241)
--
-- The six things the owner asked to be sure of, and two more that are the
-- reason some of them are written the way they are.
--
-- The one worth explaining is the fourth. "A non-filed message is never
-- stored" cannot be proved by looking at what is in `mail_log`, because an
-- empty result proves only that nobody happened to file anything. What is
-- proved instead is that there is nowhere for it to go and no way to put it
-- there: the table has no column a body could occupy, nobody signed in can
-- insert a row by hand, and the one function that files refuses a message
-- with no client. A message nobody files reaches none of those.
--
-- The sixth is written the same way round. "The notification goes to
-- assigned staff and Margaret only" is not "two rows exist" - it is that a
-- third person cannot read them, which is asked as that person, under RLS.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_admin      uuid;
  v_admin_uid  uuid;
  v_coach      uuid;
  v_coach_uid  uuid;
  v_third      uuid;
  v_third_uid  uuid;
  v_standing   uuid;
  v_client     uuid;
  v_other      uuid;
  v_mail       uuid;
  v_reply      uuid;
  v_n          integer;
  v_text       text;
  v_how        text;
  v_subject    text;
  v_can        boolean;
  v_filed      integer;
  failures     text[] := '{}';
begin
  -- ── people to act as ───────────────────────────────────────
  select s.id, s.user_id into v_admin, v_admin_uid from public.staff s
   where s.active and s.user_id is not null and s.role = 'Admin'
     and not coalesce(s.is_system, false)
   order by s.created_at limit 1;
  if v_admin is null then raise exception 'No Admin to act as.'; end if;

  select s.id, s.user_id into v_coach, v_coach_uid from public.staff s
   where s.active and s.user_id is not null and s.role in ('Job Coach', 'Case Manager', 'Job Search')
     and not coalesce(s.is_system, false)
   order by s.created_at limit 1;
  if v_coach is null then raise exception 'Nobody to be the assigned staff member.'; end if;

  -- The standing recipient the practice names, and somebody who is neither.
  select o.mail_notice_staff_id into v_standing from public.org_settings o limit 1;
  if v_standing is null then
    failures := failures || 'FAILED: nobody is set to hear about a reply that files itself'::text;
  end if;

  select s.id, s.user_id into v_third, v_third_uid from public.staff s
   where s.active and s.user_id is not null and s.role <> 'Admin'
     and s.id <> v_coach and s.id is distinct from v_standing
     and not coalesce(s.is_system, false)
   order by s.created_at limit 1;
  if v_third is null then raise exception 'Nobody to be the person who must not be told.'; end if;

  insert into public.clients (name, status, assigned_staff_id, email)
  values ('ZZ Mail Client', 'Active', v_coach, 'zz-mail-client@example.test')
  returning id into v_client;
  insert into public.clients (name, status, email)
  values ('ZZ Mail Other', 'Active', 'zz-mail-other@example.test')
  returning id into v_other;

  -- ── 1. a message sent from the record is filed, and logged ─
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_coach_uid::text, 'role', 'authenticated')::text, true);

  select f.filed into v_filed from public.file_mail_to_client(
    v_client,
    jsonb_build_array(jsonb_build_object(
      'id', 'zz-sent-1', 'conversation', 'zz-conv-1',
      'subject', 'Authorization request', 'sent_at', now()::text,
      'direction', 'Outgoing', 'counterpart', 'zq-counselor@example.test',
      'web_link', '', 'mailbox', '')),
    null, 'sent') f;

  if v_filed <> 1 then
    failures := failures || format('FAILED: sending filed %s messages, expected 1', v_filed)::text;
  end if;

  select m.id, m.filed_how into v_mail, v_how from public.mail_log m
   where m.graph_message_id = 'zz-sent-1';
  if v_mail is null then
    failures := failures || 'FAILED: a message sent from the record was not filed on the client'::text;
  elsif v_how <> 'sent' then
    failures := failures || format('FAILED: the sent message says it was filed "%s"', v_how)::text;
  else
    raise notice 'ok  a message sent from the record is on the client, and says it was sent';
  end if;

  -- The contact log is written by the screen, not by the database, so what is
  -- asserted here is that the screen's row is one a member of staff may
  -- write - which is the half the database owns.
  insert into public.contact_log (client_id, staff_id, date, method, topic, outcome)
  values (v_client, v_coach, current_date, 'Email sent', 'Authorization request',
          'To zq-counselor@example.test');
  select count(*)::int into v_n from public.contact_log
   where client_id = v_client and method = 'Email sent';
  if v_n <> 1 then
    failures := failures || 'FAILED: the contact log did not take the line about the message'::text;
  else
    raise notice 'ok  and the contact log carries who wrote to whom about what';
  end if;

  -- ── 2. a reply on that thread files itself, as "auto" ──────
  perform set_config('request.jwt.claims', '', true);
  perform set_config('role', 'postgres', true);

  if public.client_for_thread('zz-conv-1') is distinct from v_client then
    failures := failures || 'FAILED: the thread does not say which client it belongs to'::text;
  end if;

  perform public.log_mail_message_for_sync(
    v_coach, v_client, null, 'zz-reply-1', 'zz-conv-1', 'Re: Authorization request',
    now(), 'Incoming', 'zq-counselor@example.test', '', 'auto');

  select m.id, m.filed_how into v_reply, v_how from public.mail_log m
   where m.graph_message_id = 'zz-reply-1';
  if v_reply is null then
    failures := failures || 'FAILED: a reply on a filed thread was not recorded'::text;
  elsif v_how <> 'auto' then
    failures := failures || format('FAILED: the reply says it was filed "%s", expected "auto"', v_how)::text;
  elsif (select m.filed_by from public.mail_log m where m.id = v_reply) is not null then
    failures := failures || 'FAILED: a reply nobody filed records somebody as having filed it'::text;
  else
    raise notice 'ok  a reply on a filed thread files itself, marked auto, with nobody''s name on it';
  end if;

  -- ── 3. unfiling takes it off the client, not out of the mailbox ──
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_coach_uid::text, 'role', 'authenticated')::text, true);

  begin
    perform public.unfile_mail(v_mail, '   ');
    failures := failures || 'FAILED: a message came off a client with no reason given'::text;
  exception when check_violation then
    raise notice 'ok  unfiling without a reason is refused';
  end;

  select u.subject into v_subject from public.unfile_mail(v_mail, 'Wrong client.') u;
  if v_subject is null then
    failures := failures || 'FAILED: unfiling said nothing about what came off'::text;
  end if;

  select count(*)::int into v_n from public.client_mail where client_id = v_client and id = v_mail;
  if v_n <> 0 then
    failures := failures || 'FAILED: an unfiled message is still on the client'::text;
  else
    raise notice 'ok  it is off the client';
  end if;

  -- The row itself stays, with the reason on it. This is the mailbox's end of
  -- the promise: nothing was deleted anywhere.
  select count(*)::int into v_n from public.mail_log
   where id = v_mail and unfiled_reason = 'Wrong client.' and unfiled_by = v_coach;
  if v_n <> 1 then
    failures := failures || 'FAILED: unfiling erased the record of itself'::text;
  else
    raise notice 'ok  and the row stays, with who took it off and why';
  end if;

  -- ── 3b. and anybody can take off what nobody filed ────────
  --
  -- The owner said both "the person who filed, or Admin" and, of an
  -- auto-filed reply, "anyone can unfile one". They are the same rule: the
  -- filer is deferred to because they know whether it belonged, and when
  -- nobody filed it there is nobody to defer to (0242).
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_third_uid::text, 'role', 'authenticated')::text, true);
  begin
    perform public.unfile_mail(v_reply, 'Not this client''s.');
    raise notice 'ok  a reply nobody filed can be taken off by anybody on the staff';
  exception when insufficient_privilege then
    failures := failures ||
      'FAILED: an auto-filed reply can only be unfiled by Admin, which leaves the person who can see the mistake unable to fix it'::text;
  end;

  -- The thread has nothing left on the client, so a later reply does not
  -- quietly put it back. Asserted both ways round: a silent "if" here would
  -- be a check asking nothing, which is how the first version of this passed.
  perform set_config('request.jwt.claims', '', true);
  perform set_config('role', 'postgres', true);
  if public.client_for_thread('zz-conv-1') is not null then
    failures := failures ||
      'FAILED: a fully unfiled thread still answers for the client, so a reply would file itself again'::text;
  else
    raise notice 'ok  a fully unfiled thread stops answering, so a reply does not undo the decision';
  end if;

  -- ── 4. nothing unfiled can be stored at all ───────────────
  --
  -- Not "there is none", which proves nothing, but that there is nowhere to
  -- put one and no way in.
  if has_table_privilege('authenticated', 'public.mail_log', 'insert')
     or has_table_privilege('authenticated', 'public.mail_log', 'update') then
    failures := failures || 'FAILED: somebody signed in can write the mail log by hand'::text;
  else
    raise notice 'ok  nobody signed in can put a message in the log by hand';
  end if;

  select count(*)::int into v_n from information_schema.columns
   where table_schema = 'public' and table_name = 'mail_log'
     and column_name ~ '(body|html|content|preview|message_text)';
  if v_n > 0 then
    failures := failures || 'FAILED: mail_log has somewhere a message body could go'::text;
  else
    raise notice 'ok  and there is no column a message could go in';
  end if;

  -- And filing refuses a message that belongs to nobody.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_coach_uid::text, 'role', 'authenticated')::text, true);
  begin
    perform public.file_mail_to_client(
      '00000000-0000-0000-0000-000000000000'::uuid,
      jsonb_build_array(jsonb_build_object('id', 'zz-nowhere', 'conversation', '')),
      null, 'by hand');
    failures := failures || 'FAILED: a message was filed on a client who is not there'::text;
  exception when no_data_found then
    raise notice 'ok  and filing refuses a client who is not there';
  end;

  -- ── 5. a restricted thread is redacted, not hidden ────────
  perform set_config('request.jwt.claims', '', true);
  perform set_config('role', 'postgres', true);

  perform public.log_mail_message_for_sync(
    v_coach, v_client, null, 'zz-private-1', 'zz-conv-2', 'A private matter',
    now(), 'Incoming', 'zq-counselor@example.test', 'https://outlook.test/x', 'auto');

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_coach_uid::text, 'role', 'authenticated')::text, true);
  perform public.set_mail_restricted('zz-conv-2', v_client, true);

  -- The assigned staff member can read it.
  select cm.can_open, cm.subject into v_can, v_subject from public.client_mail cm
   where cm.conversation_id = 'zz-conv-2';
  if not coalesce(v_can, false) or v_subject <> 'A private matter' then
    failures := failures || 'FAILED: the client''s own staff member cannot read a restricted thread'::text;
  else
    raise notice 'ok  a restricted thread is readable by the client''s assigned staff member';
  end if;

  -- The third person sees the row and not the words.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_third_uid::text, 'role', 'authenticated')::text, true);
  select cm.can_open, cm.subject into v_can, v_subject from public.client_mail cm
   where cm.conversation_id = 'zz-conv-2';
  if v_can is null then
    failures := failures || 'FAILED: a restricted thread is hidden rather than redacted - the row is gone'::text;
  elsif v_can then
    failures := failures || 'FAILED: a restricted thread is readable by somebody it is restricted from'::text;
  elsif v_subject <> '' then
    failures := failures || format('FAILED: a redacted thread still shows its subject: %s', v_subject)::text;
  else
    raise notice 'ok  and to everybody else it is a row with no words in it';
  end if;

  -- ── 6. the reply tells two people, and nobody else ────────
  perform set_config('request.jwt.claims', '', true);
  perform set_config('role', 'postgres', true);

  select count(*)::int into v_n from public.notifications n
   where n.kind = 'mail_reply' and n.client_id = v_client;
  if v_n = 0 then
    failures := failures || 'FAILED: a reply that filed itself told nobody'::text;
  end if;

  -- The assigned staff member, by name.
  select count(*)::int into v_n from public.notifications n
   where n.kind = 'mail_reply' and n.client_id = v_client and n.staff_id = v_coach;
  if v_n = 0 then
    failures := failures || 'FAILED: the client''s own staff member was not told about the reply'::text;
  else
    raise notice 'ok  the assigned staff member is told, by name';
  end if;

  if v_standing is not null then
    select count(*)::int into v_n from public.notifications n
     where n.kind = 'mail_reply' and n.client_id = v_client and n.staff_id = v_standing;
    if v_n = 0 then
      failures := failures || 'FAILED: the standing recipient was not told about the reply'::text;
    else
      raise notice 'ok  and so is the one person the practice names';
    end if;
  end if;

  -- Nobody by role, which is the whole of "nobody else": a notification with
  -- a role on it is readable by everybody who has that role.
  select count(*)::int into v_n from public.notifications n
   where n.kind = 'mail_reply' and n.client_id = v_client and cardinality(n.roles) > 0;
  if v_n > 0 then
    failures := failures ||
      'FAILED: a reply notification carries a role, so everybody with that role can read it'::text;
  else
    raise notice 'ok  and none of them carries a role';
  end if;

  -- Asked as the third person, under their own policies - and asked as
  -- somebody sharing the assigned staff member's role, which is the person
  -- who would actually see a role-stamped notification.
  --
  -- The role is borrowed for the length of this transaction on purpose.
  -- Every role in the practice currently has exactly one person in it, so
  -- asking as whoever happens to be third proves nothing: their role would
  -- not match the leak either way, and the first version of this read a
  -- deliberately leaking notification as unreadable. The leak is a property
  -- of the notification, not of who is on the payroll this month, so the
  -- fixture makes the condition rather than hoping for it.
  update public.staff s set role = (select role from public.staff where id = v_coach)
   where s.id = v_third;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_third_uid::text, 'role', 'authenticated')::text, true);
  select count(*)::int into v_n from public.notifications n
   where n.kind = 'mail_reply' and n.client_id = v_client;
  if v_n > 0 then
    failures := failures ||
      format('FAILED: a colleague in the same role as the assigned staff member can read %s of them', v_n)::text;
  else
    raise notice 'ok  a colleague in the same role, told nothing, can read none of them';
  end if;

  -- And it is on their My day as well as in the bell.
  perform set_config('request.jwt.claims', '', true);
  perform set_config('role', 'postgres', true);
  select count(*)::int into v_n from public.tasks t
   where t.source_kind = 'mail_reply' and t.client_id = v_client and t.assigned_staff_id = v_coach;
  if v_n = 0 then
    failures := failures || 'FAILED: the reply is in the bell but not on My day'::text;
  else
    raise notice 'ok  and it is on My day, not only in the bell';
  end if;

  -- ── 6b. matching an address is not filing, and tells nobody ──
  --
  -- This is the assertion that was missing, and the one that cost something.
  -- The writer defaulted `filed_how` to "auto", so every message the sweep
  -- recognised by address claimed to be a reply on a filed thread - and the
  -- trigger fired on all of it. One sweep put 38 notifications and 38 My day
  -- items in front of Margaret and Rei about mail that was not a reply to
  -- anything (0247).
  --
  -- Two things have to hold, and neither is about counting notifications
  -- afterwards: an address match tells nobody, and it does not become a
  -- filing by being replied to.
  perform public.log_mail_message_for_sync(
    v_coach, v_client, null, 'zz-matched-1', 'zz-conv-3', 'Something that mentioned them',
    now(), 'Incoming', 'zq-counselor@example.test', '', null);

  select m.filed_how into v_how from public.mail_log m where m.graph_message_id = 'zz-matched-1';
  if v_how <> 'matched' then
    failures := failures ||
      format('FAILED: an address match records itself as "%s", so it claims somebody filed it', v_how)::text;
  else
    raise notice 'ok  an address match says it is an address match';
  end if;

  select count(*)::int into v_n from public.notifications n
   where n.kind = 'mail_reply' and n.client_id = v_client
     and n.dedupe_key like '%' || (select id::text from public.mail_log where graph_message_id = 'zz-matched-1') || '%';
  if v_n > 0 then
    failures := failures ||
      'FAILED: an address match raised a notification, which is how one sweep fills somebody''s My day with mail nobody sent them'::text;
  else
    raise notice 'ok  and tells nobody, because nobody replied to anything';
  end if;

  if public.client_for_thread('zz-conv-3') is not null then
    failures := failures ||
      'FAILED: a thread the sweep matched by address answers as filed, so the next reply to it would file itself and notify'::text;
  else
    raise notice 'ok  and a matched thread is not a filed one, so a reply to it does not become one';
  end if;

  -- Anybody may take a matched message off a client, with a reason (owner,
  -- 23 Oct 2026). Nobody chose it and nobody read it, so there is nobody to
  -- defer to - the same reasoning as an auto-filed reply, with more force.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_third_uid::text, 'role', 'authenticated')::text, true);
  begin
    perform public.unfile_mail(
      (select id from public.mail_log where graph_message_id = 'zz-matched-1'),
      'Not about this client.');
    raise notice 'ok  and anybody on the staff can take a matched message off, with a reason';
  exception when insufficient_privilege then
    failures := failures ||
      'FAILED: only Admin can take off a message nobody filed and nobody read'::text;
  end;

  -- ── 7. a client is written to at their own address ─────────
  --
  -- The screen refuses it, and this is the fact the screen refuses it on:
  -- another client's address is findable as another client's.
  select count(*)::int into v_n from public.clients c
   where lower(c.email) = 'zz-mail-other@example.test' and c.id <> v_client;
  if v_n <> 1 then
    failures := failures || 'FAILED: another client''s address is not recognisable as one'::text;
  else
    raise notice 'ok  another client''s address is recognisable as another client''s';
  end if;

  -- ── 8. the templates fill in without leaking ──────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_coach_uid::text, 'role', 'authenticated')::text, true);

  select count(*)::int into v_n from public.mail_templates_for(v_client, null);
  if v_n < 3 then
    failures := failures || format('FAILED: %s templates came back, expected the three', v_n)::text;
  else
    raise notice 'ok  every template fills in, in one question';
  end if;

  select t.body into v_text from public.mail_templates_for(v_client, null) t limit 1;
  if v_text ~ '\{[a-z_]+\}' then
    failures := failures ||
      format('FAILED: a template went out with a field still in brackets: %s', v_text)::text;
  else
    raise notice 'ok  and leaves no field in brackets';
  end if;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('role', 'postgres', true);

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- CLIENT EMAIL VERIFIED ---';
end $$;

rollback;
