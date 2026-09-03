-- Zion Vocational Rehab CRM — Phase 1 verification
--
-- Run this in the Supabase SQL Editor after the four migrations. It checks the
-- structure, then exercises the billing and form rules against throwaway rows.
-- Everything happens inside a transaction that is rolled back at the end, so it
-- leaves nothing behind. If it prints "PHASE 1 VERIFIED" it passed; any problem
-- raises an error instead.

begin;

-- ── 1. Structure ──────────────────────────────────────────────
do $$
declare
  t          text;
  missing    text[] := '{}';
  no_policy  text[] := '{}';
  tables     text[] := array[
    'staff','offices','rate_schedule','counselors','clients','client_private',
    'client_stage_history','intakes','authorizations','service_entries',
    'completions','invoices','placements','tasks','notes','form_templates',
    'forms','contact_log','hours_requests','sops'
  ];
begin
  foreach t in array tables loop
    if not exists (
      select 1 from pg_class c
        join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'public' and c.relname = t and c.relrowsecurity
    ) then
      missing := missing || t;
    end if;

    if not exists (
      select 1 from pg_policies where schemaname = 'public' and tablename = t
    ) then
      no_policy := no_policy || t;
    end if;
  end loop;

  if array_length(missing, 1) is not null then
    raise exception 'Row-level security is OFF on: %', array_to_string(missing, ', ');
  end if;
  if array_length(no_policy, 1) is not null then
    raise exception 'No policies on: %', array_to_string(no_policy, ', ');
  end if;

  raise notice 'ok  RLS enabled with policies on all % tables', array_length(tables, 1);
end $$;

do $$
declare fn text;
begin
  foreach fn in array array[
    'current_staff_id','current_staff_role','is_active_staff','is_admin','can_see_restricted'
  ] loop
    if not exists (
      select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = fn and p.prosecdef
    ) then
      raise exception 'Missing SECURITY DEFINER function public.%()', fn;
    end if;
  end loop;
  raise notice 'ok  identity helper functions present';
end $$;

do $$
begin
  if exists (
    select 1
      from information_schema.role_table_grants
     where grantee = 'anon' and table_schema = 'public'
  ) then
    raise exception 'The anon role still has table grants in public — nothing should be readable without a login';
  end if;
  raise notice 'ok  anon has no access to any table';
end $$;

do $$
declare n integer;
begin
  select count(*) into n from public.form_templates;
  if n <> 8 then raise exception 'Expected 8 USOR form templates, found %', n; end if;

  select count(*) into n from public.form_templates where sensitive;
  if n <> 2 then raise exception 'Expected USOR 94 and 98 to be marked sensitive, found % sensitive', n; end if;

  select count(*) into n from public.rate_schedule;
  if n <> 18 then raise exception 'Expected 18 rate schedule rows, found %', n; end if;

  raise notice 'ok  reference data loaded (8 form templates, 18 rates)';
end $$;

-- ── 2. Business rules ─────────────────────────────────────────
do $$
declare
  v_counselor uuid;
  v_client    uuid;
  v_auth      uuid;
  v_invoice   uuid;
  v_form      uuid;
begin
  insert into public.counselors (name) values ('ZZ Verify Counselor')
    returning id into v_counselor;
  insert into public.clients (name, counselor_id) values ('ZZ Verify Client', v_counselor)
    returning id into v_client;
  insert into public.authorizations
    (client_id, number, service_type, total_hours, rate_type, rate)
  values (v_client, 'ZZ-VERIFY-1', 'Job Coaching', 10, 'Hourly', 45)
    returning id into v_auth;

  -- Stage history is written automatically.
  if not exists (select 1 from public.client_stage_history where client_id = v_client) then
    raise exception 'FAILED: no stage history row was created for a new client';
  end if;
  raise notice 'ok  new client recorded a pipeline stage';

  -- Hours within the authorization are accepted.
  insert into public.service_entries (auth_id, date, hours) values (v_auth, current_date, 6);
  raise notice 'ok  service entry within the authorization accepted';

  -- Hours beyond the authorization are refused.
  begin
    insert into public.service_entries (auth_id, date, hours) values (v_auth, current_date, 5);
    raise exception 'FAILED: an entry exceeding the authorized hours was accepted';
  exception when check_violation then
    raise notice 'ok  entry beyond the authorized hours refused';
  end;

  -- Future dates are refused.
  begin
    insert into public.service_entries (auth_id, date, hours)
      values (v_auth, current_date + 1, 1);
    raise exception 'FAILED: a future-dated entry was accepted';
  exception when check_violation then
    raise notice 'ok  future-dated entry refused';
  end;

  -- An invoice cannot exceed what the authorization authorizes (10 x 45 = 450).
  begin
    insert into public.invoices (auth_id, number, amount) values (v_auth, 'ZZ-1', 500);
    raise exception 'FAILED: an invoice above the authorized amount was accepted';
  exception when check_violation then
    raise notice 'ok  invoice above the authorized amount refused';
  end;

  insert into public.invoices (auth_id, number, amount, status)
    values (v_auth, 'ZZ-1', 400, 'Draft')
    returning id into v_invoice;

  -- Job Coaching requires USOR 93 and 95 before the invoice can be sent.
  begin
    update public.invoices set status = 'Sent' where id = v_invoice;
    raise exception 'FAILED: an invoice was sent with USOR forms outstanding';
  exception when check_violation then
    raise notice 'ok  invoice with USOR 93/95 outstanding could not be sent';
  end;

  insert into public.forms (template_id, client_id, auth_id, status, data)
    values ('usor93', v_client, v_auth, 'Completed', '{"note":"verify"}'::jsonb)
    returning id into v_form;
  insert into public.forms (template_id, client_id, auth_id, status)
    values ('usor95', v_client, v_auth, 'Completed');

  update public.invoices set status = 'Sent' where id = v_invoice;
  if (select sent_date from public.invoices where id = v_invoice) is null then
    raise exception 'FAILED: sent_date was not stamped when the invoice was sent';
  end if;
  raise notice 'ok  invoice sent once the required forms were completed';

  -- A completed form is locked.
  begin
    update public.forms set data = '{"note":"tampered"}'::jsonb where id = v_form;
    raise exception 'FAILED: a completed form was edited';
  exception when check_violation then
    raise notice 'ok  completed form is locked against edits';
  end;

  begin
    update public.forms set status = 'Draft' where id = v_form;
    raise exception 'FAILED: a completed form was reopened';
  exception when check_violation then
    raise notice 'ok  completed form cannot be reopened';
  end;

  -- USOR 94 and 98 are flagged restricted automatically.
  insert into public.forms (template_id, client_id, status) values ('wsa', v_client, 'Draft');
  if not (select sensitive from public.forms
           where client_id = v_client and template_id = 'wsa') then
    raise exception 'FAILED: a USOR 94 form was not flagged as restricted';
  end if;
  raise notice 'ok  USOR 94 flagged as restricted content';

  -- An intake cannot be saved without consent.
  begin
    insert into public.intakes (client_id, consent_signed) values (v_client, false);
    raise exception 'FAILED: an intake was saved without consent';
  exception when check_violation then
    raise notice 'ok  intake without consent refused';
  end;

  raise notice '--- PHASE 1 VERIFIED ---';
end $$;

rollback;
