-- Zion Vocational Rehab CRM — the client's own database role
--
-- What has to hold, each tried from the direction that would break it:
--
--   portal_client is granted nothing outside the portal's own five tables.
--   Asked for any other table it is refused for want of a privilege, before
--   any policy is consulted - so a policy written wrong, or a table added with
--   none, cannot show a client somebody else's record.
--
--   Inside those five, the same rules as before: their own account, sessions,
--   consents and activity, and the terms; nothing of another client's.
--
--   It cannot issue or check sign-in codes, give portal access, or run any
--   staff function; and a function created later is not granted to it.
--
--   The access-token hook gives the role to a live portal account, hands a
--   staff member's token back untouched, and is callable only by the sign-in
--   service.
--
-- Runs inside a transaction that is rolled back. Nothing here is left behind.

begin;

do $$
declare
  v_admin    uuid;
  v_adm_uid  uuid;
  v_client_a uuid;
  v_client_b uuid;
  v_user_a   uuid := gen_random_uuid();
  v_acct_a   uuid;
  v_acct_b   uuid;
  v_sess_a   uuid := gen_random_uuid();
  v_n        bigint;
  v_open     text;
  v_refused  boolean;
  v_event    jsonb;
  r          record;
  failures   text[] := '{}';
begin
  select id, user_id into v_admin, v_adm_uid from public.staff
   where role = 'Admin' and active and user_id is not null order by created_at limit 1;

  insert into public.clients (name, stage, status, assigned_staff_id, phone)
  values ('ZZ Role Client A', 'Job Coaching', 'Active', v_admin, '(801) 555-0111') returning id into v_client_a;
  insert into public.clients (name, stage, status, assigned_staff_id, phone)
  values ('ZZ Role Client B', 'Job Coaching', 'Active', v_admin, '(801) 555-0112') returning id into v_client_b;

  insert into public.portal_accounts (client_id, kind, name, phone)
  values (v_client_a, 'Client', 'ZZ Role Client A', '+18015550111') returning id into v_acct_a;
  insert into public.portal_accounts (client_id, kind, name, phone)
  values (v_client_b, 'Client', 'ZZ Role Client B', '+18015550112') returning id into v_acct_b;

  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_user_a, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'p-' || v_acct_a || '@portal.zionvocrehab.com', '{}', '{}', now(), now());
  insert into public.portal_sessions (id, account_id, auth_user_id) values (v_sess_a, v_acct_a, v_user_a);

  update public.portal_terms set is_current = false where is_current;
  insert into public.portal_terms (version, title, source_file, body, text_sha256, published_at, is_current)
  values ('zz-role-1', 'ZZ terms', 'zz.docx', '[{"type":"p","text":"ZZ"}]', repeat('c', 64), now(), true);
  insert into public.portal_consents (account_id, client_id, terms_version, kind, given, ip, acting_as, actor_name)
  values (v_acct_a, v_client_a, 'zz-role-1', 'Electronic communication', true, '203.0.113.5', 'Client', 'ZZ Role Client A');

  -- ── the hook decides the role ──────────────────────────────
  v_event := public.portal_access_token_hook(
    jsonb_build_object('user_id', v_user_a::text, 'claims', jsonb_build_object('role', 'authenticated', 'sub', v_user_a::text)));
  if v_event #>> '{claims,role}' <> 'portal_client' then
    failures := failures || 'FAILED: a portal account was not given the portal_client role in its token'::text;
  end if;
  v_event := public.portal_access_token_hook(
    jsonb_build_object('user_id', v_adm_uid::text, 'claims', jsonb_build_object('role', 'authenticated', 'sub', v_adm_uid::text)));
  if v_event #>> '{claims,role}' <> 'authenticated' then
    failures := failures || 'FAILED: a staff member''s token was changed by the portal hook'::text;
  end if;
  update public.portal_accounts set disabled_at = now() where id = v_acct_a;
  v_event := public.portal_access_token_hook(
    jsonb_build_object('user_id', v_user_a::text, 'claims', jsonb_build_object('role', 'authenticated', 'sub', v_user_a::text)));
  if v_event #>> '{claims,role}' <> 'authenticated' then
    failures := failures || 'FAILED: an account that was turned off still gets the portal_client role'::text;
  else
    raise notice 'ok  the sign-in hook gives the portal role to a live portal account, and to nobody else';
  end if;
  update public.portal_accounts set disabled_at = null where id = v_acct_a;

  if has_function_privilege('authenticated', 'public.portal_access_token_hook(jsonb)', 'execute')
     or has_function_privilege('anon', 'public.portal_access_token_hook(jsonb)', 'execute')
     or not has_function_privilege('supabase_auth_admin', 'public.portal_access_token_hook(jsonb)', 'execute') then
    failures := failures || 'FAILED: the sign-in hook is callable by somebody other than the sign-in service'::text;
  end if;
  if not pg_has_role('authenticator', 'portal_client', 'member') then
    failures := failures || 'FAILED: requests cannot be run as portal_client (authenticator is not a member)'::text;
  end if;

  -- ── granted nothing outside the portal's own tables ────────
  select string_agg(c.relname, ', ' order by c.relname) into v_open
    from pg_class c
   where c.relnamespace = 'public'::regnamespace
     and c.relkind in ('r', 'v', 'm', 'p')
     and c.relname not in ('portal_accounts', 'portal_sessions', 'portal_terms', 'portal_consents', 'portal_activity')
     and (has_table_privilege('portal_client', c.oid, 'select')
          or has_table_privilege('portal_client', c.oid, 'insert')
          or has_table_privilege('portal_client', c.oid, 'update')
          or has_table_privilege('portal_client', c.oid, 'delete'));
  if v_open is not null then
    failures := failures || format('FAILED: portal_client has privileges on: %s', v_open)::text;
  else
    raise notice 'ok  the client role is granted nothing outside the portal''s own five tables';
  end if;

  select string_agg(p.proname, ', ' order by p.proname) into v_open
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.prokind in ('f', 'p')
     and has_function_privilege('portal_client', p.oid, 'execute')
     and p.proname not in ('portal_session_account_id', 'portal_my_consent', 'portal_client_id',
                           'portal_touch_session', 'portal_me', 'portal_begin_session',
                           'portal_end_my_session', 'portal_record_consent');
  if v_open is not null then
    failures := failures || format('FAILED: portal_client can execute more than the portal needs: %s', v_open)::text;
  else
    raise notice 'ok  the client role can run only the portal''s own functions';
  end if;

  create function public.zz_verify_role_function() returns int language sql as 'select 1';
  if has_function_privilege('portal_client', 'public.zz_verify_role_function()', 'execute') then
    failures := failures || 'FAILED: a function created later is given to portal_client by default'::text;
  else
    raise notice 'ok  a function created later is not given to the client role';
  end if;

  -- ── as a client, in that role ──────────────────────────────
  perform set_config('role', 'portal_client', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user_a, 'role', 'portal_client', 'session_id', v_sess_a)::text, true);

  if public.portal_session_account_id() is distinct from v_acct_a
     or public.portal_client_id() is distinct from v_client_a then
    failures := failures || 'FAILED: a client signed in as portal_client is not recognised'::text;
  end if;

  v_refused := false;
  begin
    select count(*) into v_n from public.clients;
    if v_n > 0 then
      failures := failures || format('FAILED: portal_client read %s rows from clients', v_n)::text;
    end if;
  exception when insufficient_privilege then
    v_refused := true;
  end;
  if not v_refused then
    failures := failures || 'FAILED: portal_client was allowed to ask the clients table at all'::text;
  else
    raise notice 'ok  a client asking for a staff table is refused before any rule is consulted';
  end if;

  begin
    select count(*) into v_n from storage.objects;
    failures := failures || 'FAILED: portal_client can ask for stored files'::text;
  exception when insufficient_privilege then null;
  end;

  if (select count(*) from public.portal_accounts) <> 1
     or exists (select 1 from public.portal_accounts where id = v_acct_b)
     or (select count(*) from public.portal_terms where version = 'zz-role-1') <> 1 then
    failures := failures || 'FAILED: in its own role a client does not see exactly its own rows'::text;
  else
    raise notice 'ok  in its own role a client still sees its own account, and only its own';
  end if;

  begin
    perform public.portal_invite(v_client_a, 'Client');
    failures := failures || 'FAILED: portal_client gave portal access'::text;
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.portal_issue_code('(801) 555-0111', '203.0.113.5');
    failures := failures || 'FAILED: portal_client issued a sign-in code'::text;
  exception when insufficient_privilege then null;
  end;
  raise notice 'ok  a client cannot issue codes, give access, or run a staff function';

  -- The portal still works in this role: consent is recorded, the session touched.
  perform public.portal_record_consent('Electronic communication', true, '203.0.113.5', 'zz-agent');
  if public.portal_touch_session() <> 'ok' then
    failures := failures || 'FAILED: the portal does not work in the portal_client role'::text;
  else
    raise notice 'ok  signing in, consent and the session all work in the client role';
  end if;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('role', 'postgres', true);

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- PORTAL CLIENT ROLE VERIFIED ---';
end $$;

rollback;
