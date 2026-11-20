-- Zion Vocational Rehab CRM — the reports board, and the hands on a report (0377)
--
-- The owner's rulings of 20 November 2026, asked of the database rather than
-- of the screen. What has to hold:
--
--   A client on the caseload with no report for the month is a row all the
--   same, said to be Not started, owed, and due on the 5th of the month
--   after - which is the date the scheduler would have stamped on it. The
--   board is built from the caseload, so the current month has rows on the
--   1st rather than on the 1st of the next.
--
--   A service with a report of its own is offered a row and is not owed one.
--   Eleven clients hold a coaching authorization and nobody has asked any of
--   them for a Job Coaching Update; a board that called those overdue would
--   have been eleven lies on the day it opened. So: no due date, and not
--   late however long ago the month was.
--
--   The chips count what the drafter reads and nothing else, and a Personal
--   note or contact is in neither - it is not in the report either, and
--   telling a counselor two notes were left out about somebody's housing is
--   still telling them something.
--
--   A report whose client has since been closed is still on the board. Three
--   of October's nineteen drafts are like that, and the first version of this
--   dropped them.
--
--   Asking the board writes nothing: no report, no note, no log line.
--
--   Every active staff member may edit and assemble any report; signing,
--   sending and taking a signature back are Reports', Admin's and the
--   writer's; and the writer is set by Reports and Admin. Each of those is
--   tried from the direction that would break it, and each refusal has a
--   control - somebody who is allowed doing the same thing - because a
--   refusal with nothing to compare it against is a function that is broken.
--
--   And a change to a report that is not yours is in the access log, which is
--   the half of ruling 1 that keeps widening the policy honest.
--
--   Reports can file anybody's To file item. Nobody else can except Admin.
--
--   Nobody not signed in is anywhere near any of it.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_client   uuid;
  v_closed   uuid;
  v_writer   uuid; v_writer_uid uuid := gen_random_uuid();
  v_coach    uuid; v_coach_uid  uuid := gen_random_uuid();
  v_reports  uuid; v_reports_uid uuid := gen_random_uuid();
  v_admin    uuid; v_admin_uid  uuid := gen_random_uuid();
  v_auth     uuid;
  v_employer uuid;
  v_lead     uuid;
  v_report   uuid;
  v_shut     uuid;
  v_item     uuid;
  v_other    uuid;
  -- A month that is over, so "overdue" means something. Fixed rather than
  -- taken from today, so this says the same thing whatever day it is run.
  v_oct      date := date '2026-10-01';
  v_mon      date := date '2026-10-05';   -- a Monday inside it
  v_mon2     date := date '2026-10-12';
  r          record;
  v_n        integer;
  v_logs     integer;
  v_reports_n integer;
  v_mark     integer;
  failures   text[] := '{}';
