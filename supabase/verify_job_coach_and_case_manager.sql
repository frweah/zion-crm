-- Zion Vocational Rehab CRM — Job Coach and Case Manager (0180)
--
-- Two roles, and the one thing that makes Job Coach a role rather than a
-- label: hours against a coaching authorization, and not against any other.
-- Tried from the direction that would break it:
--
--   Both roles exist, so a record can be set to either.
--   Job Coach has what Job Search has; Case Manager has what Reports has.
--   Neither reaches Billing or Insights, whatever else they can do.
--   A Job Coach logs hours against Job Coaching and is refused Job Placement.
--   Everybody who could log hours before still can, against anything.
--   Rispah is a Case Manager, and the placeholder seat is gone.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_admin    uuid;
  v_coach    uuid;
  v_coach_u  uuid := gen_random_uuid();
  v_case     uuid;
  v_case_u   uuid := gen_random_uuid();
  v_client   uuid;
  v_coaching uuid;
  v_placing  uuid;
  v_text     text;
  failures   text[] := '{}';
begin
  select id into v_admin from public.staff
   where role = 'Admin' and active and user_id is not null order by created_at limit 1;

  -- ── the roles exist ────────────────────────────────────────
  insert into public.staff (name, email, role, active)
  values ('ZZ Coach Testperson', 'zz-coach@example.test', 'Job Coach', true)
  returning id into v_coach;
  insert into public.staff (name, email, role, active)
  values ('ZZ Case Testperson', 'zz-case@example.test', 'Case Manager', true)
  returning id into v_case;
  raise notice 'ok  a record can be set to Job Coach and to Case Manager';

  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data,
                          raw_user_meta_data, created_at, updated_at)
  values (v_coach_u, '00000000-0000-0000-0000-000000000000', 'authenticated',
          'authenticated', 'zz-coach@example.test', '{}', '{}', now(), now()),
         (v_case_u, '00000000-0000-0000-0000-000000000000', 'authenticated',
          'authenticated', 'zz-case@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_coach_u where id = v_coach;
  update public.staff set user_id = v_case_u where id = v_case;

  -- ── what each role has, and what it does not ───────────────
  select string_agg(format('%s/%s', x.role, x.area), ', ') into v_text
    from (values
      ('Job Coach', 'tasks', true), ('Job Coach', 'counselors', true),
      ('Job Coach', 'billing', false), ('Job Coach', 'insights', false),
      ('Case Manager', 'tasks', true), ('Case Manager', 'counselors', false),
      ('Case Manager', 'billing', false), ('Case Manager', 'insights', false)
    ) as x(role, area, expected)
   where public.role_has_area(x.role, x.area, 'view') <> x.expected;
  if v_text is not null then
    failures := failures ||
      format('FAILED: the new roles do not have what lib/roles.ts gives them: %s', v_text)::text;
  else
    raise notice 'ok  Job Coach has Job Search''s areas, Case Manager has Reports'', and neither has Billing or Insights';
  end if;

  -- ── hours: coaching yes, anything else no ──────────────────
  insert into public.clients (name, stage, status)
  values ('ZZ Coach Client', 'Job Coaching', 'Active') returning id into v_client;
  insert into public.authorizations
    (client_id, number, service_type, rate_type, rate, total_hours, status, start_date, end_date)
  values (v_client, 'ZZ-C-1', 'Job Coaching', 'Hourly', 45, 40, 'Authorized',
          public.practice_today() - 30, public.practice_today() + 30)
  returning id into v_coaching;
  insert into public.authorizations
    (client_id, number, service_type, rate_type, rate, status, start_date, end_date)
  values (v_client, 'ZZ-C-2', 'Job Placement', 'Flat Fee', 1500, 'Authorized',
          public.practice_today() - 30, public.practice_today() + 30)
  returning id into v_placing;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_coach_u, 'role', 'authenticated')::text, true);

  begin
    insert into public.service_entries (auth_id, date, hours, staff_id, notes)
    values (v_coaching, public.practice_today() - 1, 2, v_coach, 'ZZ coaching visit');
    raise notice 'ok  a Job Coach logs hours against a coaching authorization';
  exception when others then
    get stacked diagnostics v_text = message_text;
    failures := failures ||
      format('FAILED: a Job Coach could not log coaching hours: %s', v_text)::text;
  end;

  begin
    insert into public.service_entries (auth_id, date, hours, staff_id, notes)
    values (v_placing, public.practice_today() - 1, 2, v_coach, 'ZZ placement visit');
    failures := failures ||
      'FAILED: a Job Coach logged hours against a Job Placement authorization'::text;
  exception when insufficient_privilege then
    raise notice 'ok  and is refused one that is not coaching';
  end;

  -- A Case Manager does not log hours at all.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_case_u, 'role', 'authenticated')::text, true);
  begin
    insert into public.service_entries (auth_id, date, hours, staff_id, notes)
    values (v_coaching, public.practice_today() - 1, 1, v_case, 'ZZ case visit');
    failures := failures || 'FAILED: a Case Manager logged billable hours'::text;
  exception when insufficient_privilege then
    raise notice 'ok  a Case Manager logs no billable hours';
  end;

  -- ── and nobody lost anything ───────────────────────────────
  perform set_config('role', 'postgres', true);
  select string_agg(r, ', ') into v_text from (
    select r from unnest(array['Admin', 'Billing', 'Job Search']) as r
     where not public.role_has_area(r, 'tasks') and r <> 'Billing'
  ) x;
  if v_text is not null then
    failures := failures || format('FAILED: %s lost an area they had', v_text)::text;
  end if;
  if not (public.role_has_area('Admin', 'billing', 'edit')
          and public.role_has_area('Billing', 'billing', 'edit')
          and public.role_has_area('Job Search', 'counselors', 'edit')
          and public.role_has_area('Reports', 'tasks', 'edit')) then
    failures := failures || 'FAILED: an existing role lost what it had'::text;
  else
    raise notice 'ok  the four roles that existed are unchanged';
  end if;

  -- ── the two housekeeping facts ─────────────────────────────
  if (select role from public.staff where name = 'Rispah Otieno') <> 'Case Manager' then
    failures := failures || 'FAILED: Rispah is not a Case Manager'::text;
  else
    raise notice 'ok  Rispah is a Case Manager (her record and invite were already there)';
  end if;

  if exists (select 1 from public.staff where name = 'Billing (to be assigned)') then
    failures := failures || 'FAILED: the Billing placeholder seat is still on file'::text;
  else
    raise notice 'ok  the "Billing (to be assigned)" seat is gone';
  end if;

  perform set_config('request.jwt.claims', '', true);

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- JOB COACH AND CASE MANAGER VERIFIED ---';
end $$;

rollback;
