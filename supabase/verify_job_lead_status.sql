-- Where a job application got to (0270)
--
-- What has to hold:
--
--   The nine statuses are exactly the nine the owner listed, and the old
--   eight-word vocabulary is not quietly accepted alongside them.
--
--   Whoever may record a job search update may say where an application got
--   to, and so may the staff member the client is assigned to even when their
--   role is not one of the five. Nobody else can, and everybody on the staff
--   can read it.
--
--   An entry says who reported it. A person cannot add one in somebody else's
--   name, and cannot pass one off as automatic.
--
--   Nothing changes or deletes an entry, and nothing empties the table -
--   including a caller the grants do not stop, which is most of what writes to
--   this database.
--
--   The application's status is the latest entry said in the eight words the
--   rest of the system knows, and a back-dated entry does not move it
--   backwards.
--
--   "No response" lands on an application that has sat at Applied for a
--   fortnight, says nothing twice, and stops once anything later is recorded.
--
--   The history follows the application through a merge, because the client is
--   reached through it rather than copied onto it.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_admin uuid; v_admin_uid uuid := gen_random_uuid();
  v_biller uuid; v_biller_uid uuid := gen_random_uuid();
  v_other uuid; v_other_uid uuid := gen_random_uuid();
  v_mine uuid; v_theirs uuid; v_into uuid;
  v_employer uuid; v_lead uuid; v_second_lead uuid; v_third_lead uuid;
  v_match uuid; v_other_match uuid; v_spare uuid; v_fresh uuid;
  v_row uuid; v_word text; v_n integer; v_notes integer;
  failures text[] := '{}';