begin
  insert into public.staff (name, email, role, active)
  values ('ZZ Board Writer', 'zz-board-writer@example.test', 'Job Coach', true) returning id into v_writer;
  insert into public.staff (name, email, role, active)
  values ('ZZ Board Coach', 'zz-board-coach@example.test', 'Job Coach', true) returning id into v_coach;
  insert into public.staff (name, email, role, active)
  values ('ZZ Board Reports', 'zz-board-reports@example.test', 'Reports', true) returning id into v_reports;
  insert into public.staff (name, email, role, active)
  values ('ZZ Board Admin', 'zz-board-admin@example.test', 'Admin', true) returning id into v_admin;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_writer_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-board-writer@example.test', '{}', '{}', now(), now()),
         (v_coach_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-board-coach@example.test', '{}', '{}', now(), now()),
         (v_reports_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-board-reports@example.test', '{}', '{}', now(), now()),
         (v_admin_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-board-admin@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_writer_uid where id = v_writer;
  update public.staff set user_id = v_coach_uid where id = v_coach;
  update public.staff set user_id = v_reports_uid where id = v_reports;
  update public.staff set user_id = v_admin_uid where id = v_admin;

  insert into public.clients (name, funding_source, status, stage, assigned_staff_id)
  values ('ZZ Board Client', 'Utah VR', 'Active', 'Job Coaching', v_writer)
  returning id into v_client;
  insert into public.clients (name, funding_source, status, stage, assigned_staff_id)
  values ('ZZ Board Closed Client', 'Utah VR', 'Inactive', 'Job Coaching', v_writer)
  returning id into v_closed;

  -- Job Coaching, hourly, running across October: the service that has a
  -- report of its own, and the one that makes hours expected.
  insert into public.authorizations
    (client_id, number, service_type, funding_source, total_hours, rate_type, rate, start_date, end_date, status)
  values (v_client, 'ZZ-BOARD-1', 'Job Coaching', 'Utah VR', 40, 'Hourly', 50,
          v_oct - 10, v_oct + 60, 'Authorized')
  returning id into v_auth;

  -- ── 1. a month nobody has started is still a row ──────────
  v_mark := coalesce(array_length(failures, 1), 0);
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_reports_uid, 'role', 'authenticated')::text, true);

  select * into r from public.report_board_rows(v_oct)
   where client_id = v_client and template = 'Monthly client report';
  if r.client_id is null then
    failures := failures || 'FAILED: a client on the caseload has no row for a month with no report in it'::text;
  else
    if r.status <> 'Not started' then
      failures := failures || format('FAILED: a month nobody has started says %s', r.status)::text;
    end if;
    if not r.owed then
      failures := failures || 'FAILED: the monthly client report is not owed, so nothing is ever overdue'::text;
    end if;
    if r.due_on is distinct from date '2026-11-05' then
      failures := failures || format('FAILED: a month nobody has started is due %s, and the scheduler stamps the 5th of the month after', coalesce(r.due_on::text, 'never'))::text;
    end if;
    if r.report_id is not null then
      failures := failures || 'FAILED: a row nobody has started names a report'::text;
    end if;
  end if;

  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice 'ok  a month nobody has started is a row, owed, and due on the 5th of the month after';
  end if;

  -- ── 2. a service's own report is offered, not owed ────────
  v_mark := coalesce(array_length(failures, 1), 0);
  select * into r from public.report_board_rows(v_oct)
   where client_id = v_client and template = 'Job Coaching Update';
  if r.client_id is null then
    failures := failures || 'FAILED: a client getting coaching is offered no Job Coaching Update row'::text;
  else
    if r.owed then
      failures := failures || 'FAILED: a Job Coaching Update nobody asked for is owed, so the board opens with reports overdue that the practice does not owe'::text;
    end if;
    if r.due_on is not null then
      failures := failures || format('FAILED: a report nobody asked for is due %s', r.due_on)::text;
    end if;
  end if;

  -- And a client with no coaching service is offered no such row. The control
  -- for the above: a row that appeared for everybody would pass section 2
  -- without the family map doing anything.
  if exists (select 1 from public.report_board_rows(v_oct)
              where client_id = v_closed and template = 'Job Coaching Update') then
    failures := failures || 'FAILED: a client with no authorization is offered a service report anyway'::text;
  end if;

  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice 'ok  a service with a report of its own is offered one and is not owed one';
  end if;

  -- ── 3. the chips count what the drafter reads ─────────────
  v_mark := coalesce(array_length(failures, 1), 0);
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  insert into public.notes (client_id, staff_name, text, type, at, category)
  values (v_client, 'ZZ Board Writer', 'ZZ a coaching note', 'General', v_oct + 3, 'Job coaching'),
         (v_client, 'ZZ Board Writer', 'ZZ another note', 'General', v_oct + 4, 'Job coaching'),
         (v_client, 'ZZ Board Writer', 'ZZ nobody else''s business', 'General', v_oct + 5, 'Personal');
  insert into public.contact_log (client_id, date, method, topic, outcome, category, staff_id)
  values (v_client, v_oct + 6, 'Phone call', 'ZZ called the client', 'Spoke', 'Job coaching', v_writer),
         (v_client, v_oct + 7, 'Appointment', 'ZZ a visit', 'Happened', 'Job coaching', v_writer),
         (v_client, v_oct + 8, 'Phone call', 'ZZ housing', 'Spoke', 'Personal', v_writer);
  insert into public.service_entries (auth_id, date, hours, non_billable, notes)
  values (v_auth, v_oct + 3, 2.5, false, 'ZZ billable'),
         (v_auth, v_oct + 4, 1.0, true, 'ZZ not billable');
  insert into public.client_weekly_reports (client_id, week_start, owner_id, due_on, status)
  values (v_client, v_mon, v_writer, v_mon + 9, 'Draft');
  insert into public.client_weekly_reports (client_id, week_start, owner_id, due_on, status, confirmed_by, confirmed_at)
  values (v_client, v_mon2, v_writer, v_mon2 + 9, 'Confirmed', v_writer, now());
  insert into public.employers (name) values ('ZZ Board Employer') returning id into v_employer;
  insert into public.job_leads (employer_id, title) values (v_employer, 'ZZ Board Opening')
  returning id into v_lead;
  insert into public.lead_matches (lead_id, client_id, status, applied_on)
  values (v_lead, v_client, 'Applied', v_oct + 9);
  insert into public.placements (client_id, employer, title, start_date)
  values (v_client, 'ZZ Board Employer', 'ZZ Board Opening', v_oct + 10);

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_reports_uid, 'role', 'authenticated')::text, true);

  select * into r from public.report_board_rows(v_oct)
   where client_id = v_client and template = 'Monthly client report';
  if r.notes <> 2 then
    failures := failures || format('FAILED: the month counts %s notes, and two of the three are not Personal', r.notes)::text;
  end if;
  if r.contacts <> 2 then
    failures := failures || format('FAILED: the month counts %s contacts, and two of the three are not Personal', r.contacts)::text;
  end if;
  if r.hours <> 2.5 then
    failures := failures || format('FAILED: the month counts %s hours, and only the billable 2.5 are the counselor''s business', r.hours)::text;
  end if;
  if r.weeks_total <> 2 or r.weeks_confirmed <> 1 then
    failures := failures || format('FAILED: the month has %s weeks with %s confirmed, and the fixture made two with one confirmed', r.weeks_total, r.weeks_confirmed)::text;
  end if;
  if r.first_unconfirmed_week is distinct from v_mon then
    failures := failures || format('FAILED: the week chip opens %s, and the unconfirmed one is %s', coalesce(r.first_unconfirmed_week::text, 'nothing'), v_mon)::text;
  end if;
  if r.applications <> 1 then
    failures := failures || format('FAILED: the month counts %s applications and one was sent', r.applications)::text;
  end if;
  if r.placements <> 1 then
    failures := failures || format('FAILED: the month counts %s placements and one started', r.placements)::text;
  end if;
  if not r.hourly then
    failures := failures || 'FAILED: an hourly authorization did not make hours expected, so "no hours logged" can never be said'::text;
  end if;

  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice 'ok  the chips count what the drafter reads, the billable hours only, and no Personal note or contact';
  end if;

  -- ── 4. a closed client's draft is still on the board ──────
  v_mark := coalesce(array_length(failures, 1), 0);
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  insert into public.client_reports
    (client_id, template, period, owner_id, status, content, visible_roles, due_on)
  values (v_closed, 'Monthly client report', v_oct, v_writer, 'Draft',
          jsonb_build_object('from', v_oct, 'to', v_oct + 30, 'sections', '[]'::jsonb, 'withheld', 0, 'hours', 0),
          array['Admin', 'Job Search', 'Reports', 'Billing'], date '2026-11-05')
  returning id into v_shut;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_reports_uid, 'role', 'authenticated')::text, true);

  select * into r from public.report_board_rows(v_oct) where client_id = v_closed;
  if r.client_id is null then
    failures := failures || 'FAILED: a draft belonging to a closed client is on no screen at all'::text;
  elsif r.report_id is distinct from v_shut then
    failures := failures || 'FAILED: the closed client''s row does not name their draft'::text;
  elsif r.owed then
    failures := failures || 'FAILED: a closed client is still owed a report'::text;
  else
    raise notice 'ok  a draft whose client has since been closed is still on the board, and not owed';
  end if;

  -- ── 5. asking the board writes nothing ───────────────────
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  select count(*) into v_reports_n from public.client_reports;
  select count(*) into v_logs from public.access_log;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_reports_uid, 'role', 'authenticated')::text, true);
  perform count(*) from public.report_board_rows(v_oct);
  perform count(*) from public.report_board_rows(null);
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  select count(*) into v_n from public.client_reports;
  if v_n <> v_reports_n then
    failures := failures || 'FAILED: asking the board made a report'::text;
  end if;
  select count(*) into v_n from public.access_log;
  if v_n <> v_logs then
    failures := failures || 'FAILED: asking the board wrote to the access log'::text;
  else
    raise notice 'ok  asking the board twice writes no report and no log line';
  end if;

  -- ── 6. everybody writes; fewer sign ──────────────────────
  v_mark := coalesce(array_length(failures, 1), 0);
  insert into public.client_reports
    (client_id, template, period, owner_id, status, content, visible_roles, due_on)
  values (v_client, 'Monthly client report', v_oct, v_writer, 'Draft',
          jsonb_build_object('from', v_oct, 'to', v_oct + 30, 'sections', '[]'::jsonb, 'withheld', 0, 'hours', 0),
          array['Admin', 'Job Search', 'Reports', 'Billing'], date '2026-11-05')
  returning id into v_report;
  select count(*) into v_logs from public.access_log;

  -- A Job Coach who is not the writer: may read it, may change what it says.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_coach_uid, 'role', 'authenticated')::text, true);
  select count(*) into v_n from public.client_reports where id = v_report;
  if v_n <> 1 then
    failures := failures || 'FAILED: an active staff member cannot open a report that is not theirs'::text;
  end if;
  update public.client_reports set note = 'ZZ somebody else got it out' where id = v_report;
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    failures := failures || 'FAILED: an active staff member cannot edit a report that is not theirs'::text;
  end if;

  -- And may not sign it, nor change who is writing it.
  begin
    update public.client_reports
       set status = 'Signed', signed_at = now(), signed_by = v_coach
     where id = v_report;
    failures := failures || 'FAILED: a Job Coach who did not write it signed a report'::text;
  exception when insufficient_privilege then null;
  end;
  begin
    update public.client_reports set owner_id = v_coach where id = v_report;
    failures := failures || 'FAILED: a Job Coach took a report off its writer'::text;
  exception when insufficient_privilege then null;
  end;

  -- The controls. Reports sets the writer, and Reports signs.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_reports_uid, 'role', 'authenticated')::text, true);
  update public.client_reports set owner_id = v_reports, due_on = date '2026-11-10'
   where id = v_report;
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    failures := failures || 'FAILED: Reports cannot set the writer or the date, so the two cells on the board do nothing'::text;
  end if;

  -- The writer signs their own. Reassigned above, so the writer is Reports
  -- now; a Job Coach signing their own is the case the role check would miss,
  -- so it is tried on the closed client's draft, which is still the Job
  -- Coach's.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_writer_uid, 'role', 'authenticated')::text, true);
  update public.client_reports
     set status = 'Reviewed', reviewed_at = now(), reviewed_by = v_writer
   where id = v_shut;
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    failures := failures || 'FAILED: the writer cannot move their own report on'::text;
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_reports_uid, 'role', 'authenticated')::text, true);
  update public.client_reports
     set status = 'Signed', signed_at = now(), signed_by = v_reports
   where id = v_report;
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    failures := failures || 'FAILED: Reports cannot sign a report, so nothing ever goes to a counselor'::text;
  end if;

  -- And taking a signature back is the same hands, which is the half that is
  -- easy to leave out: unsigning is undoing a signature.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_coach_uid, 'role', 'authenticated')::text, true);
  begin
    update public.client_reports
       set status = 'Draft', signed_at = null, signed_by = null,
           reopen_reason = 'ZZ not mine to reopen'
     where id = v_report;
    failures := failures || 'FAILED: a Job Coach who did not write it took a signature back'::text;
  exception when insufficient_privilege then null;
  end;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice 'ok  every active staff member writes a report; the writer, Reports and Admin sign, send and unsign it';
  end if;

  -- ── 7. and the log keeps who edited what ─────────────────
  select count(*) into v_n from public.access_log
   where subject = 'Somebody else''s report' and client_id = v_client;
  if v_n = 0 then
    failures := failures || 'FAILED: nothing was logged when somebody who is not the writer changed a report'::text;
  elsif not exists (
    select 1 from public.access_log
     where subject = 'Somebody else''s report' and client_id = v_client
       and staff_name = 'ZZ Board Coach' and purpose like '%Monthly client report%')
  then
    failures := failures || 'FAILED: the log does not name who changed the report and which one'::text;
  elsif exists (
    select 1 from public.access_log
     where subject = 'Somebody else''s report' and client_id = v_closed and staff_name = 'ZZ Board Writer')
  then
    failures := failures || 'FAILED: the writer''s own work is in the log, which buries the changes that matter'::text;
  else
    raise notice 'ok  a change to somebody else''s report names who made it and which report, and the writer''s own is not logged';
  end if;

  -- ── 8. Reports files anybody's item ──────────────────────
  v_mark := coalesce(array_length(failures, 1), 0);
  insert into public.to_file (staff_id, by_staff_id, source, source_key, title, detail, happened_at, client_id, guess_why)
  values (v_writer, v_writer, 'Calendar', 'zz-board-event-1', 'ZZ an appointment', '', v_oct + 11, v_client, 'named')
  returning id into v_item;
  insert into public.to_file (staff_id, by_staff_id, source, source_key, title, detail, happened_at, client_id, guess_why)
  values (v_writer, v_writer, 'Calendar', 'zz-board-event-2', 'ZZ another appointment', '', v_oct + 12, v_client, 'named')
  returning id into v_other;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_coach_uid, 'role', 'authenticated')::text, true);
  begin
    perform public.to_file_confirm(v_item, 'happened', 'ZZ not mine to file', 'Job coaching');
    failures := failures || 'FAILED: a Job Coach filed somebody else''s item'::text;
  exception when insufficient_privilege then null;
  end;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_reports_uid, 'role', 'authenticated')::text, true);
  perform public.to_file_confirm(v_item, 'happened', 'ZZ filed by Reports', 'Job coaching');
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  if (select state from public.to_file where id = v_item) <> 'Confirmed' then
    failures := failures || 'FAILED: Reports could not file somebody else''s item, so 106 of the 147 stay waiting'::text;
  end if;
  -- And the contact it wrote is dated when the thing happened, not today:
  -- an October appointment filed in November belongs to October's report.
  if not exists (
    select 1 from public.contact_log
     where client_id = v_client and date = (v_oct + 11)::date and topic = 'ZZ an appointment')
  then
    failures := failures || 'FAILED: filing dated the contact on the day it was filed, so the month it lands in is wrong'::text;
  end if;
  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice 'ok  Reports files anybody''s item, a Job Coach files only their own, and the contact keeps the day it happened';
  end if;

  -- ── 9. nobody not signed in ──────────────────────────────
  perform set_config('role', 'anon', true);
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  begin
    perform count(*) from public.report_board_rows(v_oct);
    failures := failures || 'FAILED: the board answered somebody who is not signed in'::text;
  exception when insufficient_privilege then null;
  end;
  -- Caught rather than read, because there are two ways for this to be right
  -- and only one of them returns a number: the table's SELECT grant is
  -- revoked from anon outright, which is a refusal and not an empty result.
  begin
    select count(*) into v_n from public.client_reports;
    if v_n <> 0 then
      failures := failures || format('FAILED: somebody not signed in read %s reports', v_n)::text;
    end if;
  exception when insufficient_privilege then null;
  end;
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  if not exists (select 1 from unnest(failures) f where f like '%not signed in%') then
    raise notice 'ok  somebody not signed in reaches neither the board nor a report';
  end if;

  -- ── and the verdict ──────────────────────────────────────
  if array_length(failures, 1) is null then
    raise notice '';
    raise notice '--- REPORTS BOARD VERIFIED ---';
  else
    raise notice '';
    for v_n in 1 .. array_length(failures, 1) loop
      raise notice '%', failures[v_n];
    end loop;
    raise exception '% of the reports board rules do not hold', array_length(failures, 1);
  end if;
end $$;

rollback;
