-- Zion Vocational Rehab CRM — a warrant stub is never settled from the inbox
--
-- What has to hold, each tried from the direction that would break it:
--
--   A document read as a warrant cannot be filed, set aside or reclassified
--   by a person in the document inbox, whatever their role. It leaves the
--   inbox only through the warrant pipeline, which runs as the service role
--   after every line on it has been checked.
--
--   Saying whose folder it came from is still a person's to do.
--
-- Runs inside a transaction that is rolled back. Nothing here is left behind.

begin;

do $$
declare
  v_adm_uid uuid;
  v_doc     uuid;
  v_state   text;
  failures  text[] := '{}';
begin
  select user_id into v_adm_uid from public.staff where role = 'Admin' and active order by created_at limit 1;

  insert into public.inbox_documents (sha256, folder_name, relative_path, filename, kind, proposal)
  values (repeat('e', 64), 'ZZ Warrant Folder', 'ZZ Warrant Folder/stub.pdf', 'stub.pdf', 'Warrant',
          '{"action": "Read as a warrant", "needs": "the warrant pipeline"}')
  returning id into v_doc;

  -- ── a person, even Admin ──────────────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);

  begin
    update public.inbox_documents set state = 'Filed', outcome = 'Matched to an invoice' where id = v_doc;
    failures := failures || 'FAILED: Admin filed a warrant stub from the inbox'::text;
  exception when insufficient_privilege then
    raise notice 'ok  a warrant stub cannot be filed from the inbox, even by Admin';
  end;

  begin
    update public.inbox_documents set state = 'Ignored', outcome = 'set aside' where id = v_doc;
    failures := failures || 'FAILED: a warrant stub was set aside from the inbox'::text;
  exception when insufficient_privilege then
    raise notice 'ok  a warrant stub cannot be set aside from the inbox';
  end;

  begin
    update public.inbox_documents set kind = 'Other' where id = v_doc;
    failures := failures || 'FAILED: a warrant stub was reclassified from the inbox, past the warrant checks'::text;
  exception when insufficient_privilege then
    raise notice 'ok  a warrant stub cannot be called something else to get it past the checks';
  end;

  begin
    update public.inbox_documents set folder_name = 'ZZ Warrant Folder' where id = v_doc;
    raise notice 'ok  saying whose folder it came from is still allowed';
  exception when others then
    failures := failures || format('FAILED: an ordinary change to a warrant stub was refused: %s', sqlerrm)::text;
  end;

  -- ── the warrant pipeline ──────────────────────────────────
  perform set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
  perform set_config('role', 'service_role', true);

  update public.inbox_documents
     set state = 'Filed', decided_at = now(), outcome = 'Read as a warrant on Billing → Warrants'
   where id = v_doc;
  select state into v_state from public.inbox_documents where id = v_doc;
  if v_state is distinct from 'Filed' then
    failures := failures || 'FAILED: the warrant pipeline could not close the stub in the inbox'::text;
  else
    raise notice 'ok  the warrant pipeline closes the stub once it has read it';
  end if;

  perform set_config('request.jwt.claims', '', true);

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- WARRANT ROUTING VERIFIED ---';
end $$;

rollback;
