-- Zion Vocational Rehab CRM — the editable directory, and its log
--
-- What has to hold, each tried from the direction that would break it:
--
--   Adding, editing and removing a counselor, a billing office or an office
--   is written to the log by the database - who, when, which fields from what
--   to what - however the change was made. A save that changes nothing adds
--   nothing. The log is never edited or deleted.
--
--   Moving office needs a reason, a real office and a different one; it is
--   logged as "Moved office" with the reason, and the billing office follows
--   the office. Somebody who may not edit counselors cannot move one.
--
--   Billing offices and offices are edited by those with Billing to edit -
--   Admin and the Billing role among them - and by nobody else.
--
-- Uses made-up staff (ZZ). Runs inside a transaction that is rolled back.

begin;

do $$
declare
  v_admin     uuid;
  v_adm_uid   uuid;
  v_rep       uuid;
  v_rep_uid   uuid := gen_random_uuid();
  v_bil       uuid;
  v_bil_uid   uuid := gen_random_uuid();
  v_k         uuid;
  v_client    uuid;
  v_before    bigint;
  v_n         bigint;
  r           record;
  v_move      record;
  v_dt        uuid;
  failures    text[] := '{}';
begin
  select id, user_id into v_admin, v_adm_uid from public.staff
   where role = 'Admin' and active and user_id is not null order by created_at, id limit 1;
  select id into v_dt from public.billing_offices where name = 'Downtown CRP';

  insert into public.staff (name, email, role, active) values ('ZZ Dir Reports', 'zz-dir-reports@example.test', 'Reports', true) returning id into v_rep;
  insert into public.staff (name, email, role, active) values ('ZZ Dir Billing', 'zz-dir-billing@example.test', 'Billing', true) returning id into v_bil;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_rep_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-dir-reports@example.test', '{}', '{}', now(), now()),
         (v_bil_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-dir-billing@example.test', '{}', '{}', now(), now());

  perform set_config('role', 'authenticated', true);

  -- ── adding and editing a counselor is logged ───────────────
  perform set_config('request.jwt.claims', json_build_object('sub', v_bil_uid, 'role', 'authenticated')::text, true);
  insert into public.counselors (name, office, email) values ('ZZ Dir Counselor', 'Salt Lake City', 'zz-dir@example.test')
  returning id into v_k;

  if not exists (select 1 from public.directory_changes
                  where entity = 'Counselor' and entity_key = v_k::text and action = 'Added'
                    and changed_by = v_bil and changed_by_name = 'ZZ Dir Billing') then
    failures := failures || 'FAILED: adding a counselor was not logged with who did it'::text;
  end if;

  update public.counselors set phone = '801-555-0199' where id = v_k;
  if not exists (select 1 from public.directory_changes
                  where entity_key = v_k::text and action = 'Edited'
                    and changes -> 'phone' ->> 'to' = '801-555-0199' and (changes -> 'phone' -> 'from') = 'null'::jsonb) then
    failures := failures || 'FAILED: an edit was not logged with the field, from and to'::text;
  end if;

  select count(*) into v_before from public.directory_changes where entity_key = v_k::text;
  update public.counselors set phone = '801-555-0199' where id = v_k;
  if (select count(*) from public.directory_changes where entity_key = v_k::text) <> v_before then
    failures := failures || 'FAILED: a save that changed nothing was logged'::text;
  else
    raise notice 'ok  adding and editing a counselor is logged - who, the field, from and to - and a save that changes nothing is not';
  end if;

  -- ── moving office ──────────────────────────────────────────
  perform set_config('role', 'postgres', true);
  insert into public.clients (name, stage, status, assigned_staff_id, counselor_id)
  values ('ZZ Dir Client', 'Job Coaching', 'Active', v_admin, v_k) returning id into v_client;
  perform set_config('role', 'authenticated', true);

  begin
    perform public.move_counselor_office(v_k, 'Taylorsville', '  ');
    failures := failures || 'FAILED: a counselor moved office with no reason'::text;
  exception when check_violation then null;
  end;
  begin
    perform public.move_counselor_office(v_k, 'Salt Lake City', 'ZZ same');
    failures := failures || 'FAILED: a counselor was moved to the office they are in'::text;
  exception when check_violation then null;
  end;
  begin
    perform public.move_counselor_office(v_k, 'ZZ Nowhere', 'ZZ nowhere');
    failures := failures || 'FAILED: a counselor was moved to an office that is not on file'::text;
  exception when check_violation then null;
  end;

  select * into v_move from public.move_counselor_office(v_k, 'Taylorsville', 'ZZ moved to the Taylorsville office');
  if v_move.from_office <> 'Salt Lake City' or v_move.to_office <> 'Taylorsville'
     or v_move.from_billing <> 'Downtown CRP' or v_move.to_billing <> 'Valley West CRP' or v_move.clients <> 1 then
    failures := failures || format('FAILED: the move reported %s', row_to_json(v_move))::text;
  end if;
  if (select billing_office from public.client_billing_office where client_id = v_client) <> 'Valley West CRP' then
    failures := failures || 'FAILED: moving office did not move the counselor''s clients to the new billing office'::text;
  end if;
  if not exists (select 1 from public.directory_changes
                  where entity_key = v_k::text and action = 'Moved office' and reason = 'ZZ moved to the Taylorsville office'
                    and changes -> 'office' ->> 'from' = 'Salt Lake City' and changes -> 'office' ->> 'to' = 'Taylorsville') then
    failures := failures || 'FAILED: a move was not logged as Moved office, with the reason and both offices'::text;
  else
    raise notice 'ok  moving office needs a reason and a real, different office; it is logged as a move and the billing office follows';
  end if;

  update public.counselors set notes = 'ZZ after the move' where id = v_k;
  if (select action from public.directory_changes where entity_key = v_k::text order by seq desc limit 1) <> 'Edited'
     or (select reason from public.directory_changes where entity_key = v_k::text order by seq desc limit 1) <> '' then
    failures := failures || 'FAILED: an ordinary edit after a move was logged as a move'::text;
  end if;

  -- Somebody who may not edit counselors cannot move one.
  perform set_config('request.jwt.claims', json_build_object('sub', v_rep_uid, 'role', 'authenticated')::text, true);
  begin
    perform public.move_counselor_office(v_k, 'Centerville', 'ZZ not theirs');
    failures := failures || 'FAILED: somebody without Counselors to edit moved a counselor'::text;
  exception when insufficient_privilege then
    raise notice 'ok  somebody who may not edit counselors cannot move one';
  end;

  -- ── billing offices and offices ────────────────────────────
  update public.billing_offices set contact_title = 'ZZ refused' where id = v_dt;
  perform set_config('role', 'postgres', true);
  if (select contact_title from public.billing_offices where id = v_dt) = 'ZZ refused' then
    failures := failures || 'FAILED: somebody without Billing changed a billing office'::text;
  end if;
  perform set_config('role', 'authenticated', true);

  perform set_config('request.jwt.claims', json_build_object('sub', v_bil_uid, 'role', 'authenticated')::text, true);
  update public.billing_offices set contact_title = 'ZZ by Billing' where id = v_dt;
  update public.offices set note = 'ZZ office note' where name = 'Centerville';
  perform set_config('role', 'postgres', true);
  if (select contact_title from public.billing_offices where id = v_dt) <> 'ZZ by Billing' then
    failures := failures || 'FAILED: the Billing role could not edit a billing office'::text;
  elsif not exists (select 1 from public.directory_changes
                     where entity = 'Billing office' and entity_key = v_dt::text and changed_by = v_bil
                       and changes -> 'contact_title' ->> 'to' = 'ZZ by Billing')
     or not exists (select 1 from public.directory_changes
                     where entity = 'Office' and entity_key = 'Centerville' and changed_by = v_bil
                       and changes -> 'note' ->> 'to' = 'ZZ office note') then
    failures := failures || 'FAILED: a change to a billing office or an office was not logged'::text;
  else
    raise notice 'ok  Billing edits billing offices and offices, nobody without Billing does, and both are logged';
  end if;

  -- ── the log is a record ────────────────────────────────────
  begin
    update public.directory_changes set reason = 'ZZ rewritten' where entity_key = v_k::text;
    failures := failures || 'FAILED: the directory log was changed'::text;
  exception when insufficient_privilege then null;
  end;
  begin
    delete from public.directory_changes where entity_key = v_k::text;
    failures := failures || 'FAILED: the directory log was deleted from'::text;
  exception when insufficient_privilege then null;
  end;
  perform set_config('role', 'authenticated', true);
  begin
    insert into public.directory_changes (entity, entity_key, entity_name, action) values ('Counselor', 'x', 'ZZ', 'Edited');
    failures := failures || 'FAILED: somebody wrote to the directory log by hand'::text;
  exception when insufficient_privilege then
    raise notice 'ok  the log is written by the database alone, and never changed or deleted';
  end;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('role', 'postgres', true);

  if has_table_privilege('anon', 'public.directory_changes', 'select')
     or has_function_privilege('anon', 'public.move_counselor_office(uuid, text, text)', 'execute') then
    failures := failures || 'FAILED: somebody not signed in can read the log or move a counselor'::text;
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- DIRECTORY CHANGES VERIFIED ---';
end $$;

rollback;
