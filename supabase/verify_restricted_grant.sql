-- Zion Vocational Rehab CRM — restricted client records, given person by person (0232)
--
-- A staff member whose role does not include restricted records (here Job
-- Search) cannot see them; given "Restricted client records" by Admin, they
-- can - documents and the client portal alike; once it is ended, they cannot
-- again. It can only be given to view.
--
-- Runs inside a transaction that is rolled back. Nothing here is left behind.

begin;

do $$
declare v_js uuid; v_uid uuid; v_client uuid; v_before boolean; v_after boolean; v_portal boolean; v_ended boolean; v_admin uuid; v_auid uuid; g uuid; f text[] := '{}';
begin
  select id, user_id into v_js, v_uid from public.staff where role = 'Job Search' and active and not is_system and user_id is not null limit 1;
  select id, user_id into v_admin, v_auid from public.staff where role = 'Admin' and active and not is_system and user_id is not null limit 1;
  insert into public.clients (name, stage, status, assigned_staff_id) values ('ZZ Grant', 'Intake', 'Active', v_admin) returning id into v_client;
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
  v_before := public.can_see_restricted(v_client);
  perform set_config('request.jwt.claims', json_build_object('sub', v_auid, 'role', 'authenticated')::text, true);
  begin perform public.grant_staff_access(v_js, 'restricted', 'edit', 'zz test'); f := f || 'FAILED: restricted records were given to edit'::text; exception when check_violation then null; end;
  g := public.grant_staff_access(v_js, 'restricted', 'view', 'zz test grant');
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
  v_after := public.can_see_restricted(v_client); v_portal := public.can_manage_portal(v_client);
  perform set_config('request.jwt.claims', json_build_object('sub', v_auid, 'role', 'authenticated')::text, true);
  perform public.revoke_staff_access(g, 'zz test over');
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
  v_ended := public.can_see_restricted(v_client);
  if v_before or not v_after or not v_portal or v_ended then
    f := f || format('FAILED: before=%s after=%s portal=%s ended=%s', v_before, v_after, v_portal, v_ended);
  end if;
  if array_length(f, 1) > 0 then raise exception '%', array_to_string(f, E'\n'); end if;
  raise notice '--- RESTRICTED GRANT VERIFIED ---';
end $$;

rollback;
