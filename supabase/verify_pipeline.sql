-- Zion Vocational Rehab CRM — the referral pipeline
--
-- Two things this has to get right, because both are quoted at people.
--
-- "Days waiting" must count from the last time somebody entered the stage they
-- are in — not from the first time they touched it, and not from when the
-- record was made. Somebody who went out to Intake and came back to Referral
-- has been waiting since they came back, not since the day they arrived.
--
-- "Ever reached" must credit the stages behind the one somebody is standing
-- in. The workbook migration left every client with a single stage row, so a
-- funnel built on history alone would say nobody has ever converted.
--
-- Runs inside a transaction that is rolled back. Nothing here is left behind.

begin;

do $$
declare
  v_admin  uuid;
  v_client uuid;
  v_days   int;
  v_since  timestamptz;
  v_count  int;
  failures text[] := '{}';
begin
  select id into v_admin from public.staff where role = 'Admin' and active order by created_at limit 1;

  insert into public.clients (name, stage, status, created_at)
  values ('ZZ Pipeline Test', 'Referral', 'Active', now() - interval '200 days')
  returning id into v_client;

  -- ── with no stage record, waiting counts from the record ───
  delete from public.client_stage_history where client_id = v_client;

  select days_in_stage into v_days from public.client_pipeline where client_id = v_client;
  if v_days < 199 or v_days > 201 then
    failures := failures || format('FAILED: with no stage record, 200 days reads as %s', v_days);
  else
    raise notice 'ok  with no stage record, waiting counts from when the client arrived';
  end if;

  -- ── entering a stage restarts the clock ────────────────────
  insert into public.client_stage_history (client_id, stage, at, staff_id)
  values (v_client, 'Referral', now() - interval '90 days', v_admin);

  select days_in_stage into v_days from public.client_pipeline where client_id = v_client;
  if v_days < 89 or v_days > 91 then
    failures := failures || format('FAILED: entering Referral 90 days ago reads as %s days', v_days);
  else
    raise notice 'ok  waiting counts from entering the stage, not from arriving';
  end if;

  -- ── out and back again ─────────────────────────────────────
  insert into public.client_stage_history (client_id, stage, at, staff_id)
  values (v_client, 'Intake', now() - interval '60 days', v_admin),
         (v_client, 'Referral', now() - interval '10 days', v_admin);

  select days_in_stage, stage_since into v_days, v_since
    from public.client_pipeline where client_id = v_client;
  if v_days < 9 or v_days > 11 then
    failures := failures || format('FAILED: back at Referral 10 days ago reads as %s days', v_days);
  else
    raise notice 'ok  going out and coming back restarts the wait — the latest entry wins';
  end if;

  -- ── what counts as reached ─────────────────────────────────
  select count(*) into v_count from public.client_stages_reached
   where client_id = v_client and stage = 'Intake';
  if v_count <> 1 then
    failures := failures || 'FAILED: a stage in the history does not count as reached'::text;
  else
    raise notice 'ok  a stage in the history counts as reached, even after moving back';
  end if;

  select count(*) into v_count from public.client_stages_reached
   where client_id = v_client and stage = 'Placement';
  if v_count <> 0 then
    failures := failures || 'FAILED: a stage nobody reached is counted as reached'::text;
  else
    raise notice 'ok  a stage never touched is not counted';
  end if;

  -- Standing further along credits everything behind, whatever the workbook
  -- remembered.
  update public.clients set stage = 'Job Coaching' where id = v_client;
  select count(*) into v_count from public.client_stages_reached
   where client_id = v_client
     and stage in ('Referral', 'Intake', 'Assessment', 'Job Development', 'Placement', 'Job Coaching');
  if v_count <> 6 then
    failures := failures || format('FAILED: a client at Job Coaching is credited with %s of 6 stages', v_count);
  else
    raise notice 'ok  standing at Job Coaching credits every stage behind it';
  end if;

  select count(*) into v_count from public.client_stages_reached
   where client_id = v_client and stage = 'Follow-Along';
  if v_count <> 0 then
    failures := failures || 'FAILED: a stage ahead of the client is counted as reached'::text;
  else
    raise notice 'ok  and credits nothing ahead of them';
  end if;

  -- Closed carries no position, so a closed client is credited only with what
  -- the history actually holds — which is the honest answer for the workbook's
  -- twenty closed cases.
  update public.clients set stage = 'Closed', status = 'Closed' where id = v_client;

  select count(distinct sh.stage) into v_count
    from public.client_stage_history sh
   where sh.client_id = v_client
     and public.stage_rank(sh.stage) is not null;

  if (select count(*) from public.client_stages_reached where client_id = v_client) <> v_count then
    failures := failures || format(
      'FAILED: a closed client is credited with %s stages, not the %s their history holds',
      (select count(*) from public.client_stages_reached where client_id = v_client), v_count);
  else
    raise notice 'ok  Closed is not a position, so only the recorded history counts';
  end if;

  -- ── a referral with nothing authorized ─────────────────────
  if not (select no_authorization from public.client_pipeline where client_id = v_client) then
    failures := failures || 'FAILED: a client with no authorization is not flagged as such'::text;
  else
    raise notice 'ok  a client with nothing authorized says so — no service agreed, nothing to bill';
  end if;

  insert into public.authorizations (client_id, number, service_type, total_hours, rate, rate_type, status)
  values (v_client, 'ZZ-PIPE', 'Job Coaching', 10, 45, 'Hourly', 'Open');

  select auth_count into v_count from public.client_pipeline where client_id = v_client;
  if v_count <> 1 or (select no_authorization from public.client_pipeline where client_id = v_client) then
    failures := failures || 'FAILED: an authorization did not clear the flag'::text;
  else
    raise notice 'ok  authorizing something clears it';
  end if;

  -- ── every client appears exactly once ──────────────────────
  -- The screen counts rows. Two rows for one client would double a caseload.
  select count(*) into v_count from public.client_pipeline;
  if v_count <> (select count(*) from public.clients) then
    failures := failures || format('FAILED: %s pipeline rows for %s clients', v_count,
                                   (select count(*) from public.clients));
  else
    raise notice 'ok  one row per client, so nothing is counted twice';
  end if;

  if failures = '{}' then
    raise notice '';
    raise notice '--- REFERRAL PIPELINE VERIFIED ---';
  else
    raise notice '';
    raise notice '%  PROBLEM(S):', array_length(failures, 1);
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
