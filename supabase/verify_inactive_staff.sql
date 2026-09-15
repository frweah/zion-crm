-- Zion Vocational Rehab CRM — an inactive member of staff's record is read-only
--
-- What has to hold, each tried from the direction that would break it:
--
--   Once somebody is inactive, nobody - Admin included - can add, change or
--   remove their pay rates, credentials, training, documents, employment
--   details or onboarding checklist. All of it can still be read.
--
--   The offboarding checklist stays open, because it is finished after the
--   person has gone.
--
--   Reactivating them reopens the record.
--
-- Runs inside a transaction that is rolled back. Nothing here is left behind.

begin;

do $$
declare
  v_adm_uid   uuid;
  v_person    uuid;
  v_file      uuid;
  v_cat       text;
  v_type      text;
  v_onboard   uuid;
  v_offboard  uuid;
  v_since     timestamptz;
  v_count     int;
  failures    text[] := '{}';
begin
  select user_id into v_adm_uid from public.staff where role = 'Admin' and active order by created_at limit 1;
  select key into v_cat from public.staff_file_categories where not system_only order by sort_order limit 1;
  select key into v_type from public.credential_types where active and kind <> 'hours' order by sort_order limit 1;
  select id into v_onboard from public.checklist_tasks where phase = 'Onboarding' and auto_key is null order by sort_order limit 1;
  select id into v_offboard from public.checklist_tasks where phase = 'Offboarding' and auto_key is null order by sort_order limit 1;

  -- Somebody with a record, while they still work here.
  insert into public.staff (name, email, role, active)
  values ('ZZ Leaver', 'zz-leaver@example.test', 'Job Search', true) returning id into v_person;
  insert into public.staff_pay (staff_id, pay_rate, rate_unit, effective_from, note)
  values (v_person, 20, 'Hourly', date '2026-01-01', 'ZZ test rate');
  insert into public.staff_files (staff_id, storage_path, filename, mime_type, size_bytes, category, note)
  values (v_person, 'zz/leaver.pdf', 'leaver.pdf', 'application/pdf', 10, v_cat, 'ZZ test file') returning id into v_file;

  -- They leave.
  update public.staff set active = false where id = v_person;
  select deactivated_at into v_since from public.staff where id = v_person;
  if v_since is null then
    failures := failures || 'FAILED: deactivating somebody did not record when'::text;
  end if;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);

  -- ── nothing on the record changes, even for Admin ──────────
  begin
    perform public.set_staff_pay(v_person, 25, 'Hourly', date '2026-09-01', 'raise');
    failures := failures || 'FAILED: a pay rate was added for somebody inactive'::text;
  exception when insufficient_privilege then
    raise notice 'ok  no pay rate can be added once somebody is inactive';
  end;

  begin
    insert into public.staff_credentials (staff_id, type_key, issued_on) values (v_person, v_type, date '2026-09-01');
    failures := failures || 'FAILED: a credential was recorded for somebody inactive'::text;
  exception when insufficient_privilege then
    raise notice 'ok  no credential can be recorded';
  end;

  begin
    insert into public.ce_entries (staff_id, on_date, hours, topic) values (v_person, date '2026-09-01', 1, 'ZZ');
    failures := failures || 'FAILED: training hours were logged for somebody inactive'::text;
  exception when insufficient_privilege then
    raise notice 'ok  no training can be logged';
  end;

  begin
    delete from public.staff_files where id = v_file;
    failures := failures || 'FAILED: a document was removed from an inactive record'::text;
  exception when insufficient_privilege then
    raise notice 'ok  no document can be removed from their file';
  end;

  begin
    insert into public.staff_employment (staff_id, transports_clients) values (v_person, true);
    failures := failures || 'FAILED: employment details were changed for somebody inactive'::text;
  exception when insufficient_privilege then
    raise notice 'ok  their employment details cannot be changed';
  end;

  if v_onboard is not null then
    begin
      perform public.set_checklist_item(v_person, v_onboard, true, '');
      failures := failures || 'FAILED: an onboarding item was ticked for somebody inactive'::text;
    exception when insufficient_privilege then
      raise notice 'ok  the onboarding checklist cannot be changed';
    end;
  end if;

  -- ── but offboarding can be finished ────────────────────────
  if v_offboard is not null then
    begin
      perform public.set_checklist_item(v_person, v_offboard, true, 'returned');
      raise notice 'ok  the offboarding checklist can still be completed after they have gone';
    exception when others then
      failures := failures || format('FAILED: an offboarding item could not be ticked: %s', sqlerrm)::text;
    end;
  end if;

  -- ── the stored file is held as well as its row ─────────────
  -- Storage deletes go through the storage service, so the policy is checked
  -- here as written: Admin may delete a staff file only outside an inactive
  -- person's folder.
  if not exists (
    select 1 from pg_policies
     where schemaname = 'storage' and tablename = 'objects'
       and policyname = 'zion delete staff files' and cmd = 'DELETE'
       and qual ilike '%staff-files%' and qual ilike '%is_admin()%'
       and qual ilike '%foldername%' and qual ilike '%active%'
  ) then
    failures := failures || 'FAILED: an inactive person''s stored documents can still be deleted directly from storage'::text;
  else
    raise notice 'ok  their stored files cannot be deleted from storage either';
  end if;

  -- ── and everything still reads ─────────────────────────────
  select count(*) into v_count from public.staff_pay where staff_id = v_person;
  if v_count <> 1 or not exists (select 1 from public.staff_files where id = v_file) then
    failures := failures || 'FAILED: an inactive record could not be read in full'::text;
  else
    raise notice 'ok  their pay history and documents are still there to read';
  end if;

  -- ── reactivating reopens it ────────────────────────────────
  perform set_config('role', 'postgres', true);
  update public.staff set active = true where id = v_person;
  perform set_config('role', 'authenticated', true);
  begin
    perform public.set_staff_pay(v_person, 25, 'Hourly', date '2026-09-01', 'back');
    raise notice 'ok  reactivating somebody reopens their record';
  exception when others then
    failures := failures || format('FAILED: a reactivated record stayed frozen: %s', sqlerrm)::text;
  end;

  perform set_config('request.jwt.claims', '', true);

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- INACTIVE STAFF RECORDS VERIFIED ---';
end $$;

rollback;
