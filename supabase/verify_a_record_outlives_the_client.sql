-- A record outlives the client (0289)
--
-- What has to hold:
--
--   A client can be deleted with a consent record, a document log, and portal
--   activity and consents on them. Before this, any one of the four refused
--   it, and between them they covered every client who had ever been texted or
--   had a single file on their record.
--
--   Every one of those records is still there afterwards, whole, with only its
--   pointer to the client emptied. The consent row keeps the phone number, the
--   state, the method and the date - that is the practice's proof under the
--   TCPA that it was allowed to text somebody, and a deleted client does not
--   make it untrue.
--
--   And the carve-out is only ever a detach. A log row cannot be edited, moved
--   to another client, given a pointer it never had, or deleted, by anybody.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_uid uuid := gen_random_uuid();
  v_admin uuid; v_client uuid; v_other uuid; v_portal uuid;
  v_consent uuid; v_event uuid; v_act uuid; v_pc uuid;
  v_phone text := '+13850000795';
  r record;
  failures text[] := '{}';
begin
  insert into public.staff (name, email, role, active)
  values ('ZZ Outlive Admin', 'zz-outlive@example.test', 'Admin', true) returning id into v_admin;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-outlive@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_uid where id = v_admin;

  insert into public.clients (name, stage, status, phone)
  values ('ZZ Outlive Testperson', 'Job Search', 'Active', v_phone) returning id into v_client;
  insert into public.clients (name, stage, status)
  values ('ZZ Outlive Other', 'Job Search', 'Active') returning id into v_other;

  -- Everything that used to refuse the delete, on one client.
  insert into public.sms_consent_events (client_id, state, phone, method, note)
  values (v_client, 'Granted', v_phone, 'Intake form', 'ZQ agreed at intake')
  returning id into v_consent;

  insert into public.attachments (client_id, storage_path, filename, mime_type, size_bytes, category)
  values (v_client, v_client::text || '/zq.pdf', 'zq.pdf', 'application/pdf', 10,
          (select category from public.attachments limit 1));
  select id into v_event from public.client_document_events
   where client_id = v_client order by at desc limit 1;
  if v_event is null then
    failures := failures || 'FAILED: filing a document wrote nothing to the document log, so this proves nothing'::text;
  end if;

  insert into public.portal_activity (client_id, action, detail, ip, acting_as, actor_name)
  values (v_client, 'Signed in', '', '', 'Client', 'ZQ') returning id into v_act;

  insert into public.portal_accounts (client_id, name, email, kind)
  values (v_client, 'ZQ Portal', 'zq-outlive-portal@example.test', 'Client') returning id into v_portal;
  insert into public.portal_consents (account_id, client_id, terms_version, kind, given,
                                      ip, user_agent, acting_as, actor_name)
  values (v_portal, v_client,
          (select version from public.portal_terms order by created_at desc limit 1),
          'Text messages', true, '', '', 'Client', 'ZQ')
  returning id into v_pc;

  -- ── the delete goes through ───────────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
  begin
    perform public.delete_client(v_client, 'ZQ verifying that the records outlive them');
  exception when others then
    failures := failures || format('FAILED: the client could not be deleted - %s', sqlerrm)::text;
  end;
  perform set_config('role', 'postgres', true);

  if exists (select 1 from public.clients where id = v_client) then
    failures := failures || 'FAILED: the client is still on file'::text;
  elsif array_length(failures, 1) is null then
    raise notice 'ok  a client with consent, a document log and portal records can be deleted';
  end if;

  -- ── and every record is still there, whole ────────────────
  select * into r from public.sms_consent_events where id = v_consent;
  if r.id is null then
    failures := failures || 'FAILED: the consent record went with the client, so the practice cannot show it was allowed to text them'::text;
  elsif r.client_id is not null then
    failures := failures || 'FAILED: the consent record still points at a client who is gone'::text;
  elsif r.phone <> v_phone or r.state <> 'Granted' or r.method <> 'Intake form' then
    failures := failures || 'FAILED: the consent record lost what it was about'::text;
  else
    raise notice 'ok  the consent record stays, with the number, the state and the method it was given with';
  end if;

  if v_event is not null then
    select * into r from public.client_document_events where id = v_event;
    if r.id is null then
      failures := failures || 'FAILED: the document log went with the client'::text;
    elsif r.client_id is not null then
      failures := failures || 'FAILED: the document log still points at a client who is gone'::text;
    else
      raise notice 'ok  and the document log stays, with its pointer emptied';
    end if;
  end if;

  select * into r from public.portal_activity where id = v_act;
  if r.id is null then
    failures := failures || 'FAILED: the portal activity log went with the client'::text;
  elsif r.client_id is not null then
    failures := failures || 'FAILED: the portal activity log still points at a client who is gone'::text;
  else
    raise notice 'ok  and the portal activity log stays';
  end if;

  select * into r from public.portal_consents where id = v_pc;
  if r.id is null then
    failures := failures || 'FAILED: the portal consent went with the client'::text;
  elsif r.client_id is not null or r.account_id is not null then
    failures := failures || 'FAILED: the portal consent still points at something that is gone'::text;
  elsif r.given is not true or r.kind <> 'Text messages' then
    failures := failures || 'FAILED: the portal consent lost what was agreed'::text;
  else
    raise notice 'ok  and what somebody agreed to on the portal stays, with what they agreed to';
  end if;

  -- ── and the carve-out is only ever a detach ───────────────
  -- The fault put back is each of these in turn: a guard that let any of them
  -- through would be a log anybody could rewrite.
  begin
    update public.sms_consent_events set note = 'ZQ rewritten' where id = v_consent;
    failures := failures || 'FAILED: a consent record can be edited'::text;
  exception when check_violation then null;
  end;

  begin
    update public.sms_consent_events set client_id = v_other where id = v_consent;
    failures := failures || 'FAILED: a consent record can be moved onto another client'::text;
  exception when check_violation then null;
  end;

  begin
    delete from public.sms_consent_events where id = v_consent;
    failures := failures || 'FAILED: a consent record can be deleted'::text;
  exception when check_violation then null;
  end;

  begin
    update public.client_document_events set client_id = v_other where id = v_event;
    failures := failures || 'FAILED: a document log row can be moved onto another client'::text;
  exception when insufficient_privilege then null;
  end;

  begin
    update public.portal_activity set client_id = v_other where id = v_act;
    failures := failures || 'FAILED: a portal activity row can be moved onto another client'::text;
  exception when insufficient_privilege then null;
  end;

  if array_length(failures, 1) is null then
    raise notice 'ok  and none of them can be edited, moved to another client, or removed';
  end if;

  -- A client who is still there is not a detach either: emptying a pointer is
  -- allowed only because the client has gone.
  insert into public.sms_consent_events (client_id, state, phone, method, note)
  values (v_other, 'Granted', '+13850000796', 'Intake form', 'ZQ still here')
  returning id into v_consent;
  begin
    update public.sms_consent_events set client_id = null where id = v_consent;
    failures := failures || 'FAILED: a consent record was detached from a client who is still on file'::text;
  exception when check_violation then
    raise notice 'ok  and a pointer cannot be emptied while the client is still there';
  end;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- RECORDS OUTLIVE THE CLIENT VERIFIED ---';
end $$;

rollback;
