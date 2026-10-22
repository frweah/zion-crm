-- Zion Vocational Rehab CRM — the hours used, counted once (0205)
--
-- What has to hold:
--
--   One answer. The screen, the working list and the trigger read the same
--   function, so the hours a form offers are the hours the database allows.
--   The bug this closes: the Billing screen counted each authorization's own
--   entries, which for a coaching parent misses every hour logged on its
--   months, so the form said 0 used while the trigger said 40.
--
--   Counted across the family and including carried_used, which is the rule
--   check_entry_hours has enforced since 0171.
--
--   Non-billable hours are not hours used.
--
--   One call answers for a whole set, and answers for every id asked about -
--   including one with no entries at all, which must come back as 0 rather
--   than not come back.
--
--   p_excluding leaves the named entry out, which is the only reason the
--   trigger can ask about a row it is in the middle of writing.
--
--   And anon cannot call it.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_client  uuid;
  v_staff   uuid;
  v_uid     uuid := gen_random_uuid();
  v_parent  uuid;
  v_month   uuid;
  v_flat    uuid;
  v_entry   uuid;
  v_used    numeric;
  v_n       integer;
  v_text    text;
  failures  text[] := '{}';
begin
  insert into public.staff (name, email, role, active)
  values ('ZZ Hours Admin', 'zz-hours@example.test', 'Admin', true) returning id into v_staff;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-hours@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_uid where id = v_staff;

  insert into public.clients (name, stage, status) values ('ZZ Hours Client', 'Job Placement', 'Active')
  returning id into v_client;

  -- A coaching parent holding the hours, and one month under it (§5).
  insert into public.authorizations (client_id, number, service_type, rate_type, rate,
                                     total_hours, carried_used, start_date, end_date, received_on)
  values (v_client, 'ZZ-H-1', 'Job Coaching', 'Hourly', 45, 20, 3,
          public.practice_today() - 60, public.practice_today() + 60, public.practice_today() - 55)
  returning id into v_parent;

  insert into public.authorizations (client_id, parent_id, service_type, rate_type, rate,
                                     period, start_date, end_date, received_on)
  values (v_client, v_parent, 'Job Coaching', 'Hourly', 45,
          date_trunc('month', public.practice_today())::date,
          public.practice_today() - 10, public.practice_today() + 20, public.practice_today() - 10)
  returning id into v_month;

  -- ── carried_used alone, before any hours ──────────────────
  select used into v_used from public.authorization_hours_used(array[v_parent]) u;
  if coalesce(v_used, -1) <> 3 then
    failures := failures || format('FAILED: with no entries the parent reads %s used, not its carried 3', v_used)::text;
  else
    raise notice 'ok  carried_used is counted before a single hour is logged';
  end if;

  -- ── an hour logged on the month counts against the parent ──
  insert into public.service_entries (auth_id, date, hours, staff_id, notes)
  values (v_month, public.practice_today() - 1, 5, v_staff, 'ZZ month hours')
  returning id into v_entry;

  select used into v_used from public.authorization_hours_used(array[v_parent]) u;
  if coalesce(v_used, -1) <> 8 then
    failures := failures || format('FAILED: 5 hrs on the month and 3 carried reads %s on the parent, not 8', v_used)::text;
  else
    raise notice 'ok  hours logged on a coaching month count against its parent';
  end if;

  -- The month itself answers with the family total too, because the cap it is
  -- held to is the parent's.
  select used into v_used from public.authorization_hours_used(array[v_month]) u;
  if coalesce(v_used, -1) <> 8 then
    failures := failures || format('FAILED: asked about the month it reads %s, not the family 8', v_used)::text;
  else
    raise notice 'ok  and asking about the month gives the same family total';
  end if;

  -- ── non-billable is not hours used ────────────────────────
  insert into public.service_entries (auth_id, date, hours, staff_id, notes, non_billable)
  values (v_month, public.practice_today() - 1, 4, v_staff, 'ZZ not billable', true);

  select used into v_used from public.authorization_hours_used(array[v_parent]) u;
  if coalesce(v_used, -1) <> 8 then
    failures := failures || format('FAILED: a non-billable entry moved used to %s', v_used)::text;
  else
    raise notice 'ok  non-billable hours are not hours used';
  end if;

  -- ── p_excluding ───────────────────────────────────────────
  select used into v_used from public.authorization_hours_used(array[v_parent], v_entry) u;
  if coalesce(v_used, -1) <> 3 then
    failures := failures || format('FAILED: excluding the only billable entry reads %s, not the carried 3', v_used)::text;
  else
    raise notice 'ok  p_excluding leaves the named entry out';
  end if;

  -- ── a whole set in one call, including an authorization with nothing ──
  insert into public.authorizations (client_id, number, service_type, rate_type, rate,
                                     start_date, end_date, received_on)
  values (v_client, 'ZZ-H-2', 'Job Placement', 'Flat Fee', 1200,
          public.practice_today() - 30, public.practice_today() + 30, public.practice_today() - 30)
  returning id into v_flat;

  select count(*) into v_n from public.authorization_hours_used(array[v_parent, v_month, v_flat]) u;
  if v_n <> 3 then
    failures := failures || format('FAILED: asked about 3 authorizations, got %s rows back', v_n)::text;
  else
    raise notice 'ok  one call answers for every authorization asked about';
  end if;

  select used into v_used from public.authorization_hours_used(array[v_flat]) u;
  if coalesce(v_used, -1) <> 0 then
    failures := failures || format('FAILED: an authorization with no entries reads %s, not 0', v_used)::text;
  else
    raise notice 'ok  and one with no hours at all comes back as 0, not missing';
  end if;

  -- ── the trigger refuses using the same number ─────────────
  -- 20 authorized, 8 used. 13 more is one too many.
  begin
    insert into public.service_entries (auth_id, date, hours, staff_id, notes)
    values (v_month, public.practice_today() - 1, 13, v_staff, 'ZZ over the cap');
    failures := failures || 'FAILED: 13 hrs went in over a 20-hour authorization already showing 8 used'::text;
  exception when check_violation then
    v_text := SQLERRM;
    -- The figure, as the message formats it: numeric(6,2), so 8.00.
    if position('8.00 used' in v_text) = 0 then
      failures := failures || format('FAILED: the refusal does not quote the 8 hours the counter reports: %s', v_text)::text;
    else
      raise notice 'ok  the trigger refuses, and quotes the same used figure the screen shows';
    end if;
  end;

  -- And one that fits still goes in, so the cap is a cap and not a wall.
  insert into public.service_entries (auth_id, date, hours, staff_id, notes)
  values (v_month, public.practice_today() - 1, 12, v_staff, 'ZZ up to the cap');
  select used into v_used from public.authorization_hours_used(array[v_parent]) u;
  if coalesce(v_used, -1) <> 20 then
    failures := failures || format('FAILED: filling the authorization exactly reads %s, not 20', v_used)::text;
  else
    raise notice 'ok  an entry that fits goes in, and the family reads exactly its 20';
  end if;

  -- ── anon cannot call it ───────────────────────────────────
  if has_function_privilege('anon', 'public.authorization_hours_used(uuid[], uuid)', 'execute') then
    failures := failures || 'FAILED: anon may execute authorization_hours_used'::text;
  else
    raise notice 'ok  anon cannot call it';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
