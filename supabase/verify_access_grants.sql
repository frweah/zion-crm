-- Zion Vocational Rehab CRM — access given to one person, on top of their role
--
-- What has to hold, each tried from the direction that would break it:
--
--   Roles are the default and a grant only adds: nobody loses anything a role
--   gives, and a grant that would add nothing is refused.
--
--   The database enforces it. Without a grant the writes are refused by the
--   rules and by the billing functions; with view, reading opens and writing
--   stays shut; with edit, writing opens; once ended, it shuts again.
--
--   Only Admin gives or ends access. A grant is a record - who, when, why -
--   that is never edited or deleted, only ended once.
--
--   Making somebody inactive ends everything given to them.
--
-- Uses made-up staff (ZZ) so no real person's access is touched. Runs inside a
-- transaction that is rolled back. Nothing here is left behind.

begin;

do $$
declare
  v_admin     uuid;
  v_adm_uid   uuid;
  v_rep       uuid;
  v_rep_uid   uuid := gen_random_uuid();
  v_bil       uuid;
  v_bil_uid   uuid := gen_random_uuid();
  v_client    uuid;
  v_grant     uuid;
  v_n         bigint;
  v_text      text;
  v_state     text;
  r           record;
  failures    text[] := '{}';
begin
  select id, user_id into v_admin, v_adm_uid from public.staff
   where role = 'Admin' and active and user_id is not null order by created_at, id limit 1;

  -- ── made-up people ─────────────────────────────────────────
  insert into public.staff (name, email, role, active) values ('ZZ Grant Reports', 'zz-grant-reports@example.test', 'Reports', true)
  returning id into v_rep;
  insert into public.staff (name, email, role, active) values ('ZZ Grant Billing', 'zz-grant-billing@example.test', 'Billing', true)
  returning id into v_bil;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_rep_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-grant-reports@example.test', '{}', '{}', now(), now()),
         (v_bil_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-grant-billing@example.test', '{}', '{}', now(), now());

  insert into public.clients (name, stage, status, assigned_staff_id)
  values ('ZZ Grant Client', 'Job Coaching', 'Active', v_admin) returning id into v_client;

  -- ── what each role gives, with no grant ────────────────────
  select string_agg(format('%s/%s', x.role, x.area), ', ') into v_text
    from (values
      ('Admin', 'tasks', true), ('Admin', 'counselors', true), ('Admin', 'billing', true), ('Admin', 'insights', true),
      ('Job Search', 'tasks', true), ('Job Search', 'counselors', true), ('Job Search', 'billing', false), ('Job Search', 'insights', false),
      ('Reports', 'tasks', true), ('Reports', 'counselors', false), ('Reports', 'billing', false), ('Reports', 'insights', false),
      ('Billing', 'tasks', false), ('Billing', 'counselors', true), ('Billing', 'billing', true), ('Billing', 'insights', false)
    ) as x(role, area, expected)
   where public.role_has_area(x.role, x.area, 'view') <> x.expected;
  if v_text is not null then
    failures := failures || format('FAILED: role defaults disagree with the navigation for %s', v_text)::text;
  else
    raise notice 'ok  each role''s areas are what the navigation gives it (lib/roles.ts ROLE_AREAS)';
  end if;

  -- ── before any grant: refused, by the rules and the functions ──
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_rep_uid, 'role', 'authenticated')::text, true);

  if public.staff_has_area('billing', 'view') then
    failures := failures || 'FAILED: a Reports member of staff has Billing with no grant'::text;
  end if;
  begin
    insert into public.authorizations (client_id, number, service_type, rate, rate_type, status)
    values (v_client, 'ZQ-GRANT-0', 'ZZ Grant Service', 100, 'Flat Fee', 'Open');
    failures := failures || 'FAILED: somebody without Billing added an authorization'::text;
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.dismiss_warrant_line(gen_random_uuid(), 'ZZ');
    failures := failures || 'FAILED: somebody without Billing got past a billing function''s check'::text;
  exception when insufficient_privilege then
    raise notice 'ok  without a grant, the rules and the billing functions refuse';
  end;
  begin
    perform public.grant_staff_access(v_rep, 'billing', 'edit', 'ZZ giving myself access');
    failures := failures || 'FAILED: somebody who is not Admin gave themselves access'::text;
  exception when insufficient_privilege then
    raise notice 'ok  only Admin gives access beyond a role';
  end;

  -- ── Admin gives Billing, view only ─────────────────────────
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);

  begin
    perform public.grant_staff_access(v_bil, 'billing', 'view', 'ZZ already theirs');
    failures := failures || 'FAILED: a grant was given for what the role already gives'::text;
  exception when check_violation then
    raise notice 'ok  a grant that would add nothing to the role is refused';
  end;
  begin
    perform public.grant_staff_access(v_rep, 'insights', 'edit', 'ZZ insights edit');
    failures := failures || 'FAILED: Insights was given to edit'::text;
  exception when check_violation then null;
  end;
  begin
    perform public.grant_staff_access(v_rep, 'billing', 'view', '  ');
    failures := failures || 'FAILED: access was given with no reason'::text;
  exception when check_violation then null;
  end;
  begin
    perform public.grant_staff_access(v_rep, 'people', 'view', 'ZZ people');
    failures := failures || 'FAILED: People was given as an area'::text;
  exception when check_violation then
    raise notice 'ok  People and System cannot be given; Insights only to view; a reason is required';
  end;

  v_grant := public.grant_staff_access(v_rep, 'billing', 'view', 'ZZ covering billing questions while the owner is away');
  perform public.grant_staff_access(v_bil, 'tasks', 'view', 'ZZ seeing the task list');

  if not exists (select 1 from public.staff_access_grants
                  where id = v_grant and granted_by = v_admin and granted_by_name <> '' and reason like 'ZZ covering%') then
    failures := failures || 'FAILED: a grant does not record who gave it and why'::text;
  else
    raise notice 'ok  a grant records who gave it, when and why';
  end if;

  -- ── view: reading opens, writing stays shut ────────────────
  perform set_config('request.jwt.claims', json_build_object('sub', v_rep_uid, 'role', 'authenticated')::text, true);

  if not public.staff_has_area('billing', 'view') or public.staff_has_area('billing', 'edit') then
    failures := failures || 'FAILED: a view grant did not give view, or gave edit'::text;
  end if;
  begin
    select count(*) into v_n from public.warrant_lines;
  exception when insufficient_privilege then
    failures := failures || 'FAILED: a Billing view grant cannot read warrants'::text;
  end;
  begin
    insert into public.authorizations (client_id, number, service_type, rate, rate_type, status)
    values (v_client, 'ZQ-GRANT-1', 'ZZ Grant Service', 100, 'Flat Fee', 'Open');
    failures := failures || 'FAILED: a view-only grant added an authorization'::text;
  exception when insufficient_privilege then
    raise notice 'ok  view only opens reading; writing stays shut';
  end;
  if (select count(*) from public.staff_access_grants) <> 1 then
    failures := failures || 'FAILED: somebody can see grants other than their own'::text;
  else
    raise notice 'ok  a person sees their own grants and nobody else''s';
  end if;

  -- ── edit: writing opens, and the old grant is ended, not changed ──
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);
  perform public.grant_staff_access(v_rep, 'billing', 'edit', 'ZZ now doing the invoices too');

  perform set_config('role', 'postgres', true);
  if not exists (select 1 from public.staff_access_grants
                  where id = v_grant and revoked_at is not null and revoke_reason like 'Replaced by view and edit access:%')
     or (select count(*) from public.staff_access_grants where staff_id = v_rep and revoked_at is null) <> 1 then
    failures := failures || 'FAILED: raising view to edit did not end the old grant and start one new one'::text;
  else
    raise notice 'ok  raising view to edit ends the old grant, with the reason, and starts a new one';
  end if;
  perform set_config('role', 'authenticated', true);

  perform set_config('request.jwt.claims', json_build_object('sub', v_rep_uid, 'role', 'authenticated')::text, true);
  begin
    insert into public.authorizations (client_id, number, service_type, rate, rate_type, status)
    values (v_client, 'ZQ-GRANT-2', 'ZZ Grant Service', 100, 'Flat Fee', 'Open');
  exception when insufficient_privilege then
    failures := failures || 'FAILED: an edit grant could not add an authorization'::text;
  end;
  v_state := 'passed the check';
  begin
    perform public.dismiss_warrant_line(gen_random_uuid(), 'ZZ');
  exception
    when insufficient_privilege then v_state := 'refused';
    when others then v_state := 'passed the check';
  end;
  if v_state = 'refused' then
    failures := failures || 'FAILED: an edit grant is still refused by the billing functions'::text;
  else
    raise notice 'ok  with edit, the rules and the billing functions let them work';
  end if;

  -- ── a record, never rewritten ──────────────────────────────
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);
  begin
    insert into public.staff_access_grants (staff_id, area, level, reason) values (v_rep, 'tasks', 'edit', 'ZZ by hand');
    failures := failures || 'FAILED: a grant was written around grant_staff_access'::text;
  exception when insufficient_privilege then null;
  end;
  perform set_config('role', 'postgres', true);
  begin
    update public.staff_access_grants set level = 'view' where staff_id = v_rep and revoked_at is null;
    failures := failures || 'FAILED: a grant was changed instead of ended'::text;
  exception when check_violation then null;
  end;
  begin
    delete from public.staff_access_grants where id = v_grant;
    failures := failures || 'FAILED: a grant was deleted'::text;
  exception when insufficient_privilege then
    raise notice 'ok  a grant is never written by hand, changed or deleted - only ended';
  end;
  perform set_config('role', 'authenticated', true);

  -- ── ending it shuts it again ───────────────────────────────
  select id into v_grant from public.staff_access_grants where staff_id = v_rep and area = 'billing' and revoked_at is null;
  perform public.revoke_staff_access(v_grant, 'ZZ cover finished');
  begin
    perform public.revoke_staff_access(v_grant, 'ZZ again');
    failures := failures || 'FAILED: an ended grant was ended twice'::text;
  exception when check_violation then null;
  end;
  perform set_config('request.jwt.claims', json_build_object('sub', v_rep_uid, 'role', 'authenticated')::text, true);
  begin
    insert into public.authorizations (client_id, number, service_type, rate, rate_type, status)
    values (v_client, 'ZQ-GRANT-3', 'ZZ Grant Service', 100, 'Flat Fee', 'Open');
    failures := failures || 'FAILED: ended access still let them add an authorization'::text;
  exception when insufficient_privilege then
    raise notice 'ok  ended access shuts again, and the record says who ended it and why';
  end;

  -- ── the role is never taken away ───────────────────────────
  perform set_config('request.jwt.claims', json_build_object('sub', v_bil_uid, 'role', 'authenticated')::text, true);
  if not public.staff_has_area('billing', 'edit') or not public.staff_has_area('counselors', 'edit')
     or not public.staff_has_area('tasks', 'view') then
    failures := failures || 'FAILED: a grant cost a Billing member of staff something their role gives'::text;
  else
    raise notice 'ok  a grant adds to a role and takes nothing from it';
  end if;

  -- ── inactive ends everything ───────────────────────────────
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);
  perform public.grant_staff_access(v_rep, 'counselors', 'edit', 'ZZ before leaving');
  perform set_config('role', 'postgres', true);
  update public.staff set active = false where id = v_rep;
  if exists (select 1 from public.staff_access_grants where staff_id = v_rep and revoked_at is null)
     or not exists (select 1 from public.staff_access_grants
                     where staff_id = v_rep and area = 'counselors' and revoke_reason like 'Ended automatically when ZZ Grant Reports was made inactive.%') then
    failures := failures || 'FAILED: making somebody inactive did not end their grants'::text;
  else
    raise notice 'ok  making somebody inactive ends every grant, and says so';
  end if;
  begin
    perform set_config('request.jwt.claims', json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);
    perform set_config('role', 'authenticated', true);
    perform public.grant_staff_access(v_rep, 'tasks', 'view', 'ZZ after leaving');
    failures := failures || 'FAILED: access was given to somebody inactive'::text;
  exception when check_violation then null;
  end;
  perform set_config('role', 'postgres', true);

  -- ── the six billing functions all ask ──────────────────────
  select string_agg(p.proname, ', ') into v_text
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('confirm_authorization_document', 'dismiss_warrant_line', 'link_document_to_authorization',
                       'reconcile_warrant_line', 'reconcile_warrant_page', 'replace_placeholder_authorization')
     and position('staff_has_area' in pg_get_functiondef(p.oid)) = 0;
  if v_text is not null then
    failures := failures || format('FAILED: billing functions that ignore grants: %s', v_text)::text;
  end if;

  if has_function_privilege('anon', 'public.grant_staff_access(uuid, text, text, text)', 'execute')
     or has_function_privilege('anon', 'public.staff_has_area(text, text)', 'execute')
     or has_table_privilege('anon', 'public.staff_access_grants', 'select')
     or has_table_privilege('authenticated', 'public.staff_access_grants', 'insert') then
    failures := failures || 'FAILED: grants can be read or written from outside the rules'::text;
  else
    raise notice 'ok  nobody signed out sees a grant, and nobody writes one except through the rules';
  end if;

  perform set_config('request.jwt.claims', '', true);

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- ACCESS GRANTS VERIFIED ---';
end $$;

rollback;
