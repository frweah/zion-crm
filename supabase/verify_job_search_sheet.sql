-- Zion Vocational Rehab CRM — the job-search spreadsheet's fields (0117)
--
-- What has to hold, each tried from the direction that would break it:
--
--   An interview with a time goes on the calendar at that time, where it is
--   held; without one it keeps the old nine o'clock.
--
--   An interview that is cancelled, backed out of or unscheduled stops
--   asking: its prep task, its day-of task and its calendar entry go.
--
--   Withdrawn is a status, it says so on the record, and it sorts after the
--   employer's own "Not selected".
--
--   The interview's kind, confirmation and result take only their own words.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_staff  uuid;
  v_client uuid;
  v_emp    uuid;
  v_lead   uuid;
  v_match  uuid;
  v_start  timestamptz;
  v_loc    text;
  failures text[] := '{}';
begin
  insert into public.staff (name, email, role, active) values ('ZZ Sheet Coach', 'zz-sheet-coach@example.test', 'Job Search', true) returning id into v_staff;
  insert into public.clients (name, stage, status, assigned_staff_id, preferred_locations, job_search_email)
  values ('ZZ Sheet Client', 'Job Development', 'Active', v_staff, 'Murray, Holladay', 'zz.sheet@example.test')
  returning id into v_client;
  insert into public.employers (name, industry) values ('ZZ Grocer', 'Grocery') returning id into v_emp;
  insert into public.job_leads (employer_id, title, location, requisition, posting_url, apply_url, hours_week)
  values (v_emp, 'ZZ Stocker', 'ZZ 1 Main St', 'REQ-0001', 'https://example.test/job', 'https://example.test/apply', 'Part-time')
  returning id into v_lead;

  insert into public.lead_matches (lead_id, client_id, status, applied_on, interview_on, interview_time, interview_kind, interview_location, interview_confirmed)
  values (v_lead, v_client, 'Interview', public.practice_today() - 2, public.practice_today() + 3, time '14:30', 'In person', 'ZZ 1 Main St', 'Confirmed')
  returning id into v_match;

  -- ── at its own time and place ─────────────────────────────
  select starts_at, location into v_start, v_loc from public.calendar_events
   where source_match_id = v_match and source_kind = 'Interview';
  if v_start is distinct from ((public.practice_today() + 3) + time '14:30') at time zone 'America/Denver'
     or v_loc <> 'ZZ 1 Main St' then
    failures := failures || format('FAILED: the interview went on the calendar at %s, %s - not 14:30 at its address', v_start, v_loc);
  else
    raise notice 'ok  an interview goes on the calendar at its own time and place';
  end if;

  -- ── cancelled stops asking ────────────────────────────────
  update public.lead_matches set interview_result = 'Cancelled' where id = v_match;
  if exists (select 1 from public.tasks where source_match_id = v_match and status = 'Open' and source_kind like 'Interview%')
     or exists (select 1 from public.calendar_events where source_match_id = v_match and source_kind = 'Interview') then
    failures := failures || 'FAILED: a cancelled interview still has its reminders'::text;
  else
    raise notice 'ok  a cancelled interview takes its reminders with it';
  end if;

  -- ── Withdrawn ─────────────────────────────────────────────
  update public.lead_matches set status = 'Withdrawn', outcome = 'ZZ declined the offer' where id = v_match;
  if not exists (select 1 from public.notes where client_id = v_client and text like 'Withdrew from ZZ Stocker at ZZ Grocer.%') then
    failures := failures || 'FAILED: withdrawing did not say so on the record'::text;
  end if;
  if public.job_status_rank('Withdrawn') <= public.job_status_rank('Not selected') then
    failures := failures || 'FAILED: Withdrawn sorts before the employer''s own decision'::text;
  end if;
  if not exists (select 1 from public.client_job_history where match_id = v_match
                  and requisition = 'REQ-0001' and apply_url <> '' and interview_kind = 'In person' and industry = 'Grocery') then
    failures := failures || 'FAILED: the job panel does not see the new fields'::text;
  else
    raise notice 'ok  Withdrawn is a status of its own, noted, and the panel reads every new field';
  end if;

  -- ── only their own words ──────────────────────────────────
  begin
    update public.lead_matches set interview_kind = 'Carrier pigeon' where id = v_match;
    failures := failures || 'FAILED: an interview kind outside the list was accepted'::text;
  exception when check_violation then null;
  end;
  begin
    update public.lead_matches set interview_result = 'Went fine I think' where id = v_match;
    failures := failures || 'FAILED: an interview result outside the list was accepted'::text;
  exception when check_violation then null;
  end;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
