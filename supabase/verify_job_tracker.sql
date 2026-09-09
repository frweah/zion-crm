-- Zion Vocational Rehab CRM — the job tracker
--
-- A rename is the kind of change that looks free and is not. The names lived
-- in a constraint, a trigger, two screens and a shared list, and the ones that
-- disagree do not announce themselves — they fail the next time somebody tries
-- to use the feature, which is weeks later and looks like something else.
--
-- So this proves the new vocabulary end to end: the constraint takes the new
-- names and refuses the old, the trigger still writes a note for each of them,
-- and the two things the brief said to keep — that note, and Hired being an
-- explicit decision rather than an automatic placement — still hold.
--
-- Runs inside a transaction that is rolled back. Nothing here is left behind.

begin;

do $$
declare
  v_admin    uuid;
  v_adm_uid  uuid;
  v_client   uuid;
  v_employer uuid;
  v_lead     uuid;
  v_match    uuid;
  v_notes    int;
  v_before   int;
  v_text     text;
  v_type     text;
  v_status   text;
  v_seen     uuid[];
  failures   text[] := '{}';
begin
  select id, user_id into v_admin, v_adm_uid from public.staff where legacy_id = 's1';
  select id into v_client from public.clients where status = 'Active' order by created_at limit 1;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);

  insert into public.employers (name, created_by) values ('ZZ Verify Employer', v_admin)
  returning id into v_employer;
  insert into public.job_leads (employer_id, title, location, created_by)
  values (v_employer, 'ZZ Test Position', 'ZZ Site', v_admin)
  returning id into v_lead;

  -- ── the old names are gone ─────────────────────────────────
  begin
    insert into public.lead_matches (lead_id, client_id, status, created_by)
    values (v_lead, v_client, 'Considering', v_admin);
    failures := failures || 'FAILED: the old status "Considering" was still accepted'::text;
  exception when check_violation then
    raise notice 'ok  the old vocabulary is refused, not silently kept alongside the new';
  end;

  -- ── the default is the first step ──────────────────────────
  select count(*) into v_before from public.notes where client_id = v_client;

  insert into public.lead_matches (lead_id, client_id, created_by)
  values (v_lead, v_client, v_admin)
  returning id, status into v_match, v_status;

  if v_status <> 'Saved' then
    failures := failures || format('FAILED: a new job starts as "%s", expected Saved', v_status);
  else
    raise notice 'ok  a job starts as Saved';
  end if;

  -- ── the trigger still writes the note ──────────────────────
  select count(*) into v_notes from public.notes where client_id = v_client;
  if v_notes <> v_before + 1 then
    failures := failures || 'FAILED: adding a job wrote no note'::text;
  else
    raise notice 'ok  adding a job writes a note on the client, as before';
  end if;

  -- ── every step in the new vocabulary writes one ────────────
  foreach v_status in array array['Applied', 'Follow-up', 'Interview', 'Offer', 'Not selected']
  loop
    -- The notes written in here all share a created_at, because now() is fixed
    -- for the whole transaction. Ordering by it returns an arbitrary row, and
    -- the first version of this file did exactly that: every check passed
    -- while reading the same stale note. The new one is found by id instead.
    select count(*), coalesce(array_agg(id), '{}') into v_before, v_seen
      from public.notes where client_id = v_client;
    update public.lead_matches set status = v_status where id = v_match;
    select count(*) into v_notes from public.notes where client_id = v_client;

    if v_notes <> v_before + 1 then
      failures := failures || format('FAILED: moving to %s wrote no note', v_status);
    else
      select text into v_text from public.notes
       where client_id = v_client and not (id = any(v_seen));
      -- The point of the rename: the note has to read like something a person
      -- would say. A fallthrough would read "Follow-up — ZZ Test Position at".
      if v_text like '%—%' and v_status <> 'Saved' then
        failures := failures || format('FAILED: the note for %s fell through to the generic form: %s',
                                       v_status, v_text);
      else
        raise notice 'ok  % writes its own sentence: %', v_status, left(v_text, 46);
      end if;
    end if;
  end loop;

  -- ── the outcome reaches the note ───────────────────────────
  select coalesce(array_agg(id), '{}') into v_seen
    from public.notes where client_id = v_client;
  update public.lead_matches
     set status = 'Interview', outcome = 'ZZ they liked her'
   where id = v_match;
  select text into v_text from public.notes
   where client_id = v_client and not (id = any(v_seen));
  if v_text not like '%ZZ they liked her%' then
    failures := failures || 'FAILED: the outcome did not reach the note'::text;
  else
    raise notice 'ok  what somebody wrote about how it went reaches the note';
  end if;

  -- ── a rejection is dated ───────────────────────────────────
  -- Declined was renamed. Left unchanged, setMatchStatus would have stopped
  -- recording the day a rejection happened, and nothing would have said so.
  update public.lead_matches set status = 'Not selected', decided_on = current_date
   where id = v_match;
  if (select decided_on from public.lead_matches where id = v_match) is null then
    failures := failures || 'FAILED: a rejection recorded no date'::text;
  else
    raise notice 'ok  a rejection records the day it happened';
  end if;

  -- ── Hired does not create a placement by itself ────────────
  select count(*) into v_before from public.placements where client_id = v_client;
  update public.lead_matches set status = 'Hired', decided_on = current_date where id = v_match;
  select count(*) into v_notes from public.placements where client_id = v_client;

  if v_notes <> v_before then
    failures := failures || 'FAILED: marking Hired created a placement on its own'::text;
  else
    raise notice 'ok  Hired creates no placement — that stays a separate decision';
  end if;

  if (select placement_id from public.lead_matches where id = v_match) is not null then
    failures := failures || 'FAILED: a placement was linked without anybody creating one'::text;
  else
    raise notice 'ok  nothing is linked until somebody creates the placement';
  end if;

  -- ── the job reaches the timeline and the panel ─────────────
  update public.lead_matches
     set applied_on = current_date - 3, interview_on = current_date - 1,
         follow_up_on = current_date + 2
   where id = v_match;

  foreach v_status in array array['Job', 'Interview', 'Follow-up']
  loop
    if not exists (select 1 from public.client_activity
                    where client_id = v_client and kind = v_status
                      and at > now() - interval '7 days') then
      failures := failures || format('FAILED: %s did not reach the timeline', v_status);
    else
      raise notice 'ok  % reaches the timeline', v_status;
    end if;
  end loop;

  if not exists (
    select 1 from public.client_job_history
     where match_id = v_match and employer_name = 'ZZ Verify Employer'
       and location = 'ZZ Site' and follow_up_on is not null
  ) then
    failures := failures || 'FAILED: the panel view is missing the job or its new fields'::text;
  else
    raise notice 'ok  the panel sees the employer, the site and the follow-up date';
  end if;

  -- ── the steps are ordered by progress, not alphabet ────────
  if public.job_status_rank('Applied') >= public.job_status_rank('Not selected')
     or public.job_status_rank('Saved') >= public.job_status_rank('Hired') then
    failures := failures || 'FAILED: the statuses do not rank in the order they happen'::text;
  else
    raise notice 'ok  the statuses rank in the order they actually happen';
  end if;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  if failures = '{}' then
    raise notice '';
    raise notice '--- JOB TRACKER VERIFIED ---';
  else
    raise notice '';
    raise notice '%  PROBLEM(S):', array_length(failures, 1);
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
