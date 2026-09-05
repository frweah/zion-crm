-- Zion Vocational Rehab CRM — notification rule verification
--
-- Builds a situation that ought to trip every rule, runs the generator, and
-- checks each one fired. An alert system that quietly produces nothing is
-- worse than not having one, because everybody assumes it is watching.
--
-- Runs inside a transaction that is rolled back.

begin;

do $$
declare
  v_counselor uuid;
  v_client    uuid;
  v_staff     uuid;
  a_exhausted uuid;
  a_low       uuid;
  a_ending    uuid;
  a_flat      uuid;
  a_coaching  uuid;
  last_month  text := to_char((date_trunc('month', current_date) - interval '1 day'), 'YYYY-MM');
  last_day    date := (date_trunc('month', current_date) - interval '1 day')::date;
begin
  select id into v_staff from public.staff where role = 'Job Search' and active limit 1;

  insert into public.counselors (name, email) values ('ZZ Notify Counselor', 'zz@example.test')
    returning id into v_counselor;
  insert into public.clients (name, counselor_id, assigned_staff_id)
    values ('ZZ Notify Client', v_counselor, v_staff)
    returning id into v_client;

  -- 1. no hours left
  insert into public.authorizations
    (client_id, number, service_type, total_hours, carried_used, rate_type, rate, status)
  values (v_client, 'ZZ-EXHAUSTED', 'Job Coaching', 10, 10, 'Hourly', 45, 'Open')
    returning id into a_exhausted;

  -- 2. under 10% remaining
  insert into public.authorizations
    (client_id, number, service_type, total_hours, carried_used, rate_type, rate, status)
  values (v_client, 'ZZ-LOW', 'Job Coaching', 100, 95, 'Hourly', 45, 'Open')
    returning id into a_low;

  -- 3. ending within 14 days
  insert into public.authorizations
    (client_id, number, service_type, total_hours, carried_used, rate_type, rate, status, end_date)
  values (v_client, 'ZZ-ENDING', 'Job Coaching', 50, 0, 'Hourly', 45, 'Open', current_date + 7)
    returning id into a_ending;

  -- 4. invoice sent and long unpaid. "Other" requires no USOR form, so the
  --    billing gate does not block the fixture.
  insert into public.authorizations
    (client_id, number, service_type, rate_type, rate, status)
  values (v_client, 'ZZ-FLAT', 'Other', 'Flat Fee', 500, 'Open')
    returning id into a_flat;
  insert into public.invoices (auth_id, number, date, amount, status)
  values (a_flat, 'ZZ-INV-95', current_date - 95, 500, 'Sent');

  -- 5. overdue task
  insert into public.tasks (client_id, assigned_staff_id, title, due, status)
  values (v_client, v_staff, 'ZZ overdue task', current_date - 3, 'Open');

  -- 6. monthly USOR reports, with activity last month to report on
  insert into public.authorizations
    (client_id, number, service_type, total_hours, carried_used, rate_type, rate, status)
  values (v_client, 'ZZ-COACH', 'Job Coaching', 40, 0, 'Hourly', 45, 'Open')
    returning id into a_coaching;
  insert into public.notes (client_id, text, type, at, visible_roles)
  values (v_client, 'ZZ activity last month', 'Job search', last_day,
          array['Admin','Job Search','Reports','Billing']);

  -- 7. counselor follow-up now due
  insert into public.contact_log (counselor_id, client_id, date, method, topic, follow_up, staff_id)
  values (v_counselor, v_client, current_date - 10, 'Phone call',
          'ZZ chase authorization', current_date - 1, v_staff);

  raise notice 'fixtures created; last month = %', last_month;
end $$;

-- ─────────────────────────────────────────────────────────────
do $$
declare
  n_open   integer;
  failures text[] := '{}';
  r        record;

  procedure_check text;

  function_missing boolean;
