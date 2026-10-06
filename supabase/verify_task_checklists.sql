-- Zion Vocational Rehab CRM — steps, and the tasks that come round again (0138)
--
-- What has to hold, each tried from the direction that would break it:
--
--   A step cannot have steps of its own, and a step does not repeat - the
--   task it belongs to does.
--
--   Finishing a repeating task opens the next one, dated from the one just
--   finished rather than from today, so being late once does not make every
--   future one late.
--
--   The next one carries the steps, unfinished. A checklist that only works
--   the first time is a checklist nobody trusts.
--
--   A task that does not repeat opens nothing, and one past its last date
--   stops.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_staff uuid;
  v_client uuid;
  v_monthly uuid;
  v_step uuid;
  v_once uuid;
  v_last uuid;
  v_next record;
  v_n integer;
  failures text[] := '{}';
begin
  insert into public.staff (name, email, role, active) values ('ZZ Step Staff', 'zz-step@example.test', 'Job Search', true) returning id into v_staff;
  insert into public.clients (name, stage, status, assigned_staff_id)
  values ('ZZ Step Client', 'Job Coaching', 'Active', v_staff) returning id into v_client;

  insert into public.tasks (client_id, assigned_staff_id, title, due, status, repeat_every, created_by)
  values (v_client, v_staff, 'ZZ monthly report', date '2026-10-15', 'Open', 'month', v_staff)
  returning id into v_monthly;
  insert into public.tasks (client_id, assigned_staff_id, title, due, status, parent_id, created_by)
  values (v_client, v_staff, 'ZZ pull the hours', date '2026-10-15', 'Open', v_monthly, v_staff)
  returning id into v_step;

  -- ── one level of steps, and steps do not repeat ───────────
  begin
    insert into public.tasks (client_id, title, due, status, parent_id, created_by)
    values (v_client, 'ZZ a step of a step', date '2026-10-15', 'Open', v_step, v_staff);
    failures := failures || 'FAILED: a step was given steps of its own'::text;
  exception when check_violation then null;
  end;
  begin
    update public.tasks set repeat_every = 'week' where id = v_step;
    failures := failures || 'FAILED: a step was made to repeat'::text;
  exception when check_violation then
    raise notice 'ok  one level of steps, and a step does not repeat - the task it belongs to does';
  end;

  -- ── finishing it opens the next ───────────────────────────
  update public.tasks set status = 'Done', done_at = public.practice_today() where id = v_monthly;

  select * into v_next from public.tasks
   where title = 'ZZ monthly report' and status = 'Open' and parent_id is null;
  if v_next.id is null then
    failures := failures || 'FAILED: finishing a repeating task opened nothing'::text;
  elsif v_next.due <> date '2026-11-15' then
    failures := failures || format('FAILED: the next one is due %s, and should be 2026-11-15 - dated from the one just finished', v_next.due);
  else
    raise notice 'ok  the next one is dated from the one just finished, not from today';
  end if;

  select count(*) into v_n from public.tasks where parent_id = v_next.id and status = 'Open';
  if v_n <> 1 then
    failures := failures || format('FAILED: the next one carries %s steps, and should carry 1', v_n);
  else
    raise notice 'ok  the next one carries the steps, unfinished';
  end if;

  -- ── one that does not repeat opens nothing ────────────────
  insert into public.tasks (client_id, assigned_staff_id, title, due, status, created_by)
  values (v_client, v_staff, 'ZZ one-off', date '2026-10-20', 'Open', v_staff) returning id into v_once;
  update public.tasks set status = 'Done', done_at = public.practice_today() where id = v_once;
  select count(*) into v_n from public.tasks where title = 'ZZ one-off';
  if v_n <> 1 then
    failures := failures || 'FAILED: a task that does not repeat opened another'::text;
  end if;

  -- ── and one past its last date stops ──────────────────────
  insert into public.tasks (client_id, assigned_staff_id, title, due, status, repeat_every, repeat_until, created_by)
  values (v_client, v_staff, 'ZZ until', date '2026-10-15', 'Open', 'month', date '2026-10-31', v_staff)
  returning id into v_last;
  update public.tasks set status = 'Done', done_at = public.practice_today() where id = v_last;
  select count(*) into v_n from public.tasks where title = 'ZZ until';
  if v_n <> 1 then
    failures := failures || 'FAILED: a repeating task opened one past the date it was told to stop'::text;
  else
    raise notice 'ok  a one-off opens nothing, and a repeat stops when it is told to';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
