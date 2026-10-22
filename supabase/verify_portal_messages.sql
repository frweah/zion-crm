-- Zion Vocational Rehab CRM — portal messages and notices (0225)
--
-- What has to hold, each tried from the direction that would break it:
--
--   A client writes only once signed in and agreed to the current terms, and
--   only ever to their own thread; another client's thread is invisible.
--
--   Staff read and answer a portal thread only if they manage that client's
--   portal (Admin, Reports, or the assigned staff member) - by the table, by
--   the inbox and by the reply function alike.
--
--   A notice goes at most once an hour per thread, never to somebody who has
--   not signed in yet, and by text only to the client's own number with
--   texting consent. A skipped notice does not use up the hour.
--
--   A portal conversation always belongs to an account, and nothing else may
--   name one. The helper that makes a thread cannot be called directly.
--
--   Only a client funded by Utah VR has a portal account, and one whose
--   funding changes away from it loses access at once (0227).
--
-- Runs inside a transaction that is rolled back. Nothing here is left behind.

begin;

do $$
declare
  v_admin     uuid;
  v_adm_uid   uuid;
  v_js        uuid;
  v_js_uid    uuid;
  v_client_a  uuid;
  v_client_b  uuid;
  v_user_a    uuid := gen_random_uuid();
  v_user_b    uuid := gen_random_uuid();
  v_acct_a    uuid;
  v_acct_b    uuid;
  v_sess_a    uuid := gen_random_uuid();
  v_sess_b    uuid := gen_random_uuid();
  v_conv      uuid;
  v_n         bigint;
  v_ch        text;
  failures    text[] := '{}';
