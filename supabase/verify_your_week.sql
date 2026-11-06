-- Zion Vocational Rehab CRM — what the Friday email counts (0316)
--
-- Item G of the owner's list. The words are checked before every build by
-- scripts/check-week-report.mjs, over made-up figures; this is the other
-- half - that the figures are the right ones.
--
-- What has to hold:
--
--   One row per active member of staff who is a person and has an address. A
--   check account gets no week, which is the rule 0120 set and the one the
--   Monday run learnt the hard way.
--
--   A week is Monday to the day it is sent, not the last seven days.
--
--   Every figure is that person's own. Hours somebody else logged, notes
--   somebody else wrote and tasks on somebody else's list are not in their
--   row, and the week before is not in it either.
--
--   Non-billable hours are not billable hours. A voided session is not time
--   worked. A removed task is neither open nor finished.
--
--   What is waiting is what is waiting now; what is ahead is the seven days
--   after the day it is sent, and not the day itself.
--
--   And nobody signed out can ask.
--
-- Runs inside a transaction that is rolled back. Nothing here is left behind.

begin;

do $$
declare
  v_doer    uuid;
  v_other   uuid;
  v_bot     uuid;
  v_gone    uuid;
  v_quiet   uuid;
  v_client  uuid;
  v_silent  uuid;
  v_auth    uuid;
  v_task    uuid;
  v_friday  date := date '2026-11-06';
  r         record;
  w         record;
  failures  text[] := '{}';
