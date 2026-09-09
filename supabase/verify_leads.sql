-- Zion Vocational Rehab CRM — job leads verification
--
-- The reason A2 exists is that job-search effort should be typed once and then
-- appear wherever it is needed: USOR 96 autofill, the client activity report,
-- the KPIs. That only holds if matching a client to a lead really does write a
-- note of the right type. This proves it.
--
-- Runs inside a transaction that is rolled back.

begin;

do $$
declare
  v_client   uuid;
  v_employer uuid;
  v_lead     uuid;
  v_match    uuid;
  n_notes    int;
  v_type     text;
  v_text     text;
  failures   text[] := '{}';
  last_month text := to_char((date_trunc('month', current_date) - interval '1 day'), 'YYYY-MM');
begin
  insert into public.clients (name) values ('ZZ Leads Client') returning id into v_client;

  insert into public.employers (name, industry, relationship_status)
  values ('ZZ Test Grocers', 'Retail', 'Active partner') returning id into v_employer;

  insert into public.job_leads (employer_id, title, wage_range, status)
  values (v_employer, 'Stock Assistant', '$15-16/hr', 'Open') returning id into v_lead;

  -- 1. Creating a match writes a note.
  insert into public.lead_matches (lead_id, client_id, status)
  values (v_lead, v_client, 'Saved') returning id into v_match;

  select count(*) into n_notes from public.notes where client_id = v_client;
  if n_notes <> 1 then
    failures := failures || format('creating a match wrote %s notes, expected 1', n_notes);
  end if;

  select type, text into v_type, v_text from public.notes where client_id = v_client;
  raise notice 'Saved -> [%] %', v_type, v_text;
  if v_type <> 'Job search' then
    failures := failures || format('Saved should be typed "Job search", got "%s"', v_type);
  end if;

  -- 2. Each step writes its own note, with the type USOR 96 reads.
  --
  -- Checked by existence, not by "the most recent row": inside one transaction
  -- now() does not advance, so every note here shares a timestamp and ordering
  -- by it proves nothing. That mistake made a working trigger look broken.
  update public.lead_matches set status = 'Applied' where id = v_match;
  if not exists (select 1 from public.notes
                  where client_id = v_client and type = 'Application submitted'
                    and text like 'Applied for%') then
    failures := failures || 'Applied did not write an "Application submitted" note'::text;
  end if;

  update public.lead_matches set status = 'Interview' where id = v_match;
  if not exists (select 1 from public.notes
                  where client_id = v_client and type = 'Interview'
                    and text like 'Interview for%') then
    failures := failures || 'Interview did not write an "Interview" note'::text;
  end if;

  update public.lead_matches set status = 'Hired' where id = v_match;
  if not exists (select 1 from public.notes
                  where client_id = v_client and type = 'Employer contact'
                    and text like 'Hired for%') then
    failures := failures || 'Hired did not write an "Employer contact" note'::text;
  end if;

  select count(*) into n_notes from public.notes where client_id = v_client;
  if n_notes <> 4 then
    failures := failures || format('expected 4 notes across the four steps, found %s', n_notes);
  end if;

  for v_type, v_text in
    select type, text from public.notes where client_id = v_client order by type
  loop
    raise notice '  [%] %', v_type, left(v_text, 60);
  end loop;

  -- 3. Touching the row without changing status must not write another note,
  --    or editing a typo would litter the client record.
  select count(*) into n_notes from public.notes where client_id = v_client;
  update public.lead_matches set notes = 'edited a typo' where id = v_match;
  if (select count(*) from public.notes where client_id = v_client) <> n_notes then
    failures := failures || 'editing a match without changing status wrote a spurious note'::text;
  end if;
  raise notice 'editing without a status change wrote no note';

  -- 4. The types written are the ones USOR 96 autofill actually looks for.
  if not exists (
    select 1 from public.notes
     where client_id = v_client
       and type in ('Job search', 'Application submitted', 'Interview', 'Employer contact')
  ) then
    failures := failures || 'no note carries a type USOR 96 autofill reads'::text;
  end if;

  -- 5. And the per-client history view reflects it.
  if (select count(*) from public.client_job_history where client_id = v_client) <> 1 then
    failures := failures || 'client_job_history does not show the match'::text;
  end if;

  if array_length(failures, 1) is not null then
    raise exception E'LEAD FAILURES:\n  %', array_to_string(failures, E'\n  ');
  end if;

  raise notice '--- JOB LEADS VERIFIED ---';
end $$;

-- ─────────────────────────────────────────────────────────────
-- Who may work the board
--
-- Job Search and Admin edit; Intake & Reports and Billing can see it and not
-- touch it. Read access is easy to get right by accident; write access is what
-- needs proving.
-- ─────────────────────────────────────────────────────────────
do $$
declare
  v_employer uuid;
  r          record;
  can_write  boolean;
  can_read   boolean;
  failures   text[] := '{}';
begin
  insert into public.employers (name) values ('ZZ Perms Employer') returning id into v_employer;

  for r in
    select s.role, s.name, u.id as uid
      from public.staff s join auth.users u on u.id = s.user_id
     where s.active and u.email is not null
     order by s.role
  loop
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims',
                       json_build_object('sub', r.uid, 'role', 'authenticated')::text, true);

    select count(*) > 0 into can_read from public.employers where name = 'ZZ Perms Employer';

    begin
      insert into public.job_leads (employer_id, title) values (v_employer, 'ZZ perms probe');
      can_write := true;
      delete from public.job_leads where title = 'ZZ perms probe';
    exception when insufficient_privilege or others then
      can_write := false;
    end;

    perform set_config('role', 'postgres', true);
    perform set_config('request.jwt.claims', '', true);

    raise notice '  % (%): read=% write=%', r.name, r.role, can_read, can_write;

    if not can_read then
      failures := failures || format('%s cannot see the board', r.role);
    end if;

    if r.role in ('Admin', 'Job Search') then
      if not can_write then failures := failures || format('%s should be able to add an opening', r.role); end if;
    else
      if can_write then failures := failures || format('LEAK: %s can add an opening', r.role); end if;
    end if;
  end loop;

  if array_length(failures, 1) is not null then
    raise exception E'LEAD PERMISSION FAILURES:\n  %', array_to_string(failures, E'\n  ');
  end if;

  raise notice '--- LEAD PERMISSIONS VERIFIED ---';
end $$;

rollback;
