-- Zion Vocational Rehab CRM — interview and follow-up reminders
--
-- The reminders live on the row rather than in a screen, because the dates
-- that raise them are set from the job panel, from the leads board, and by the
-- status shortcut. A reminder that only appears when one of those three was
-- used is worse than none: it teaches people to trust it, and then it is
-- quiet on the day that mattered.
--
-- So everything below writes to lead_matches directly, the way any of those
-- callers eventually does, and checks what appeared.
--
-- Runs inside a transaction that is rolled back. Nothing here is left behind.

begin;

do $$
declare
  v_admin    uuid;
  v_adm_uid  uuid;
  v_client   uuid;
  v_owner    uuid;
  v_emp      uuid;
  v_lead     uuid;
  v_match    uuid;
  v_task     uuid;
  v_count    int;
  v_seen     uuid[];
  v_text     text;
  v_due      date;
  v_state    text;
  failures   text[] := '{}';
begin
  select id, user_id into v_admin, v_adm_uid from public.staff where legacy_id = 's1';
  -- A client with somebody assigned, because who the reminder belongs to is
  -- one of the things being checked.
  select id, assigned_staff_id into v_client, v_owner
    from public.clients where assigned_staff_id is not null and status = 'Active'
    order by created_at limit 1;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);

  insert into public.employers (name, created_by) values ('ZZ Reminder Co', v_admin)
  returning id into v_emp;
  insert into public.job_leads (employer_id, title, created_by)
  values (v_emp, 'ZZ Reminder Role', v_admin) returning id into v_lead;
  insert into public.lead_matches (lead_id, client_id, created_by)
  values (v_lead, v_client, v_admin) returning id into v_match;

  -- ── a job with no dates raises nothing ─────────────────────
  select count(*) into v_count from public.tasks where source_match_id = v_match;
  if v_count <> 0 then
    failures := failures || format('FAILED: a job with no dates raised %s reminders', v_count);
  else
    raise notice 'ok  a job with no dates raises no reminders';
  end if;

  -- ── an interview raises two, and queues the calendar ───────
  update public.lead_matches set interview_on = current_date + 7 where id = v_match;

  select count(*) into v_count from public.tasks
   where source_match_id = v_match and status = 'Open';
  if v_count <> 2 then
    failures := failures || format('FAILED: an interview raised %s reminders, expected 2', v_count);
  else
    raise notice 'ok  an interview raises the prep task and the day-of task';
  end if;

  select due into v_due from public.tasks
   where source_match_id = v_match and source_kind = 'Interview prep';
  if v_due <> current_date + 6 then
    failures := failures || format('FAILED: prep is due %s, expected the day before', v_due);
  else
    raise notice 'ok  prep is due the day before, not on the day';
  end if;

  if not exists (select 1 from public.calendar_events
                  where source_match_id = v_match and source_kind = 'Interview'
                    and push_state = 'Pending' and kind = 'Interview') then
    failures := failures || 'FAILED: the interview was not queued for Outlook'::text;
  else
    raise notice 'ok  the interview is queued for Outlook, for the app to send';
  end if;

  -- ── it belongs to whoever has the client ───────────────────
  if exists (select 1 from public.tasks
              where source_match_id = v_match and assigned_staff_id is distinct from v_owner) then
    failures := failures || 'FAILED: a reminder went to somebody other than the assigned staff member'::text;
  else
    raise notice 'ok  the reminders go to whoever the client is assigned to';
  end if;

  -- ── moving the date moves them, rather than piling up ──────
  update public.lead_matches set interview_on = current_date + 14 where id = v_match;

  select count(*) into v_count from public.tasks
   where source_match_id = v_match and status = 'Open';
  select due into v_due from public.tasks
   where source_match_id = v_match and source_kind = 'Interview day';
  if v_count <> 2 or v_due <> current_date + 14 then
    failures := failures || format('FAILED: moving the date left %s reminders, day-of due %s',
                                   v_count, v_due);
  else
    raise notice 'ok  moving the date moves the reminders instead of adding more';
  end if;

  if (select starts_at::date from public.calendar_events
       where source_match_id = v_match and source_kind = 'Interview') <> current_date + 14 then
    failures := failures || 'FAILED: the queued appointment did not move with the date'::text;
  else
    raise notice 'ok  the queued appointment moves with the date';
  end if;

  -- ── a reminder already dealt with is not reopened ──────────
  update public.tasks set status = 'Done', done_at = public.practice_today()
   where source_match_id = v_match and source_kind = 'Interview prep';
  update public.lead_matches set interview_on = current_date + 21 where id = v_match;

  if (select status from public.tasks
       where source_match_id = v_match and source_kind = 'Interview prep'
         and status = 'Done') is null then
    failures := failures || 'FAILED: a finished reminder was reopened by moving the date'::text;
  else
    raise notice 'ok  a reminder somebody has already dealt with is not reopened';
  end if;

  -- ── a second round of chasing gets its own reminder ────────
  -- The first version of this indexed every row rather than open ones, so a
  -- finished follow-up blocked the next one and the job went quiet — the exact
  -- failure these reminders exist to prevent.
  update public.lead_matches set follow_up_on = current_date + 3 where id = v_match;
  update public.tasks set status = 'Done', done_at = public.practice_today()
   where source_match_id = v_match and source_kind = 'Follow-up';
  update public.lead_matches set follow_up_on = current_date + 30 where id = v_match;

  select count(*) into v_count from public.tasks
   where source_match_id = v_match and source_kind = 'Follow-up' and status = 'Open';
  if v_count <> 1 then
    failures := failures || format('FAILED: chasing again raised %s reminders, expected 1', v_count);
  else
    raise notice 'ok  chasing again after a finished follow-up raises a fresh reminder';
  end if;

  -- ── clearing the date takes them away ──────────────────────
  update public.calendar_events set outlook_event_id = 'ZZ-in-outlook', push_state = 'Pushed'
   where source_match_id = v_match and source_kind = 'Interview';
  update public.lead_matches set interview_on = null where id = v_match;

  if exists (select 1 from public.tasks
              where source_match_id = v_match
                and source_kind in ('Interview prep', 'Interview day') and status = 'Open') then
    failures := failures || 'FAILED: clearing the date left an open interview reminder'::text;
  else
    raise notice 'ok  clearing the date closes the reminders it raised';
  end if;

  select push_state into v_state from public.calendar_events
   where source_match_id = v_match and source_kind = 'Interview';
  if v_state <> 'To remove' then
    failures := failures || format('FAILED: an appointment already in Outlook was left as %s', v_state);
  else
    raise notice 'ok  an appointment already in Outlook is marked for removal, not orphaned';
  end if;

  -- ── answering the prompt moves the job ─────────────────────
  select id into v_task from public.tasks
   where source_match_id = v_match and source_kind = 'Follow-up' and status = 'Open';
  select coalesce(array_agg(id), '{}') into v_seen
    from public.notes where client_id = v_client;

  perform public.answer_reminder(v_task, 'Offer', 'ZZ they offered it');

  if (select status from public.lead_matches where id = v_match) <> 'Offer' then
    failures := failures || 'FAILED: answering the prompt did not move the job'::text;
  else
    raise notice 'ok  answering the prompt moves the job along';
  end if;

  if (select status from public.tasks where id = v_task) <> 'Done' then
    failures := failures || 'FAILED: answering the prompt left the task open'::text;
  else
    raise notice 'ok  answering the prompt closes the task';
  end if;

  select text into v_text from public.notes
   where client_id = v_client and not (id = any(v_seen));
  if v_text is null or v_text not like '%ZZ they offered it%' then
    failures := failures || 'FAILED: the outcome did not reach the client record'::text;
  else
    raise notice 'ok  the outcome is written on the client record by the same note trigger';
  end if;

  -- ── the prompt only applies to reminders ───────────────────
  insert into public.tasks (client_id, title, status, assigned_staff_id, created_by)
  values (v_client, 'ZZ hand-written task', 'Open', v_owner, v_admin)
  returning id into v_task;
  begin
    perform public.answer_reminder(v_task, 'Offer', 'nonsense');
    failures := failures || 'FAILED: a hand-written task was treated as a job reminder'::text;
  exception when check_violation then
    raise notice 'ok  a task nobody raised from a job has nothing to answer';
  end;

  -- ── removing the job clears what is still pending ──────────
  update public.lead_matches set follow_up_on = current_date + 40 where id = v_match;
  select count(*) into v_count from public.tasks
   where source_match_id = v_match and status = 'Done';
  delete from public.lead_matches where id = v_match;

  if exists (select 1 from public.tasks where source_match_id = v_match and status = 'Open') then
    failures := failures || 'FAILED: removing the job left open reminders behind'::text;
  else
    raise notice 'ok  removing the job clears the reminders still outstanding';
  end if;

  -- ── today means today in Utah ──────────────────────────────
  if public.practice_today() <> (now() at time zone 'America/Denver')::date then
    failures := failures || 'FAILED: practice_today() is not the date in Utah'::text;
  else
    raise notice 'ok  today means the day it is in Utah, not on the server';
  end if;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  if failures = '{}' then
    raise notice '';
    raise notice '--- JOB REMINDERS VERIFIED ---';
  else
    raise notice '';
    raise notice '%  PROBLEM(S):', array_length(failures, 1);
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