begin
  -- ── the people ─────────────────────────────────────────────
  insert into public.staff (name, email, role, active)
  values ('ZZ Status Admin', 'zz-status-admin@example.test', 'Admin', true) returning id into v_admin;
  -- Billing is the one active role outside can_record_job_search, which is
  -- what makes it the right fixture for "and assigned staff".
  insert into public.staff (name, email, role, active)
  values ('ZZ Status Biller', 'zz-status-biller@example.test', 'Billing', true) returning id into v_biller;
  insert into public.staff (name, email, role, active)
  values ('ZZ Status Stranger', 'zz-status-stranger@example.test', 'Billing', true) returning id into v_other;

  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_admin_uid,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-status-admin@example.test',    '{}', '{}', now(), now()),
         (v_biller_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-status-biller@example.test',   '{}', '{}', now(), now()),
         (v_other_uid,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-status-stranger@example.test', '{}', '{}', now(), now());

  -- ── the client, the job, and the application ───────────────
  insert into public.clients (name, stage, status, assigned_staff_id)
  values ('ZZ Status Client', 'Job Search', 'Active', v_biller) returning id into v_mine;
  insert into public.clients (name, stage, status, assigned_staff_id)
  values ('ZZ Status Other Client', 'Job Search', 'Active', v_admin) returning id into v_theirs;
  insert into public.clients (name, stage, status)
  values ('ZZ Status Merge Target', 'Job Search', 'Active') returning id into v_into;

  insert into public.employers (name, created_by) values ('ZZ Status Employer', v_admin)
  returning id into v_employer;
  insert into public.job_leads (employer_id, title, created_by)
  values (v_employer, 'ZZ Status Position', v_admin) returning id into v_lead;
  -- A second job, because lead_matches is unique on (lead_id, client_id): two
  -- clients applying for the same job collide when one is merged into the
  -- other, and 0268 resolves that by keeping the kept record''s row. Testing
  -- the merge on one job would have tested that instead of this.
  insert into public.job_leads (employer_id, title, created_by)
  values (v_employer, 'ZZ Status Second Position', v_admin) returning id into v_second_lead;
  insert into public.job_leads (employer_id, title, created_by)
  values (v_employer, 'ZZ Status Third Position', v_admin) returning id into v_third_lead;

  insert into public.lead_matches (lead_id, client_id, status, created_by)
  values (v_lead, v_mine, 'Saved', v_admin) returning id into v_match;
  insert into public.lead_matches (lead_id, client_id, status, created_by)
  values (v_lead, v_theirs, 'Saved', v_admin) returning id into v_other_match;

  -- ── the nine are the nine ──────────────────────────────────
  select count(*) into v_n
    from (values ('Applied'), ('Employer responded'), ('Interview scheduled'), ('Interviewed'),
                 ('Offer'), ('Hired'), ('Declined by employer'), ('Client withdrew'), ('No response')) w(s)
   where public.lead_status_for_application(w.s) is null;
  if v_n > 0 then
    failures := failures || format('FAILED: %s of the nine statuses have no word in lead_matches.status', v_n);
  else
    raise notice 'ok  all nine statuses map onto the vocabulary the rest of the system reads';
  end if;

  -- The old eight-word vocabulary belongs to lead_matches.status and is not a
  -- second way of saying the same thing here.
  begin
    insert into public.job_status_history (match_id, status) values (v_match, 'Not selected');
    failures := failures || 'FAILED: an eight-word status was accepted as an application status'::text;
  exception when check_violation then
    raise notice 'ok  the old vocabulary is refused rather than kept alongside the new';
  end;
  begin
    insert into public.job_status_history (match_id, status) values (v_match, 'Saved');
    failures := failures || 'FAILED: "Saved" was accepted as an application status, and a saved job is not an application'::text;
  exception when check_violation then null;
  end;

  -- ── who may say so ─────────────────────────────────────────
  perform set_config('role', 'authenticated', true);

  -- A Billing person with no claim on this client: refused.
  perform set_config('request.jwt.claims', json_build_object('sub', v_other_uid, 'role', 'authenticated')::text, true);
  begin
    insert into public.job_status_history (match_id, status, reported_by, reported_by_name)
    values (v_match, 'Applied', v_other, 'ZZ Status Stranger');
    failures := failures || 'FAILED: somebody with no part in this client recorded where their application got to'::text;
  exception when insufficient_privilege then null;
  end;

  -- The same role, on the client they are assigned to: accepted. This is the
  -- clause that would be missing if the policy only asked can_record_job_search.
  perform set_config('request.jwt.claims', json_build_object('sub', v_biller_uid, 'role', 'authenticated')::text, true);
  begin
    insert into public.job_status_history (match_id, status, at, reported_by, reported_by_name)
    values (v_match, 'Applied', public.practice_today() - 20, v_biller, 'ZZ Status Biller')
    returning id into v_row;
    raise notice 'ok  the staff member a client is assigned to can say where their application got to';
  exception when insufficient_privilege then
    failures := failures || 'FAILED: the assigned staff member could not record a status on their own client'::text;
  end;

  -- And not on somebody else's client, which is what makes the clause a rule
  -- rather than a hole.
  begin
    insert into public.job_status_history (match_id, status, reported_by, reported_by_name)
    values (v_other_match, 'Applied', v_biller, 'ZZ Status Biller');
    failures := failures || 'FAILED: the assigned clause let somebody write on a client they are not assigned to'::text;
  exception when insufficient_privilege then
    raise notice 'ok  and not on a client they are not assigned to';
  end;

  -- ── an entry says who reported it ──────────────────────────
  begin
    insert into public.job_status_history (match_id, status, reported_by, reported_by_name)
    values (v_match, 'Employer responded', v_admin, 'ZZ Status Admin');
    failures := failures || 'FAILED: a status was recorded in somebody else''s name'::text;
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.job_status_history (match_id, status) values (v_match, 'Employer responded');
    failures := failures || 'FAILED: a status was recorded with nobody''s name against it'::text;
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.job_status_history (match_id, status, reported_by, reported_by_name, automatic)
    values (v_match, 'Employer responded', v_biller, 'ZZ Status Biller', true);
    failures := failures || 'FAILED: a person passed their own entry off as one a rule had written'::text;
  exception when insufficient_privilege then
    raise notice 'ok  an entry names the person who reported it, and a person cannot claim to be a rule';
  end;

  -- ── everybody on the staff reads it ────────────────────────
  perform set_config('request.jwt.claims', json_build_object('sub', v_other_uid, 'role', 'authenticated')::text, true);
  if not exists (select 1 from public.job_status_history where id = v_row) then
    failures := failures || 'FAILED: a member of staff cannot read where an application got to'::text;
  else
    raise notice 'ok  anybody on the staff can read it';
  end if;

  -- ── and loses it when they are no longer staff ─────────────
  perform set_config('role', 'postgres', true);
  update public.staff set active = false where id = v_other;
  perform set_config('role', 'authenticated', true);
  if exists (select 1 from public.job_status_history where id = v_row) then
    failures := failures || 'FAILED: somebody who has left can still read the job search history'::text;
  else
    raise notice 'ok  somebody who has left reads none of it';
  end if;

  -- ── added to, never changed ────────────────────────────────
  perform set_config('request.jwt.claims', json_build_object('sub', v_biller_uid, 'role', 'authenticated')::text, true);
  begin
    update public.job_status_history set status = 'Hired' where id = v_row;
    failures := failures || 'FAILED: a status was edited after the fact'::text;
  exception when insufficient_privilege then null;
  end;
  begin
    delete from public.job_status_history where id = v_row;
    failures := failures || 'FAILED: a status was deleted'::text;
  exception when insufficient_privilege then null;
  end;

  -- The trigger as well as the grant. `authenticated` has no UPDATE here, so
  -- the two above are stopped before they reach the trigger and say nothing
  -- about whether it works. What the trigger is for is the caller the grants
  -- do not stop.
  perform set_config('role', 'postgres', true);
  begin
    update public.job_status_history set status = 'Hired' where id = v_row;
    failures := failures || 'FAILED: a privileged caller edited a status; only the grant stands in the way'::text;
  exception when insufficient_privilege then null;
  end;
  begin
    delete from public.job_status_history where id = v_row;
    failures := failures || 'FAILED: a privileged caller deleted a status'::text;
  exception when insufficient_privilege then null;
  end;
  if (select status from public.job_status_history where id = v_row) <> 'Applied' then
    failures := failures || 'FAILED: the entry no longer says what it said when it was written'::text;
  else
    raise notice 'ok  an entry cannot be changed or removed, by a person or by anything privileged';
  end if;

  -- ── and the table cannot be emptied ────────────────────────
  if has_table_privilege('authenticated', 'public.job_status_history', 'TRUNCATE') then
    failures := failures || 'FAILED: anybody signed in can empty the job search history in one statement'::text;
  elsif has_table_privilege('authenticated', 'public.job_status_history', 'UPDATE')
     or has_table_privilege('authenticated', 'public.job_status_history', 'DELETE') then
    failures := failures || 'FAILED: the history is granted UPDATE or DELETE, so only a trigger stands in the way'::text;
  elsif has_table_privilege('anon', 'public.job_status_history', 'SELECT') then
    failures := failures || 'FAILED: somebody not signed in can read the job search history'::text;
  elsif has_table_privilege('anon', 'public.client_application_status', 'SELECT')
     or has_table_privilege('authenticated', 'public.client_application_status', 'INSERT') then
    failures := failures || 'FAILED: the view of it arrived writable, or readable by somebody not signed in'::text;
  else
    raise notice 'ok  the history cannot be emptied, and the grants do not lean on the trigger to say so';
  end if;

  -- ── the latest entry is the application''s status ──────────
  select status into v_word from public.lead_matches where id = v_match;
  if v_word <> 'Applied' then
    failures := failures || format('FAILED: the application reads "%s" after an Applied entry', v_word);
  elsif (select applied_on from public.lead_matches where id = v_match) is null then
    failures := failures || 'FAILED: an Applied entry left the application with no date to chase'::text;
  else
    raise notice 'ok  the latest entry is the application status, in the words the rest of the system reads';
  end if;

  insert into public.job_status_history (match_id, status, at, note, automatic)
  values (v_match, 'Interview scheduled', public.practice_today() - 2, 'ZZ booked', true);
  if (select status from public.lead_matches where id = v_match) <> 'Interview' then
    failures := failures || 'FAILED: an interview entry did not move the application on'::text;
  else
    raise notice 'ok  a later entry moves the application on';
  end if;

  -- ── and a back-dated one does not move it backwards ───────
  -- Somebody recording on Thursday that the employer rang on Monday, after
  -- Tuesday''s interview is already on file. The entry belongs in the history
  -- and the application is still at interview.
  insert into public.job_status_history (match_id, status, at, note, automatic)
  values (v_match, 'Employer responded', public.practice_today() - 6, 'ZZ they rang', true);
  if (select status from public.lead_matches where id = v_match) <> 'Interview' then
    failures := failures || 'FAILED: a back-dated entry moved the application backwards'::text;
  elsif not exists (select 1 from public.job_status_history
                     where match_id = v_match and status = 'Employer responded') then
    failures := failures || 'FAILED: a back-dated entry was not kept'::text;
  else
    raise notice 'ok  a back-dated entry is kept and does not move the application backwards';
  end if;

  -- ── nothing heard for a fortnight ──────────────────────────
  -- A second application, left at Applied twenty days ago and nothing since.
  insert into public.lead_matches (lead_id, client_id, status, created_by)
  values (v_second_lead, v_into, 'Saved', v_admin) returning id into v_spare;
  insert into public.job_status_history (match_id, status, at, automatic)
  values (v_spare, 'Applied', public.practice_today() - 20, true);

  -- And one applied for yesterday, which the fortnight has not passed on.
  -- The condition that leaves it alone is the whole rule: without this, a
  -- sweep that marked every application ever would pass the script.
  insert into public.lead_matches (lead_id, client_id, status, created_by)
  values (v_third_lead, v_into, 'Saved', v_admin) returning id into v_fresh;
  insert into public.job_status_history (match_id, status, at, automatic)
  values (v_fresh, 'Applied', public.practice_today() - 1, true);

  select count(*) into v_notes from public.notes where client_id = v_into;
  v_n := public.mark_applications_with_no_reply(14);
  if not exists (select 1 from public.job_status_history
                  where match_id = v_spare and status = 'No response') then
    failures := failures || 'FAILED: an application left at Applied for twenty days was not marked No response'::text;
  elsif (select status from public.lead_matches where id = v_spare) <> 'Applied' then
    failures := failures || 'FAILED: No response changed what the application says it is, and nothing happened'::text;
  elsif (select count(*) from public.notes where client_id = v_into) <> v_notes then
    failures := failures || 'FAILED: No response wrote a contact note about nothing happening'::text;
  else
    raise notice 'ok  nothing heard for a fortnight is recorded, quietly, and changes nothing else';
  end if;

  if exists (select 1 from public.job_status_history
              where match_id = v_fresh and status = 'No response') then
    failures := failures || 'FAILED: an application applied for yesterday was marked No response'::text;
  else
    raise notice 'ok  and leaves alone an application nobody has waited a fortnight for';
  end if;

  if public.mark_applications_with_no_reply(14) <> 0 then
    failures := failures || 'FAILED: the sweep said No response twice about the same silence'::text;
  else
    raise notice 'ok  and says it once';
  end if;

  -- Overridable: the next status is recorded, and the sweep never comes back.
  insert into public.job_status_history (match_id, status, at, automatic)
  values (v_spare, 'Employer responded', public.practice_today(), true);
  if public.mark_applications_with_no_reply(14) <> 0 then
    failures := failures || 'FAILED: No response came back after somebody recorded a reply'::text;
  elsif (select status from public.lead_matches where id = v_spare) <> 'Follow-up' then
    failures := failures || 'FAILED: a reply recorded after No response did not move the application on'::text;
  else
    raise notice 'ok  recording a reply overrides it, and it does not come back';
  end if;

  -- The sweep refuses a silence it has not been given a length for, rather
  -- than picking one.
  begin
    perform public.mark_applications_with_no_reply(0);
    failures := failures || 'FAILED: the sweep accepted a silence of no days'::text;
  exception when others then null;
  end;

  -- ── removing a job takes its history with it ──────────────
  -- The client's Job Search tab has offered "Remove this job" since 0013. An
  -- append-only trigger with no exception for the cascade turns that button
  -- into a sentence about a record, which is what the first run of this script
  -- found. The notes the application wrote stay on the client either way.
  perform set_config('role', 'postgres', true);
  insert into public.lead_matches (lead_id, client_id, status, created_by)
  values (v_second_lead, v_theirs, 'Saved', v_admin) returning id into v_row;
  insert into public.job_status_history (match_id, status, automatic)
  values (v_row, 'Applied', true);
  begin
    delete from public.lead_matches where id = v_row;
    if exists (select 1 from public.job_status_history where match_id = v_row) then
      failures := failures || 'FAILED: the history of a removed application was left behind'::text;
    else
      raise notice 'ok  removing a job that should not have been added takes its history with it';
    end if;
  exception when insufficient_privilege then
    failures := failures || 'FAILED: a job could not be removed, because its history refused to go'::text;
  end;

  -- And that exception is for the cascade only: an entry whose application is
  -- still there cannot be deleted by anybody.
  begin
    delete from public.job_status_history where match_id = v_match;
    failures := failures || 'FAILED: the cascade exception let an entry be deleted on its own'::text;
  exception when insufficient_privilege then
    raise notice 'ok  and an entry whose application is still there cannot be';
  end;

  -- ── it follows the application through a merge ────────────
  select count(*) into v_n from public.job_status_history where match_id = v_match;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin_uid, 'role', 'authenticated')::text, true);
  perform public.merge_clients(v_mine, v_into);
  perform set_config('role', 'postgres', true);

  if (select count(*) from public.job_status_history where match_id = v_match) <> v_n then
    failures := failures || 'FAILED: merging the client lost some of the application history'::text;
  elsif (select client_id from public.lead_matches where id = v_match) <> v_into then
    failures := failures || 'FAILED: the application did not move to the kept record'::text;
  elsif not exists (select 1 from public.client_application_status
                     where match_id = v_match and client_id = v_into) then
    failures := failures || 'FAILED: the history still reads against the record that was merged away'::text;
  else
    raise notice 'ok  the history moves with the application when two records are merged';
  end if;

  -- ── one latest per application, and only one ───────────────
  if (select count(*) from public.client_application_status
       where match_id = v_match and latest) <> 1 then
    failures := failures || 'FAILED: an application has no single latest status'::text;
  else
    raise notice 'ok  every application has exactly one latest status';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- APPLICATION STATUSES VERIFIED ---';
end $$;

rollback;