begin
  insert into public.staff (name, email, role, active)
  values ('ZZ Week Doer', 'zz-week-doer@example.test', 'Job Search', true) returning id into v_doer;
  insert into public.staff (name, email, role, active)
  values ('ZZ Week Other', 'zz-week-other@example.test', 'Job Search', true) returning id into v_other;
  insert into public.staff (name, email, role, active, is_system)
  values ('ZZ Week Robot', 'zz-week-robot@example.test', 'Reports', true, true) returning id into v_bot;
  insert into public.staff (name, email, role, active)
  values ('ZZ Week Leaver', 'zz-week-leaver@example.test', 'Job Search', false) returning id into v_gone;
  insert into public.staff (name, email, role, active)
  values ('ZZ Week Unreachable', '', 'Job Search', true) returning id into v_quiet;

  insert into public.clients (name, stage, status, assigned_staff_id, phone)
  values ('ZZ Week Client', 'Job Coaching', 'Active', v_doer, '(801) 555-0170') returning id into v_client;
  -- Somebody else's client, to prove the count is per person.
  insert into public.clients (name, stage, status, assigned_staff_id, phone)
  values ('ZZ Week Bystander', 'Job Coaching', 'Active', v_other, '(801) 555-0171');
  -- And one of theirs with nothing on the record at all, which is the
  -- quietest a client can be.
  insert into public.clients (name, stage, status, assigned_staff_id, phone)
  values ('ZZ Week Silence', 'Job Coaching', 'Active', v_doer, '(801) 555-0172') returning id into v_silent;
  -- Creating a client writes a stage-history row, and that row is activity -
  -- so a client made a minute ago has been active a minute ago, which is
  -- true and is not what this case is about. Taken away, so this client has
  -- nothing on the record at all: the last-activity function then answers
  -- nothing rather than a date, and "nothing" has to count as quiet. An
  -- imported client nobody ever touched is exactly that row.
  delete from public.client_stage_history where client_id = v_silent;

  insert into public.authorizations
    (client_id, number, service_type, rate_type, rate, total_hours, status, start_date, end_date)
  values (v_client, 'ZQ-WK-1', 'WSA Tier 2', 'Hourly', 45, 40, 'Due',
          date '2026-10-01', date '2026-12-31') returning id into v_auth;

  -- ── the week's work: three hours billable, one not ─────────
  insert into public.service_entries (auth_id, date, hours, notes, staff_id)
  values (v_auth, date '2026-11-03', 3.00, 'ZQ this week', v_doer);
  insert into public.service_entries (auth_id, date, hours, notes, staff_id, non_billable)
  values (v_auth, date '2026-11-04', 2.00, 'ZQ this week, not billable', v_doer, true);
  -- Last week, and somebody else's.
  insert into public.service_entries (auth_id, date, hours, notes, staff_id)
  values (v_auth, date '2026-10-30', 5.00, 'ZQ last week', v_doer);
  insert into public.service_entries (auth_id, date, hours, notes, staff_id)
  values (v_auth, date '2026-11-03', 7.00, 'ZQ somebody else', v_other);

  -- ── time on the clock: eight hours, one session voided ────
  insert into public.work_sessions (staff_id, worked_on, hours, description, created_by)
  values (v_doer, date '2026-11-02', 8.00, 'ZQ Monday', v_doer);
  insert into public.work_sessions (staff_id, worked_on, hours, description, created_by, voided)
  values (v_doer, date '2026-11-03', 6.00, 'ZQ voided', v_doer, true);
  insert into public.work_sessions (staff_id, worked_on, hours, description, created_by)
  values (v_doer, date '2026-10-28', 9.00, 'ZQ last week', v_doer);

  -- ── notes and calls ──────────────────────────────────────
  insert into public.notes (client_id, staff_id, staff_name, text, type, at)
  values (v_client, v_doer, 'ZZ Week Doer', 'ZQ a note this week', 'Call', date '2026-11-05'),
         (v_client, v_doer, 'ZZ Week Doer', 'ZQ a note last week', 'Call', date '2026-10-29'),
         (v_client, v_other, 'ZZ Week Other', 'ZQ somebody else''s note', 'Call', date '2026-11-05');
  insert into public.contact_log (client_id, date, method, topic, outcome, staff_id)
  values (v_client, date '2026-11-04', 'Call', 'ZQ topic', 'ZQ outcome', v_doer),
         (v_client, date '2026-10-27', 'Call', 'ZQ last week', 'ZQ outcome', v_doer);

  -- ── tasks: one finished, two open, one of them late, one gone ──
  insert into public.tasks (title, client_id, assigned_staff_id, due, status, done_at, created_by)
  values ('ZQ finished this week', v_client, v_doer, date '2026-11-03', 'Done', date '2026-11-03', v_doer);
  insert into public.tasks (title, client_id, assigned_staff_id, due, status, created_by)
  values ('ZQ open and late', v_client, v_doer, date '2026-10-20', 'Open', v_doer) returning id into v_task;
  insert into public.tasks (title, client_id, assigned_staff_id, due, status, created_by)
  values ('ZQ open and not late', v_client, v_doer, date '2026-11-20', 'Open', v_doer);
  insert into public.tasks (title, client_id, assigned_staff_id, due, status, removed_at, removed_by, created_by)
  values ('ZQ taken off the list', v_client, v_doer, date '2026-10-21', 'Removed',
          now(), v_doer, v_doer);

  -- ── next week's diary, and this week's, which is not it ───
  insert into public.calendar_events (client_id, staff_id, kind, title, starts_at, ends_at, created_by)
  values (v_client, v_doer, 'Coaching visit', 'ZQ next Tuesday',
          timestamptz '2026-11-10 17:00+00', timestamptz '2026-11-10 18:00+00', v_doer),
         (v_client, v_doer, 'Coaching visit', 'ZQ the Friday itself',
          timestamptz '2026-11-06 17:00+00', timestamptz '2026-11-06 18:00+00', v_doer),
         (v_client, v_doer, 'Coaching visit', 'ZQ a fortnight out',
          timestamptz '2026-11-20 17:00+00', timestamptz '2026-11-20 18:00+00', v_doer);

  -- ── who gets one ─────────────────────────────────────────
  if exists (select 1 from public.staff_week(v_friday) k where k.staff_id = v_bot) then
    failures := failures || 'FAILED: a check account is sent a week of its own'::text;
  elsif exists (select 1 from public.staff_week(v_friday) k where k.staff_id = v_gone) then
    failures := failures || 'FAILED: somebody who has left is sent a week'::text;
  elsif exists (select 1 from public.staff_week(v_friday) k where k.staff_id = v_quiet) then
    failures := failures || 'FAILED: somebody with no address is in the list with nowhere to send it'::text;
  elsif not exists (select 1 from public.staff_week(v_friday) k where k.staff_id = v_doer) then
    failures := failures || 'FAILED: an active member of staff is sent no week'::text;
  else
    raise notice 'ok  every active person with an address gets a week, and nobody else does';
  end if;

  select * into w from public.staff_week(v_friday) k where k.staff_id = v_doer;

  -- ── the week it is about ─────────────────────────────────
  if w.week_start <> date '2026-11-02' or w.week_end <> v_friday then
    failures := failures || format('FAILED: the week runs %s to %s rather than Monday to the day it is sent',
                                   w.week_start, w.week_end)::text;
  else
    raise notice 'ok  a week is Monday to the day it is sent';
  end if;

  -- ── the hours ────────────────────────────────────────────
  if w.billable_hours <> 3.00 then
    failures := failures || format('FAILED: billable hours came to %s, not the 3 logged this week', w.billable_hours)::text;
  elsif w.clocked_hours <> 8.00 then
    failures := failures || format('FAILED: hours on the clock came to %s, not the 8 worked this week', w.clocked_hours)::text;
  else
    raise notice 'ok  billable hours leave out the non-billable, and the clock leaves out a voided session';
  end if;

  -- ── and everything else is theirs and this week's ────────
  if w.notes_written <> 1 or w.contacts_logged <> 1 then
    failures := failures || format('FAILED: %s note(s) and %s call(s) where one of each was this person''s, this week',
                                   w.notes_written, w.contacts_logged)::text;
  elsif w.tasks_done <> 1 then
    failures := failures || format('FAILED: %s task(s) finished where one was', w.tasks_done)::text;
  elsif w.tasks_open <> 2 then
    failures := failures || format('FAILED: %s task(s) open where two are, and the removed one is not', w.tasks_open)::text;
  elsif w.tasks_overdue <> 1 then
    failures := failures || format('FAILED: %s task(s) past their date where one is', w.tasks_overdue)::text;
  else
    raise notice 'ok  every figure is this person''s own, and this week''s';
  end if;

  -- ── the three the Friday email is for ────────────────────
  -- Counted for this person: an item in their inbox, a client of theirs with
  -- nothing on the record for a fortnight, and a report they owe.
  perform set_config('role', 'service_role', true);
  perform set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
  perform public.to_file_offer(v_doer, 'Calendar', 'ZQ-WEEK-EVENT', 'ZQ something to file',
                               '', timestamptz '2026-11-04 17:00+00', v_client, 'named');
  perform public.to_file_offer(v_other, 'Calendar', 'ZQ-OTHER-EVENT', 'ZQ somebody else''s',
                               '', timestamptz '2026-11-04 17:00+00', v_client, 'named');
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  insert into public.client_reports (client_id, period, owner_id, status, due_on, template)
  values (v_client, date '2026-10-01', v_doer, 'Draft', date '2026-11-05', 'Monthly client report'),
         (v_client, date '2026-09-01', v_doer, 'Draft', date '2026-11-30', 'Monthly client report');

  select * into w from public.staff_week(v_friday) k where k.staff_id = v_doer;

  if w.to_file_waiting <> 1 then
    failures := failures || format('FAILED: %s thing(s) to file where one is theirs', w.to_file_waiting)::text;
  elsif w.reports_due <> 2 then
    failures := failures || format('FAILED: %s report(s) to finish where two are', w.reports_due)::text;
  elsif w.reports_overdue <> 1 then
    failures := failures || format('FAILED: %s report(s) past their date where one is', w.reports_overdue)::text;
  else
    raise notice 'ok  the three the email is for are counted, and only this person''s';
  end if;

  -- One of their two clients was seen this week and the other has nothing on
  -- the record at all. A client with no activity whatever is the quietest
  -- there is, and counting the null is what says so - the obvious comparison
  -- leaves them out, which is the wrong way round.
  if w.quiet_clients <> 1 then
    failures := failures || format('FAILED: %s quiet client(s) where one has nothing on the record and one was seen this week',
                                   w.quiet_clients)::text;
  elsif w.clients_carried <> 2 then
    failures := failures || format('FAILED: %s client(s) carried where two are theirs', w.clients_carried)::text;
  else
    raise notice 'ok  a client with nothing on the record is quiet, and one seen this week is not';
  end if;

  -- ── the week ahead ───────────────────────────────────────
  if w.appointments <> 1 then
    failures := failures || format('FAILED: %s appointment(s) ahead, where one is in the next seven days', w.appointments)::text;
  else
    raise notice 'ok  the diary ahead is the seven days after it is sent, and not the day itself';
  end if;

  -- ── and nobody signed out can ask ────────────────────────
  if has_function_privilege('anon', 'public.staff_week(date)', 'execute')
     or has_function_privilege('authenticated', 'public.staff_week(date)', 'execute') then
    failures := failures || 'FAILED: somebody signed in or signed out can read everybody''s week'::text;
  else
    raise notice 'ok  the week is the sweep''s to read, not a signed-in person''s';
  end if;

  if array_length(failures, 1) > 0 then
    raise notice '';
    raise notice '%  PROBLEM(S):', array_length(failures, 1);
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '';
  raise notice '--- THE WEEK IS COUNTED AS IT SHOULD BE ---';
end $$;

rollback;
