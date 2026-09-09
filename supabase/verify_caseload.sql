-- Zion Vocational Rehab CRM — "what is next" behind the caseload view
--
-- The counselor screen answers a question on the phone: is anything booked for
-- her? A wrong answer here is worse than no answer, because it is given with
-- confidence — a follow-up that was due last week reading as a plan, or the
-- second-soonest appointment shown because the soonest was in another table.
--
-- Runs inside a transaction that is rolled back. Nothing here is left behind.

begin;

do $$
declare
  v_admin  uuid;
  v_adm_uid uuid;
  v_client uuid;
  v_lead   uuid;
  v_employer uuid;
  v_match  uuid;
  v_at     timestamptz;
  v_kind   text;
  v_title  text;
  v_task   uuid;
  v_count  int;
  failures text[] := '{}';
begin
  select id, user_id into v_admin, v_adm_uid from public.staff
   where role = 'Admin' and active order by created_at limit 1;
  select id into v_client from public.clients where status = 'Active' order by created_at limit 1;

  -- Whatever this client already has booked is beside the point; clear it so
  -- the fixture is the only thing being read. Rolled back either way.
  delete from public.calendar_events where client_id = v_client;
  update public.tasks set status = 'Done', done_at = public.practice_today()
   where client_id = v_client and status = 'Open';
  update public.lead_matches set interview_on = null, follow_up_on = null
   where client_id = v_client;

  if exists (select 1 from public.client_next_up where client_id = v_client) then
    failures := failures || 'FAILED: something is next for a client with nothing booked'::text;
  else
    raise notice 'ok  a client with nothing booked has nothing next';
  end if;

  -- ── the past is not "next" ─────────────────────────────────
  insert into public.calendar_events (client_id, staff_id, kind, title, starts_at, ends_at, origin)
  values (v_client, v_admin, 'Coaching visit', 'ZZ last week',
          now() - interval '7 days', now() - interval '7 days' + interval '1 hour', 'CRM');

  if exists (select 1 from public.client_next_up where client_id = v_client) then
    failures := failures || 'FAILED: an appointment last week is being called next'::text;
  else
    raise notice 'ok  a visit that already happened is not what is next';
  end if;

  -- ── the soonest thing wins, across all four sources ────────
  insert into public.calendar_events (client_id, staff_id, kind, title, starts_at, ends_at, origin)
  values (v_client, v_admin, 'Coaching visit', 'ZZ in three weeks',
          now() + interval '21 days', now() + interval '21 days 1 hour', 'CRM');

  insert into public.tasks (client_id, title, due, status, assigned_staff_id, created_by)
  values (v_client, 'ZZ task in ten days', public.practice_today() + 10, 'Open', v_admin, v_admin);

  select at, kind into v_at, v_kind from public.client_next_up where client_id = v_client;
  if v_kind <> 'Task' then
    failures := failures || format('FAILED: the task in ten days lost to a "%s" three weeks out', v_kind);
  else
    raise notice 'ok  the soonest wins, whichever table it came from';
  end if;

  select count(*) into v_count from public.client_next_up where client_id = v_client;
  if v_count <> 1 then
    failures := failures || format('FAILED: a client has %s "next" rows', v_count);
  else
    raise notice 'ok  one row per client — a caseload line has room for one answer';
  end if;

  -- ── an interview brings its own reminders with it ──────────
  -- Setting an interview date raises a prep task the day before, an
  -- interview-day task, and the appointment itself. What is "next" is
  -- therefore the prep, not the interview — which is the answer somebody
  -- actually wants on the phone, and is only right because the two features
  -- were built to know about each other.
  select l.id into v_lead from public.job_leads l limit 1;
  if v_lead is null then
    -- No job board yet on this database; make one job to put somebody forward for.
    insert into public.employers (name) values ('ZZ Employer')
    returning id into v_employer;
    insert into public.job_leads (employer_id, title, status)
    values (v_employer, 'ZZ Position', 'Open')
    returning id into v_lead;
  end if;

  insert into public.lead_matches (client_id, lead_id, status, created_by)
  values (v_client, v_lead, 'Interview', v_admin)
  returning id into v_match;

  update public.lead_matches set interview_on = public.practice_today() + 2 where id = v_match;

  select kind, title into v_kind, v_title from public.client_next_up where client_id = v_client;
  if v_kind <> 'Task' or v_title not like 'Interview prep%' then
    failures := failures || format('FAILED: two days before an interview, next is "%s — %s"',
                                   v_kind, v_title);
  else
    raise notice 'ok  the day before an interview, what is next is preparing for it';
  end if;

  -- With the reminders dealt with, the appointment itself is what is left.
  update public.tasks set status = 'Done', done_at = public.practice_today()
   where source_match_id = v_match and status = 'Open';

  select kind into v_kind from public.client_next_up where client_id = v_client;
  if v_kind <> 'Interview' then
    failures := failures || format('FAILED: with the reminders done, next reads as "%s"', v_kind);
  else
    raise notice 'ok  behind the reminders sits the interview, as an appointment';
  end if;

  -- ── a decided job stops asking to be followed up ───────────
  -- This is what 0043 fixed. Answering the reminder "Not selected" used to
  -- move the job along and leave its follow-up date alone, so the task and
  -- the 9am appointment stayed booked for a job that was over.
  update public.lead_matches
     set interview_on = null, follow_up_on = public.practice_today() + 1
   where id = v_match;

  select id into v_task from public.tasks
   where source_match_id = v_match and source_kind = 'Follow-up' and status = 'Open';

  if v_task is null then
    failures := failures || 'FAILED: a follow-up date raised no reminder at all'::text;
  else
    -- answer_reminder asks who is signed in, so somebody has to be.
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims',
                       json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);
    perform public.answer_reminder(v_task, 'Not selected', 'ZZ went to another candidate');
    perform set_config('role', 'postgres', true);
    perform set_config('request.jwt.claims', '', true);

    if exists (
      select 1 from public.client_next_up
       where client_id = v_client and kind in ('Follow-up', 'Interview')
    ) then
      failures := failures || 'FAILED: a job that came to nothing still wants following up'::text;
    else
      raise notice 'ok  answering "Not selected" takes the job off the books entirely';
    end if;

    if exists (
      select 1 from public.calendar_events
       where source_match_id = v_match and source_kind = 'Follow-up'
         and push_state not in ('Not pushed', 'To remove')
    ) then
      failures := failures || 'FAILED: the follow-up appointment is still standing'::text;
    else
      raise notice 'ok  and takes the appointment off the calendar with it';
    end if;
  end if;

  -- ── a finished task stops being next ───────────────────────
  update public.tasks set status = 'Done', done_at = public.practice_today()
   where client_id = v_client and status = 'Open';

  select kind into v_kind from public.client_next_up where client_id = v_client;
  if v_kind <> 'Coaching visit' then
    failures := failures || format('FAILED: with every task done, next reads as "%s"', v_kind);
  else
    raise notice 'ok  a task that is done falls back to the visit behind it';
  end if;

  -- ── quiet is one definition, not two ───────────────────────
  -- The caseload screen and the needs list both call thirty days quiet, and
  -- both read client_last_activity. If that view ever stops covering a client
  -- the two screens disagree in front of somebody.
  select count(*) into v_count from public.clients c
   where not exists (select 1 from public.client_last_activity a where a.client_id = c.id);
  if v_count <> 0 then
    failures := failures || format('FAILED: %s clients have no activity row to measure', v_count);
  else
    raise notice 'ok  every client can be measured for quiet, including the untouched';
  end if;

  if failures = '{}' then
    raise notice '';
    raise notice '--- CASELOAD "WHAT IS NEXT" VERIFIED ---';
  else
    raise notice '';
    raise notice '%  PROBLEM(S):', array_length(failures, 1);
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
