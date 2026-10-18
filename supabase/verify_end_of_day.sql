-- Zion Vocational Rehab CRM — the end of the day (0211, 0212)
--
-- What has to hold:
--
--   One day per person per day.
--
--   What was unfinished carries. In-Progress and Pending come forward to the
--   next day; Complete does not, because a thing that is done is done.
--
--   Submitting locks it. A line cannot be added, changed or removed on a day
--   that has been submitted.
--
--   A line about a client lands on that client's record, once - and still
--   once after the day is reopened and submitted again, which is the way a
--   client's history would otherwise fill up with the same sentence.
--
--   Reopening is the same day only, needs a reason, and is written down.
--
--   Admin and the manager are told. The person themselves is not, because
--   they are the one who just did it.
--
--   And who may read a day: their own, Admin's everybody's, a manager their
--   own people's, and nobody else's - which is the half worth testing hardest,
--   because a day is a person writing about their work.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_client  uuid;
  v_person  uuid;
  v_p_uid   uuid := gen_random_uuid();
  v_boss    uuid;
  v_b_uid   uuid := gen_random_uuid();
  v_other   uuid;
  v_o_uid   uuid := gen_random_uuid();
  v_admin   uuid;
  v_a_uid   uuid;
  v_day1    uuid;
  v_day2    uuid;
  v_line    uuid;
  v_again   uuid;
  v_n       integer;
  v_text    text;
  r         record;
  failures  text[] := '{}';
