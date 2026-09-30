-- Zion Vocational Rehab CRM — a client's text that nobody answered (0130)
--
-- What has to hold, each tried from the direction that would break it:
--
--   A text waiting two business days raises a task for whoever works that
--   client, and only one however many nights pass.
--
--   Five business days puts it on the Admin's dashboard as well.
--
--   A weekend is not two days. A text on Friday afternoon is not late on
--   Sunday, because an alert that cries wolf is one people learn to ignore.
--
--   A conversation we answered is not waiting on us, whoever spoke first.
--
--   Answering it afterwards takes the task and the alert away again.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_staff uuid;
  v_client uuid;
  v_conv uuid;
  v_fresh uuid;
  v_answered uuid;
  v_n integer;
  failures text[] := '{}';
begin
  insert into public.staff (name, email, role, active) values ('ZZ Text Staff', 'zz-text@example.test', 'Job Search', true) returning id into v_staff;
  insert into public.clients (name, stage, status, assigned_staff_id)
  values ('ZZ Text Client', 'Job Development', 'Active', v_staff) returning id into v_client;

  -- Waiting a fortnight: the client spoke last.
  insert into public.conversations (kind, title, client_id, created_by)
  values ('sms', 'ZZ waiting', v_client, v_staff) returning id into v_conv;
  insert into public.messages (conversation_id, sender_kind, sender_label, body, created_at)
  values (v_conv, 'client', 'ZZ Text Client', 'Is there any news?', now() - interval '14 days');

  -- Two hours old: nobody is late.
  insert into public.conversations (kind, title, client_id, created_by)
  values ('sms', 'ZZ fresh', v_client, v_staff) returning id into v_fresh;
  insert into public.messages (conversation_id, sender_kind, sender_label, body, created_at)
  values (v_fresh, 'client', 'ZZ Text Client', 'Just now', now() - interval '2 hours');

  -- Answered: we spoke last, however long ago.
  insert into public.conversations (kind, title, client_id, created_by)
  values ('sms', 'ZZ answered', v_client, v_staff) returning id into v_answered;
  insert into public.messages (conversation_id, sender_kind, sender_label, body, created_at)
  values (v_answered, 'client', 'ZZ Text Client', 'Question', now() - interval '20 days');
  insert into public.messages (conversation_id, sender_kind, sender_staff_id, sender_label, body, created_at)
  values (v_answered, 'staff', v_staff, 'ZZ Text Staff', 'Answered', now() - interval '19 days');

  -- ── who is waiting, and who is not ────────────────────────
  if not exists (select 1 from public.texts_unanswered where conversation_id = v_conv) then
    failures := failures || 'FAILED: a text waiting a fortnight is not listed as waiting'::text;
  end if;
  if exists (select 1 from public.texts_unanswered where conversation_id = v_answered) then
    failures := failures || 'FAILED: a conversation we answered is still counted as waiting on us'::text;
  else
    raise notice 'ok  waiting means the client spoke last, not that somebody has not read it';
  end if;

  -- ── a weekend is not two business days ────────────────────
  if public.business_days_between(timestamptz '2026-09-25 16:00', timestamptz '2026-09-27 16:00') <> 0 then
    failures := failures || format('FAILED: Friday afternoon to Sunday counts as %s business days',
      public.business_days_between(timestamptz '2026-09-25 16:00', timestamptz '2026-09-27 16:00'));
  elsif public.business_days_between(timestamptz '2026-09-25 16:00', timestamptz '2026-09-29 16:00') <> 2 then
    failures := failures || format('FAILED: Friday to Tuesday counts as %s business days',
      public.business_days_between(timestamptz '2026-09-25 16:00', timestamptz '2026-09-29 16:00'));
  else
    raise notice 'ok  a weekend is not two business days: Friday to Sunday is none, Friday to Tuesday is two';
  end if;

  -- ── the task, and only one of it ──────────────────────────
  perform public.escalate_unanswered_texts(public.practice_today());
  perform public.escalate_unanswered_texts(public.practice_today());

  select count(*) into v_n from public.tasks
   where source_kind = 'text_unanswered' and source_ref = v_conv and status = 'Open';
  if v_n <> 1 then
    failures := failures || format('FAILED: two nights of waiting raised %s tasks, not 1', v_n);
  end if;

  select count(*) into v_n from public.tasks
   where source_kind = 'text_unanswered' and source_ref = v_fresh;
  if v_n <> 0 then
    failures := failures || 'FAILED: a text two hours old raised a task'::text;
  else
    raise notice 'ok  one task for the one that is late, none for the one that is not';
  end if;

  -- ── and the Admin hears about it at five ──────────────────
  select count(*) into v_n from public.notifications
   where kind = 'text_unanswered' and client_id = v_client and resolved_at is null;
  if v_n <> 1 then
    failures := failures || format('FAILED: a fortnight of waiting put %s alerts on the Admin''s dashboard, not 1', v_n);
  else
    raise notice 'ok  five business days reaches the Admin, once';
  end if;

  -- ── answering it puts both away ───────────────────────────
  insert into public.messages (conversation_id, sender_kind, sender_staff_id, sender_label, body)
  values (v_conv, 'staff', v_staff, 'ZZ Text Staff', 'Sorry for the delay - here is the news');
  perform public.escalate_unanswered_texts(public.practice_today());

  select count(*) into v_n from public.tasks
   where source_kind = 'text_unanswered' and source_ref = v_conv and status = 'Open';
  if v_n <> 0 then
    failures := failures || 'FAILED: the task survived the answer'::text;
  end if;
  select count(*) into v_n from public.notifications
   where kind = 'text_unanswered' and client_id = v_client and resolved_at is null;
  if v_n <> 0 then
    failures := failures || 'FAILED: the Admin''s alert survived the answer'::text;
  else
    raise notice 'ok  answering takes the task and the alert away again';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