begin
  select id, user_id into v_admin, v_adm_uid from public.staff
   where role = 'Admin' and active and user_id is not null order by created_at limit 1;
  select id, user_id into v_js, v_js_uid from public.staff
   where role = 'Job Search' and active and user_id is not null order by created_at limit 1;

  insert into public.clients (name, stage, status, assigned_staff_id, phone, email)
  values ('ZZ Portal Msg A', 'Job Coaching', 'Active', v_admin, '(801) 555-0111', 'zz-msg-a@example.test') returning id into v_client_a;
  insert into public.clients (name, stage, status, assigned_staff_id, phone, email)
  values ('ZZ Portal Msg B', 'Job Coaching', 'Active', v_admin, '(801) 555-0112', 'zz-msg-b@example.test') returning id into v_client_b;
  insert into public.portal_accounts (client_id, kind, name, phone, email)
  values (v_client_a, 'Client', 'ZZ Portal Msg A', '+18015550111', 'zz-msg-a@example.test') returning id into v_acct_a;
  insert into public.portal_accounts (client_id, kind, name, phone, email)
  values (v_client_b, 'Client', 'ZZ Portal Msg B', '+18015550112', 'zz-msg-b@example.test') returning id into v_acct_b;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_user_a, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'p-' || v_acct_a || '@portal.zionvocrehab.com', '{}', '{}', now(), now()),
         (v_user_b, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'p-' || v_acct_b || '@portal.zionvocrehab.com', '{}', '{}', now(), now());
  insert into public.portal_sessions (id, account_id, auth_user_id) values (v_sess_a, v_acct_a, v_user_a), (v_sess_b, v_acct_b, v_user_b);

  -- ── client A, before agreeing ──────────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_user_a, 'role', 'authenticated', 'session_id', v_sess_a)::text, true);
  begin
    perform public.portal_send_message('ZZ before consent');
    failures := failures || 'FAILED: a client wrote before agreeing to the terms'::text;
  exception when insufficient_privilege then
    raise notice 'ok  nobody writes before agreeing to the current terms';
  end;

  perform public.portal_record_consent('Electronic communication', true, '203.0.113.1', 'zz-agent');
  perform public.portal_send_message('ZZ hello from A');
  if (select count(*) from public.portal_my_messages()) <> 1 then
    failures := failures || 'FAILED: a client could not read their own message'::text;
  end if;
  begin
    perform public.portal_send_message(repeat('x', 2001));
    failures := failures || 'FAILED: a message over 2,000 characters was taken'::text;
  exception when check_violation then null;
  end;
  begin
    perform public.portal_set_notice_channel('Text');
    failures := failures || 'FAILED: a client chose text alerts with no texting consent on record'::text;
  exception when check_violation then
    raise notice 'ok  text alerts need texting consent on the client''s own number';
  end;
  perform public.portal_set_notice_channel('Email');

  -- ── client B sees nothing of A's ───────────────────────────
  perform set_config('request.jwt.claims', json_build_object('sub', v_user_b, 'role', 'authenticated', 'session_id', v_sess_b)::text, true);
  perform public.portal_record_consent('Electronic communication', true, '203.0.113.2', 'zz-agent');
  if (select count(*) from public.portal_my_messages()) <> 0 or public.portal_unread() <> 0 then
    failures := failures || 'FAILED: one client saw another client''s portal messages'::text;
  else
    raise notice 'ok  a client sees only their own thread';
  end if;
  if exists (select 1 from public.conversations where kind = 'portal') then
    failures := failures || 'FAILED: a portal client read the conversations table'::text;
  end if;

  perform set_config('role', 'postgres', true);
  select id into v_conv from public.conversations where kind = 'portal' and portal_account_id = v_acct_a;
  if v_conv is null or (select assigned_staff_id from public.conversations where id = v_conv) is distinct from v_admin then
    failures := failures || 'FAILED: the thread was not made for the account, with the client''s staff member'::text;
  end if;

  -- ── staff who do not manage this client's portal ───────────
  if v_js_uid is not null then
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', v_js_uid, 'role', 'authenticated')::text, true);
    if exists (select 1 from public.conversations where id = v_conv)
       or exists (select 1 from public.messages where conversation_id = v_conv)
       or exists (select 1 from public.message_inbox('open') where conversation_id = v_conv) then
      failures := failures || 'FAILED: staff who do not manage this client read the portal thread'::text;
    end if;
    begin
      perform public.post_portal_reply(v_conv, 'ZZ not mine');
      failures := failures || 'FAILED: staff who do not manage this client answered the portal thread'::text;
    exception when insufficient_privilege then
      raise notice 'ok  only Admin, Reports and the assigned staff member read and answer a portal thread';
    end;
    perform set_config('role', 'postgres', true);
  else
    raise notice 'skip  no active Job Search staff member to try the read rule as';
  end if;

  -- ── the assigned staff member answers ──────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);
  if not exists (select 1 from public.message_inbox('portal') where conversation_id = v_conv and unread = 1) then
    failures := failures || 'FAILED: the client''s message is not in the inbox as unread'::text;
  end if;
  perform public.post_portal_reply(v_conv, 'ZZ reply from staff');

  -- Not signed in yet: skipped, and that does not use up the hour.
  if exists (select 1 from public.portal_claim_notice(v_conv)) then
    failures := failures || 'FAILED: a notice went to somebody who has never signed in'::text;
  end if;
  perform set_config('role', 'postgres', true);
  update public.portal_accounts set first_signed_in_at = now() where id = v_acct_a;
  perform set_config('role', 'authenticated', true);
  select c.channel into v_ch from public.portal_claim_notice(v_conv) c;
  if v_ch is distinct from 'Email' then
    failures := failures || format('FAILED: the first notice went by %s, not the email the client chose', coalesce(v_ch, 'nothing'))::text;
  end if;
  if exists (select 1 from public.portal_claim_notice(v_conv)) then
    failures := failures || 'FAILED: a second notice went within the hour'::text;
  else
    raise notice 'ok  one notice an hour, and only once they have signed in';
  end if;

  -- ── the client reads it ────────────────────────────────────
  perform set_config('request.jwt.claims', json_build_object('sub', v_user_a, 'role', 'authenticated', 'session_id', v_sess_a)::text, true);
  if public.portal_unread() <> 1 then
    failures := failures || 'FAILED: the staff reply is not unread for the client'::text;
  end if;
  select max(seq) into v_n from public.portal_my_messages();
  perform public.portal_mark_read(v_n);
  if public.portal_unread() <> 0 then
    failures := failures || 'FAILED: reading the thread did not clear what was new'::text;
  else
    raise notice 'ok  the client sees the reply as new until they read it';
  end if;
  perform set_config('role', 'postgres', true);

  -- ── shape and privilege ────────────────────────────────────
  begin
    insert into public.conversations (kind, title, client_id) values ('portal', 'ZZ', v_client_a);
    failures := failures || 'FAILED: a portal conversation was made with no account'::text;
  exception when check_violation then null;
  end;
  begin
    insert into public.conversations (kind, title, client_id, portal_account_id) values ('portal', 'ZZ', v_client_a, v_acct_a);
    failures := failures || 'FAILED: a second portal thread was made for one account'::text;
  exception when unique_violation then
    raise notice 'ok  one thread per account, and every portal thread has one';
  end;
  if has_function_privilege('authenticated', 'public.portal_thread_for(uuid)', 'execute')
     or has_function_privilege('anon', 'public.portal_send_message(text)', 'execute')
     or has_function_privilege('anon', 'public.post_portal_reply(uuid, text)', 'execute') then
    failures := failures || 'FAILED: a portal function can be called by somebody it is not for'::text;
  else
    raise notice 'ok  nobody signed out calls a portal message function';
  end if;

  -- ── USOR clients only (0227) ───────────────────────────────
  begin
    update public.clients set funding_source = 'Private Pay' where id = v_client_b;
    insert into public.portal_accounts (client_id, kind, name, email) values (v_client_b, 'Client', 'ZZ again', 'zz-again@example.test');
    failures := failures || 'FAILED: a portal account was made for a client not funded by Utah VR'::text;
  exception when check_violation then null;
  end;
  update public.clients set funding_source = 'Private Pay' where id = v_client_a;
  if (select disabled_at from public.portal_accounts where id = v_acct_a) is null
     or exists (select 1 from public.portal_sessions where id = v_sess_a and ended_at is null) then
    failures := failures || 'FAILED: a client moved off Utah VR kept portal access'::text;
  else
    raise notice 'ok  the portal is for Utah VR clients only, and closes when that changes';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception E'\n%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- PORTAL MESSAGES VERIFIED ---';
end;
$$;

rollback;
