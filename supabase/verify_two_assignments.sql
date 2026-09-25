-- Zion Vocational Rehab CRM — job search and billing, two assignments (0121)
--
-- What has to hold, each tried from the direction that would break it:
--
--   Billing edits a client it is not assigned to - because no Billing seat
--   is ever assigned - and so does somebody given billing edit. Job Search
--   and Intake & Reports still can, and a system account still cannot.
--
--   A client's billing alerts are addressed to whoever bills for them; the
--   rest to whoever works their job search; a task's alert keeps the person
--   the task is on.
--
--   Billing the client is not a way into their restricted details: the
--   billing contact sees no more of them than anybody else.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_js uuid; v_js_uid uuid := gen_random_uuid();
  v_bill uuid; v_bill_uid uuid := gen_random_uuid();
  v_granted uuid; v_granted_uid uuid := gen_random_uuid();
  v_client uuid;
  v_auth uuid;
  v_who uuid;
  v_n integer;
  failures text[] := '{}';
begin
  insert into public.staff (name, email, role, active) values ('ZZ Two JobSearch', 'zz-two-js@example.test', 'Job Search', true) returning id into v_js;
  insert into public.staff (name, email, role, active) values ('ZZ Two Billing', 'zz-two-bill@example.test', 'Billing', true) returning id into v_bill;
  insert into public.staff (name, email, role, active) values ('ZZ Two Granted', 'zz-two-grant@example.test', 'Reports', true) returning id into v_granted;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_js_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-two-js@example.test', '{}', '{}', now(), now()),
         (v_bill_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-two-bill@example.test', '{}', '{}', now(), now()),
         (v_granted_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-two-grant@example.test', '{}', '{}', now(), now());

  insert into public.clients (name, stage, status, assigned_staff_id, billing_staff_id)
  values ('ZZ Two Client', 'Job Coaching', 'Active', v_js, v_bill) returning id into v_client;
  -- Out of hours: the alert a client's authorization raises for Billing.
  insert into public.authorizations (client_id, number, service_type, total_hours, carried_used, rate_type, rate, status)
  values (v_client, 'V0000882', 'Job Coaching', 10, 10, 'Hourly', 45, 'Open') returning id into v_auth;
  insert into public.tasks (client_id, assigned_staff_id, title, due, status)
  values (v_client, v_js, 'ZZ two task', public.practice_today() - 1, 'Open');

  -- ── Billing edits any client ──────────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_bill_uid, 'role', 'authenticated')::text, true);
  update public.clients set funding_source = 'ZZ set by Billing' where id = v_client;
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    failures := failures || 'FAILED: Billing cannot edit a client it is not assigned to'::text;
  end if;

  -- Somebody whose role does not bill, given billing edit.
  perform set_config('role', 'postgres', true);
  insert into public.staff_access_grants (staff_id, area, level, reason) values (v_granted, 'billing', 'edit', 'ZZ covering billing');
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_granted_uid, 'role', 'authenticated')::text, true);
  update public.clients set funding_source = 'ZZ set by a grant' where id = v_client;
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    failures := failures || 'FAILED: a billing edit grant cannot edit a client'::text;
  end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_js_uid, 'role', 'authenticated')::text, true);
  update public.clients set caseload = 'ZZ set by Job Search' where id = v_client;
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    failures := failures || 'FAILED: Job Search can no longer edit a client'::text;
  else
    raise notice 'ok  Billing, a billing grant and Job Search all edit a client, assigned or not';
  end if;

  -- ── billing the client is not a way into their details ────
  perform set_config('request.jwt.claims', json_build_object('sub', v_bill_uid, 'role', 'authenticated')::text, true);
  if public.can_see_restricted(v_client) then
    failures := failures || 'FAILED: billing for a client now opens their restricted details'::text;
  end if;

  -- ── whose alert is whose ──────────────────────────────────
  perform set_config('role', 'postgres', true);
  perform public.generate_notifications_on(public.practice_today());

  select staff_id into v_who from public.notifications
   where client_id = v_client and kind in ('auth_exhausted', 'auth_low') and resolved_at is null limit 1;
  if v_who is distinct from v_bill then
    failures := failures || 'FAILED: a client''s authorization alert did not go to whoever bills for them'::text;
  end if;

  select staff_id into v_who from public.notifications
   where client_id = v_client and kind = 'task_overdue' and resolved_at is null limit 1;
  if v_who is distinct from v_js then
    failures := failures || 'FAILED: a task''s alert stopped going to the person it is on'::text;
  else
    raise notice 'ok  a billing alert is addressed to the billing contact, a task''s to whoever holds the task';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