begin
  n_open := public.generate_notifications();
  raise notice 'generate_notifications() returned % open notification(s)', n_open;

  for r in
    select kind, level, text from public.notifications
     where resolved_at is null and text like 'ZZ%' or text like '%ZZ-%'
     order by kind
  loop
    raise notice '  [%] % — %', r.level, r.kind, left(r.text, 90);
  end loop;

  -- Each rule must have produced its own kind.
  if not exists (select 1 from public.notifications
                  where kind = 'auth_exhausted' and level = 'bad'
                    and text like '%ZZ-EXHAUSTED%' and resolved_at is null) then
    failures := failures || 'auth_exhausted did not fire';
  end if;

  if not exists (select 1 from public.notifications
                  where kind = 'auth_low' and text like '%ZZ-LOW%' and resolved_at is null) then
    failures := failures || 'auth_low did not fire';
  end if;

  if not exists (select 1 from public.notifications
                  where kind = 'auth_ending' and text like '%ZZ-ENDING%' and resolved_at is null) then
    failures := failures || 'auth_ending did not fire';
  end if;

  if not exists (select 1 from public.notifications
                  where kind = 'invoice_unpaid' and level = 'bad'
                    and text like '%ZZ-INV-95%' and resolved_at is null) then
    failures := failures || 'invoice_unpaid did not fire at 90+ days as level bad';
  end if;

  if not exists (select 1 from public.notifications
                  where kind = 'task_overdue' and text like '%ZZ overdue task%'
                    and resolved_at is null) then
    failures := failures || 'task_overdue did not fire';
  end if;

  if not exists (select 1 from public.notifications
                  where kind = 'followup_due' and text like '%ZZ chase authorization%'
                    and resolved_at is null) then
    failures := failures || 'followup_due did not fire';
  end if;

  -- The monthly reminder only applies up to the 15th, which is the rule.
  if extract(day from current_date) <= 15 then
    if not exists (select 1 from public.notifications
                    where kind = 'monthly_forms' and text like '%ZZ Notify Client%'
                      and resolved_at is null) then
      failures := failures || 'monthly_forms did not fire before the 15th';
    end if;
  else
    raise notice 'past the 15th — the monthly USOR reminder is out of season, not checked';
  end if;

  -- An overdue task must reach Admin and the role it sits with, not everyone.
  if exists (select 1 from public.notifications
              where kind = 'task_overdue' and text like '%ZZ overdue task%'
                and 'Billing' = any (roles)) then
    failures := failures || 'LEAK: an overdue Job Search task was addressed to Billing';
  end if;

  if array_length(failures, 1) is not null then
    raise exception E'NOTIFICATION FAILURES:\n  %', array_to_string(failures, E'\n  ');
  end if;

  raise notice '--- ALL NOTIFICATION RULES FIRED ---';
end $$;

-- ─────────────────────────────────────────────────────────────
-- Re-running must not duplicate, and a condition that passes must clear.
-- ─────────────────────────────────────────────────────────────
do $$
declare
  before_count integer;
  after_count  integer;
  first_seen   timestamptz;
  still_seen   timestamptz;
begin
  select count(*), min(created_at) into before_count, first_seen
    from public.notifications where text like '%ZZ-EXHAUSTED%';

  perform public.generate_notifications();

  select count(*), min(created_at) into after_count, still_seen
    from public.notifications where text like '%ZZ-EXHAUSTED%';

  if after_count <> before_count then
    raise exception 'FAILED: re-running duplicated notifications (% then %)', before_count, after_count;
  end if;
  if still_seen <> first_seen then
    raise exception 'FAILED: re-running reset created_at, so "flagged since" would be wrong';
  end if;
  raise notice 'ok  re-running neither duplicated nor reset the raised date';

  -- Close the task; its alert should clear on the next run.
  update public.tasks set status = 'Done', done_at = current_date
   where title = 'ZZ overdue task';
  perform public.generate_notifications();

  if exists (select 1 from public.notifications
              where text like '%ZZ overdue task%' and resolved_at is null) then
    raise exception 'FAILED: completing the task did not clear its alert';
  end if;
  raise notice 'ok  completing the task cleared its alert';

  raise notice '--- NOTIFICATIONS VERIFIED ---';
end $$;

rollback;