begin
  select id, user_id into v_admin, v_a_uid from public.staff
   where role = 'Admin' and active and user_id is not null order by created_at limit 1;

  insert into public.staff (name, email, role, active)
  values ('ZZ Day Boss', 'zz-day-boss@example.test', 'Job Search', true) returning id into v_boss;
  insert into public.staff (name, email, role, active, manager_id)
  values ('ZZ Day Person', 'zz-day-person@example.test', 'Job Search', true, v_boss) returning id into v_person;
  insert into public.staff (name, email, role, active)
  values ('ZZ Day Stranger', 'zz-day-stranger@example.test', 'Job Search', true) returning id into v_other;

  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_p_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-day-person@example.test', '{}', '{}', now(), now()),
         (v_b_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-day-boss@example.test', '{}', '{}', now(), now()),
         (v_o_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-day-stranger@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_p_uid where id = v_person;
  update public.staff set user_id = v_b_uid where id = v_boss;
  update public.staff set user_id = v_o_uid where id = v_other;

  insert into public.clients (name, stage, status) values ('ZZ Day Client', 'Placement', 'Active')
  returning id into v_client;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_p_uid, 'role', 'authenticated')::text, true);

  -- ── yesterday ─────────────────────────────────────────────
  select public.open_staff_day(public.practice_today() - 1) into v_day1;

  select public.open_staff_day(public.practice_today() - 1) into v_again;
  if v_again is distinct from v_day1 then
    failures := failures || 'FAILED: opening the same day twice made two days'::text;
  else
    raise notice 'ok  one day per person per day';
  end if;

  insert into public.staff_day_lines (day_id, status, description, sort_order)
  values (v_day1, 'Complete', 'ZZ rang the counselor', 1),
         (v_day1, 'In-Progress', 'ZZ writing the progress report', 2),
         (v_day1, 'Pending', 'ZZ chase the signed intake', 3);

  insert into public.staff_day_lines (day_id, status, description, client_id, notes, sort_order)
  values (v_day1, 'Complete', 'ZZ job club with the client', v_client, 'ZZ went well', 4)
  returning id into v_line;

  perform public.submit_staff_day(v_day1);

  -- ── the client line landed on the client ──────────────────
  select count(*) into v_n from public.contact_log
   where client_id = v_client and method = 'End of day report';
  if v_n <> 1 then
    failures := failures || format('FAILED: the client has %s end-of-day entries, not 1', v_n)::text;
  else
    raise notice 'ok  a line about a client lands on that client''s record';
  end if;

  select topic into v_text from public.contact_log
   where client_id = v_client and method = 'End of day report';
  if v_text <> 'ZZ job club with the client' then
    failures := failures || format('FAILED: the contact log says "%s"', v_text)::text;
  end if;

  -- ── and the day is locked ─────────────────────────────────
  begin
    insert into public.staff_day_lines (day_id, status, description, sort_order)
    values (v_day1, 'Complete', 'ZZ one more thing', 9);
    failures := failures || 'FAILED: a line was added to a submitted day'::text;
  exception when check_violation then
    raise notice 'ok  a submitted day takes no more lines';
  end;

  begin
    update public.staff_day_lines set description = 'ZZ changed' where id = v_line;
    failures := failures || 'FAILED: a line on a submitted day was changed'::text;
  exception when check_violation then
    raise notice 'ok  and none of its lines can be changed';
  end;

  -- ── reopening ─────────────────────────────────────────────
  begin
    perform public.reopen_staff_day(v_day1, 'ZZ got it wrong');
    failures := failures || 'FAILED: yesterday was reopened; only the same day may be'::text;
  exception when check_violation then
    raise notice 'ok  a day that is not today cannot be reopened';
  end;

  -- ── today, with yesterday's unfinished work on it ─────────
  select public.open_staff_day(null) into v_day2;

  select count(*) into v_n from public.staff_day_lines where day_id = v_day2;
  if v_n <> 2 then
    failures := failures || format('FAILED: %s lines carried forward, not the 2 unfinished ones', v_n)::text;
  else
    raise notice 'ok  what was In-Progress or Pending carries forward';
  end if;

  select count(*) into v_n from public.staff_day_lines
   where day_id = v_day2 and status = 'Complete';
  if v_n <> 0 then
    failures := failures || 'FAILED: a completed line carried forward; it is done'::text;
  else
    raise notice 'ok  and what was Complete does not';
  end if;

  select count(*) into v_n from public.staff_day_lines
   where day_id = v_day2 and carried_from is not null;
  if v_n <> 2 then
    failures := failures || 'FAILED: a carried line does not say where it came from'::text;
  else
    raise notice 'ok  and says which line it continues';
  end if;

  -- ── reopening today, and submitting again ─────────────────
  perform public.submit_staff_day(v_day2);
  perform public.reopen_staff_day(v_day2, 'ZZ forgot the bottlenecks');

  if (select submitted_at from public.staff_days where id = v_day2) is not null then
    failures := failures || 'FAILED: reopening did not unlock the day'::text;
  else
    raise notice 'ok  today can be reopened, and unlocks';
  end if;

  begin
    perform public.reopen_staff_day(v_day2, '   ');
    failures := failures || 'FAILED: a day was reopened with no reason'::text;
  exception when check_violation then
    raise notice 'ok  and reopening without a reason is refused';
  end;

  update public.staff_days set bottlenecks = 'ZZ the printer' where id = v_day2;
  perform public.submit_staff_day(v_day2);

  select count(*) into v_n from public.staff_day_events where day_id = v_day2;
  if v_n < 3 then
    failures := failures || format('FAILED: the day has %s events; submit, reopen and submit is 3', v_n)::text;
  else
    raise notice 'ok  every submit and reopen is written down';
  end if;

  -- ── the client's history is not written twice ─────────────
  select count(*) into v_n from public.contact_log
   where client_id = v_client and method = 'End of day report';
  if v_n <> 1 then
    failures := failures || format('FAILED: after a reopen and a second submit the client has %s entries', v_n)::text;
  else
    raise notice 'ok  and submitting twice does not write the client''s history twice';
  end if;

  perform set_config('role', 'postgres', true);

  -- ── who was told ──────────────────────────────────────────
  select count(*) into v_n from public.notifications
   where dedupe_key = 'staff_day:' || v_day2::text || ':admin' and 'Admin' = any(roles);
  if v_n <> 1 then
    failures := failures || 'FAILED: Admin was not told the day was submitted'::text;
  else
    raise notice 'ok  Admin is told';
  end if;

  select count(*) into v_n from public.notifications
   where dedupe_key = 'staff_day:' || v_day2::text || ':manager' and staff_id = v_boss;
  if v_n <> 1 then
    failures := failures || 'FAILED: the manager was not told the day was submitted'::text;
  else
    raise notice 'ok  and so is their manager, by name';
  end if;

  select count(*) into v_n from public.notifications
   where kind = 'staff_day' and staff_id = v_person;
  if v_n > 0 then
    failures := failures || 'FAILED: the person was told about their own day'::text;
  else
    raise notice 'ok  and the person who wrote it is not told about it';
  end if;

  -- ── who may read a day ────────────────────────────────────
  perform set_config('role', 'authenticated', true);

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_o_uid, 'role', 'authenticated')::text, true);
  select count(*) into v_n from public.staff_days where staff_id = v_person;
  if v_n > 0 then
    failures := failures || 'FAILED: a colleague can read somebody else''s day'::text;
  else
    raise notice 'ok  a colleague cannot read somebody else''s day';
  end if;

  select count(*) into v_n from public.staff_day_lines where day_id = v_day2;
  if v_n > 0 then
    failures := failures || 'FAILED: a colleague can read the lines of somebody else''s day'::text;
  else
    raise notice 'ok  nor its lines';
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_b_uid, 'role', 'authenticated')::text, true);
  select count(*) into v_n from public.staff_days where staff_id = v_person;
  if v_n < 2 then
    failures := failures || 'FAILED: a manager cannot read the days of somebody who reports to them'::text;
  else
    raise notice 'ok  a manager reads the days of their own people';
  end if;

  if v_a_uid is not null then
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_a_uid, 'role', 'authenticated')::text, true);
    select count(*) into v_n from public.staff_days where staff_id = v_person;
    if v_n < 2 then
      failures := failures || 'FAILED: Admin cannot read everybody''s days'::text;
    else
      raise notice 'ok  and Admin reads everybody''s';
    end if;
  end if;

  -- ── and a day is submitted by the person whose day it is ──
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_o_uid, 'role', 'authenticated')::text, true);
  begin
    perform public.submit_staff_day(v_day1);
    failures := failures || 'FAILED: somebody else submitted a day that was not theirs'::text;
  exception when insufficient_privilege or no_data_found or check_violation then
    raise notice 'ok  and nobody submits a day that is not theirs';
  end;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('role', 'postgres', true);


  /*
   * And the real staff list, not a fixture.
   *
   * Every person who has a manager, their manager can read their days. A
   * fixture proves the rule is written; this proves it is in force for the
   * people it was set for - which is the half that would be quietly wrong if
   * day_is_mine_to_see ever stopped matching how manager_id is set.
   */
  for r in
    select p.id as person, p.name as person_name,
           m.user_id as boss_uid, m.name as boss_name
      from public.staff p
      join public.staff m on m.id = p.manager_id
     where p.active and m.active and m.user_id is not null
  loop
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims',
      json_build_object('sub', r.boss_uid, 'role', 'authenticated')::text, true);

    if not public.day_is_mine_to_see(r.person) then
      failures := failures || format('FAILED: %s manages %s and cannot see their days',
        r.boss_name, r.person_name)::text;
    else
      raise notice 'ok  % manages % and can read their days', r.boss_name, r.person_name;
    end if;

    perform set_config('request.jwt.claims', '', true);
    perform set_config('role', 'postgres', true);
  end loop;

  -- ── anon cannot touch any of it ───────────────────────────
  if has_function_privilege('anon', 'public.open_staff_day(date)', 'execute')
     or has_function_privilege('anon', 'public.submit_staff_day(uuid)', 'execute')
     or has_function_privilege('anon', 'public.reopen_staff_day(uuid, text)', 'execute')
     or has_function_privilege('anon', 'public.file_emailed_day(uuid, date, uuid)', 'execute') then
    failures := failures || 'FAILED: anon may call the day functions'::text;
  else
    raise notice 'ok  anon cannot open, submit, reopen or file a day';
  end if;

  -- The transition function is the cron's alone: it writes a day belonging to
  -- somebody else, which nothing a signed-in person does is allowed to do.
  if has_function_privilege('authenticated', 'public.file_emailed_day(uuid, date, uuid)', 'execute') then
    failures := failures || 'FAILED: a signed-in person may file a day against somebody else'::text;
  else
    raise notice 'ok  and only the sending run files an emailed day';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- END OF DAY VERIFIED ---';
end $$;

rollback;
