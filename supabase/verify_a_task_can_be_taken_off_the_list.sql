-- A task can be taken off the list (0297), against the real database.
--
-- Rollback-wrapped: fixtures built, asserted, and nothing kept. Names are ZZ
-- and ZQ, which is the rule and what verify_zz_no_fixtures enforces.
--
-- What it asks:
--   1. a third status exists and nothing else does
--   2. taking one off records who and when, without being told
--   3. the screen cannot choose who removed it
--   4. a removed task is out of every list that asks for Open
--   5. its checklist steps go with it
--   6. the record survives putting it back
--   7. a removed task cannot be left without a remover
--   8. and a check account still cannot do any of it

begin;

do $$
declare
  v_me       uuid;
  v_other    uuid;
  v_client   uuid;
  v_task     uuid;
  v_step     uuid;
  v_n        integer;
  v_who      uuid;
  v_when     timestamptz;
  failures   text[] := '{}';
begin
  select id into v_me from public.staff where active and not is_system order by created_at limit 1;
  select id into v_other from public.staff where active and not is_system and id <> v_me order by created_at limit 1;
  if v_me is null then
    raise exception 'there is no active colleague, so this script is asking about nothing';
  end if;

  insert into public.clients (name, status, stage)
  values ('ZZ Removal', 'Active', 'Intake')
  returning id into v_client;

  -- current_staff_id() reads the session's staff row, and this session is
  -- postgres. The fixtures below are written as that colleague would.
  perform set_config('request.jwt.claims',
    json_build_object('sub', coalesce((select user_id::text from public.staff where id = v_me), gen_random_uuid()::text))::text,
    true);

  insert into public.tasks (title, client_id, assigned_staff_id, status, created_by, due)
  values ('ZZ a task to take off', v_client, v_me, 'Open', v_me, public.practice_today())
  returning id into v_task;

  insert into public.tasks (title, client_id, assigned_staff_id, status, created_by, parent_id)
  values ('ZZ a step of it', v_client, v_me, 'Open', v_me, v_task)
  returning id into v_step;

  -- ── 1. three statuses, and no fourth ──────────────────────
  begin
    update public.tasks set status = 'Parked' where id = v_task;
    failures := failures || 'FAILED: a task was given a status nobody defined'::text;
  exception when check_violation then
    raise notice 'ok  a task is Open, Done or Removed and nothing else';
  end;

  -- ── 2. taking one off records who and when ────────────────
  --
  -- Two things hold this, and taking the trigger away does not leave a task
  -- removed without a remover - it makes the removal impossible, because the
  -- constraint refuses a Removed row with no stamp. Watched: the script fails
  -- either way, which is what matters, but this case is not the one that
  -- catches a missing trigger.
  update public.tasks set status = 'Removed', removed_reason = 'Raised twice' where id = v_task;
  select removed_by, removed_at into v_who, v_when from public.tasks where id = v_task;
  if v_who is null or v_when is null then
    failures := failures || 'FAILED: a removed task does not say who took it off or when'::text;
  elsif v_who <> v_me then
    failures := failures || 'FAILED: a removed task names somebody other than the person who removed it'::text;
  else
    raise notice 'ok  taking a task off the list records who did it and when, without being asked';
  end if;

  -- ── 3. and the screen cannot choose who ───────────────────
  -- The trigger writes it over whatever arrived, so a browser naming somebody
  -- else is a browser naming itself.
  update public.tasks set status = 'Open' where id = v_task;
  update public.tasks set status = 'Removed', removed_by = v_other where id = v_task;
  select removed_by into v_who from public.tasks where id = v_task;
  if v_who <> v_me then
    failures := failures || 'FAILED: the remover can be chosen by whoever sends the update'::text;
  else
    raise notice 'ok  and who removed it is the person removing it, whatever the update says';
  end if;

  -- ── 4. out of every list that asks for Open ───────────────
  select count(*) into v_n from public.tasks where id = v_task and status = 'Open';
  if v_n > 0 then
    failures := failures || 'FAILED: a removed task is still Open'::text;
  else
    raise notice 'ok  a removed task is not Open, so every list that asks for Open has lost it';
  end if;

  -- ── 5. its steps go with it ───────────────────────────────
  select status into v_n from (select case when status = 'Removed' then 1 else 0 end as status
                                 from public.tasks where id = v_step) s;
  if v_n <> 1 then
    failures := failures || 'FAILED: the checklist steps of a removed task are still on the list'::text;
  else
    raise notice 'ok  its checklist steps come off with it';
  end if;

  -- ── 6. the record survives putting it back ────────────────
  update public.tasks set status = 'Open' where id = v_task;
  select removed_by into v_who from public.tasks where id = v_task;
  if v_who is null then
    failures := failures || 'FAILED: putting a task back erases who took it off'::text;
  else
    raise notice 'ok  putting one back keeps the record of who took it off';
  end if;

  -- ── 7. a removed task cannot have no remover ──────────────
  begin
    update public.tasks set status = 'Removed', removed_at = null, removed_by = null where id = v_task;
    -- The trigger fills them, so this only fails if somebody drops the
    -- trigger and keeps the column.
    select removed_by into v_who from public.tasks where id = v_task;
    if v_who is null then
      failures := failures || 'FAILED: a task is Removed with nobody recorded as removing it'::text;
    else
      raise notice 'ok  a removed task always names a remover';
    end if;
  exception when check_violation then
    raise notice 'ok  a removed task always names a remover';
  end;

  -- ── 8. and a check account still cannot ───────────────────
  declare
    v_bot uuid;
    v_uid uuid := gen_random_uuid();
  begin
    -- The staff row first: link_staff_account refuses a sign-in for an
    -- address nobody is on staff under, and links the two itself.
    insert into public.staff (name, email, role, active, is_system)
    values ('ZQ task robot', 'zq-task@example.test', 'Job Search', true, true)
    returning id into v_bot;
    insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    values (v_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'zq-task@example.test', '{}', '{}', now(), now());

    -- Open again, so "still Open" afterwards is an answer rather than the
    -- state it was already in.
    update public.tasks set status = 'Open' where id = v_task;

    perform set_config('request.jwt.claims', json_build_object('sub', v_uid::text)::text, true);
    perform set_config('role', 'authenticated', true);
    begin
      update public.tasks set status = 'Removed', removed_reason = 'by a robot' where id = v_task;
    exception when others then
      null;  -- refused by a policy is one of the two right answers
    end;
    perform set_config('role', 'postgres', true);

    -- Asked of the row rather than of the error. A refusal that raises and a
    -- refusal that matches no row both leave the task alone, and leaving the
    -- task alone is the rule; an error on its own could be anything.
    perform 1 from public.tasks where id = v_task and status = 'Open';
    if not found then
      failures := failures || 'FAILED: a check account took a task off the list'::text;
    else
      raise notice 'ok  a check account changes nothing, whichever way it is refused';
    end if;
  end;

  if array_length(failures, 1) > 0 then
    raise exception using errcode = 'ZZ001',
      message = format('%s case(s) failed: %s', array_length(failures, 1), array_to_string(failures, ' | '));
  end if;

  raise notice '--- A TASK CAN BE TAKEN OFF THE LIST: VERIFIED ---';
end $$;

rollback;
