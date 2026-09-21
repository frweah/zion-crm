-- Zion Vocational Rehab CRM — who is getting an authorization invoiced (0114)
--
-- What has to hold, each tried from the direction that would break it:
--
--   Billing (and Admin) set the owner, the next action and the due date.
--   Somebody who does not bill cannot, even on a client they work.
--
--   When and by whom it was last set is the database's record, not the
--   screen's: it is stamped on a change and cannot be written on its own.
--
--   Nobody signed in reads or writes any of it.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_billing uuid; v_billing_uid uuid := gen_random_uuid();
  v_worker  uuid; v_worker_uid  uuid := gen_random_uuid();
  v_client uuid;
  v_auth   uuid;
  v_n      integer;
  v_by     uuid;
  v_at     timestamptz;
  failures text[] := '{}';
begin
  insert into public.staff (name, email, role, active) values ('ZZ Followup Billing', 'zz-followup-billing@example.test', 'Billing', true) returning id into v_billing;
  insert into public.staff (name, email, role, active) values ('ZZ Followup Worker', 'zz-followup-worker@example.test', 'Job Search', true) returning id into v_worker;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_billing_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-followup-billing@example.test', '{}', '{}', now(), now()),
         (v_worker_uid,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-followup-worker@example.test',  '{}', '{}', now(), now());

  insert into public.clients (name, stage, status, assigned_staff_id)
  values ('ZZ Followup Client', 'Job Coaching', 'Active', v_worker) returning id into v_client;
  insert into public.authorizations (client_id, number, service_type, total_hours, rate_type, rate, status)
  values (v_client, 'V0000999', 'Job Coaching', 20, 'Hourly', 45, 'Open') returning id into v_auth;

  -- ── somebody who does not bill ─────────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_worker_uid, 'role', 'authenticated')::text, true);
  update public.authorizations set followup_owner = v_worker, followup_action = 'ZZ worker says so' where id = v_auth;
  get diagnostics v_n = row_count;
  if v_n <> 0 then
    failures := failures || 'FAILED: somebody who does not bill set who owns invoicing an authorization'::text;
  end if;

  -- ── Billing ────────────────────────────────────────────────
  perform set_config('request.jwt.claims', json_build_object('sub', v_billing_uid, 'role', 'authenticated')::text, true);
  update public.authorizations
     set followup_owner = v_billing, followup_action = 'ZZ send USOR 95 then invoice', followup_due = public.practice_today() + 7
   where id = v_auth;
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    failures := failures || 'FAILED: Billing could not set the owner and next action'::text;
  end if;

  perform set_config('role', 'postgres', true);
  select followup_set_by, followup_set_at into v_by, v_at from public.authorizations where id = v_auth;
  if v_by is distinct from v_billing or v_at is null then
    failures := failures || 'FAILED: setting the next action was not stamped with who and when'::text;
  end if;

  -- The stamp cannot be written on its own.
  perform set_config('role', 'authenticated', true);
  update public.authorizations set followup_set_by = v_worker, followup_set_at = now() - interval '1 year' where id = v_auth;
  perform set_config('role', 'postgres', true);
  if (select followup_set_by from public.authorizations where id = v_auth) is distinct from v_billing then
    failures := failures || 'FAILED: who set the next action was overwritten without the next action changing'::text;
  else
    raise notice 'ok  Billing sets the owner and next action, stamped by the database; somebody who does not bill cannot';
  end if;

  -- Too long a next action is refused.
  begin
    update public.authorizations set followup_action = repeat('x', 501) where id = v_auth;
    failures := failures || 'FAILED: a next action over 500 characters was accepted'::text;
  exception when check_violation then null;
  end;

  -- ── nobody signed in ───────────────────────────────────────
  if has_table_privilege('anon', 'public.authorizations', 'select')
     and exists (select 1 from pg_policies where tablename = 'authorizations' and 'anon' = any(roles)) then
    failures := failures || 'FAILED: somebody not signed in has a rule letting them read authorizations'::text;
  end if;
  if has_function_privilege('authenticated', 'public.stamp_authorization_followup()', 'execute') then
    failures := failures || 'FAILED: the stamp can be called directly'::text;
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
