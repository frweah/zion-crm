-- Zion Vocational Rehab CRM — a person's own papers (0198)
--
-- Melanie could not upload her ID, and the reason was that only an Admin
-- could *read* this bucket: the storage service inserts with RETURNING, and
-- RETURNING applies the select policy to the row being written. So the fix is
-- a read policy, and the test has to be the write - which is the whole reason
-- this file exists rather than a line in verify_onboarding.sql.
--
-- What has to hold, each tried from the direction that would break it:
--
--   Every one of the six roles can upload into its own folder, and read back
--   what it wrote. Every role, because the fault looked like a Billing fault
--   and was not: it was every role except Admin, and a test that only tried
--   Billing would have passed the day before the bug was reported.
--
--   All three path shapes the bucket holds resolve to their owner, and a
--   shape that names nobody resolves to nobody.
--
--   No role can read or write another person's folder. An Admin can do both,
--   because the owner asked for an Admin to act on somebody's behalf.
--
--   A document can be replaced, which had no policy at all.
--
--   A document on the record of somebody no longer active reads as frozen to
--   the delete policy, and one on a live record does not. The policy this
--   replaced asked the question about the staff member's *name* instead of
--   the object's, so it had never once applied. Storage refuses a direct
--   DELETE from SQL, so what is checked here is the expression the policy is
--   made of rather than the deletion itself - stated plainly, because a test
--   that cannot do the thing it describes should say so.
--
-- Uses made-up staff (ZZ). Everything is rolled back.

begin;

do $$
declare
  k_roles  constant text[] := array['Admin', 'Job Search', 'Reports', 'Billing', 'Job Coach', 'Case Manager'];
  v_role   text;
  v_staff  uuid;
  v_uid    uuid;
  v_other  uuid;
  v_oth_s  uuid;
  v_gone   uuid;
  v_n      integer;
  v_path   text;
  failures text[] := '{}';
begin
  -- Somebody else's folder, to try the walls against.
  insert into public.staff (name, email, role, active)
  values ('ZZ Files Bystander', 'zz-files-bystander@example.test', 'Job Coach', true)
  returning id into v_oth_s;
  v_other := gen_random_uuid();
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_other, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-files-bystander@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_other where id = v_oth_s;
  insert into storage.objects (bucket_id, name)
  values ('staff-files', v_oth_s::text || '/zz-theirs.pdf');

  -- ── which path belongs to whom ─────────────────────────────
  if public.staff_file_owner(v_oth_s::text || '/scan.pdf') is distinct from v_oth_s
     or public.staff_file_owner('staff/' || v_oth_s::text || '/w9-x.pdf') is distinct from v_oth_s
     or public.staff_file_owner('signatures/' || v_oth_s::text || '.jpg') is distinct from v_oth_s then
    failures := failures || 'FAILED: one of the three path shapes does not resolve to its owner'::text;
  else
    raise notice 'ok  all three path shapes in this bucket resolve to the person they belong to';
  end if;

  if public.staff_file_owner('something/else.pdf') is not null
     or public.staff_file_owner('') is not null
     or public.staff_file_owner(null) is not null then
    failures := failures || 'FAILED: a path naming nobody resolved to somebody'::text;
  else
    raise notice 'ok  and a path that names nobody resolves to nobody, so a new shape fails closed';
  end if;

  -- ── every role, into its own folder ────────────────────────
  foreach v_role in array k_roles loop
    insert into public.staff (name, email, role, active)
    values (format('ZZ Files %s', v_role), format('zz-files-%s@example.test', lower(replace(v_role, ' ', '-'))), v_role, true)
    returning id into v_staff;
    v_uid := gen_random_uuid();
    insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    values (v_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            format('zz-files-%s@example.test', lower(replace(v_role, ' ', '-'))), '{}', '{}', now(), now());
    update public.staff set user_id = v_uid where id = v_staff;

    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);

    -- RETURNING on purpose: it is what the storage service does, and it is
    -- what the missing read policy refused.
    v_path := v_staff::text || '/1790000000000-zz-id.jpg';
    begin
      insert into storage.objects (bucket_id, name) values ('staff-files', v_path)
      returning id into v_uid;
      raise notice 'ok  % can upload into their own folder and read it back', v_role;
    exception when others then
      failures := failures || format('FAILED: %s cannot upload their own ID: %s', v_role, sqlerrm)::text;
    end;

    select count(*) into v_n from storage.objects
     where bucket_id = 'staff-files' and name = v_path;
    if v_n <> 1 then
      failures := failures || format('FAILED: %s cannot see the file they just uploaded', v_role)::text;
    end if;

    -- Replacing it, which had no policy at all before 0198.
    begin
      update storage.objects set updated_at = now()
       where bucket_id = 'staff-files' and name = v_path;
      if not found then
        failures := failures || format('FAILED: %s could not replace their own document', v_role)::text;
      end if;
    exception when others then
      failures := failures || format('FAILED: %s could not replace their own document: %s', v_role, sqlerrm)::text;
    end;

    -- And not into anybody else's.
    begin
      insert into storage.objects (bucket_id, name)
      values ('staff-files', v_oth_s::text || '/zz-sneak.pdf') returning id into v_uid;
      if v_role <> 'Admin' then
        failures := failures || format('FAILED: %s wrote into somebody else''s folder', v_role)::text;
      else
        raise notice 'ok  and an Admin may write into anybody''s, which is acting on their behalf';
      end if;
    exception when others then
      if v_role = 'Admin' then
        failures := failures || format('FAILED: an Admin could not upload on somebody''s behalf: %s', sqlerrm)::text;
      end if;
    end;

    select count(*) into v_n from storage.objects
     where bucket_id = 'staff-files' and name = v_oth_s::text || '/zz-theirs.pdf';
    if v_role = 'Admin' and v_n <> 1 then
      failures := failures || 'FAILED: an Admin cannot read somebody''s document'::text;
    elsif v_role <> 'Admin' and v_n <> 0 then
      failures := failures || format('FAILED: %s can read somebody else''s document', v_role)::text;
    end if;

    perform set_config('request.jwt.claims', '', true);
    perform set_config('role', 'postgres', true);
  end loop;
  raise notice 'ok  and nobody but an Admin can read or write another person''s folder';

  -- ── the freeze on a record no longer active ────────────────
  insert into public.staff (name, email, role, active)
  values ('ZZ Files Departed', 'zz-files-departed@example.test', 'Job Coach', false)
  returning id into v_gone;
  insert into storage.objects (bucket_id, name)
  values ('staff-files', v_gone::text || '/zz-departed.pdf');

  select user_id into v_uid from public.staff where role = 'Admin' and active and user_id is not null
   order by created_at, id limit 1;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);

  /**
   * The predicate, not the delete.
   *
   * Supabase refuses a direct DELETE on storage.objects with "Direct deletion
   * from storage tables is not allowed - use the Storage API instead", so the
   * delete itself cannot be exercised from SQL. What can be checked is the
   * expression the policy is made of, which is where the bug was: it asked
   * about the staff member's *name* rather than the object's, so it never
   * matched and the freeze never applied.
   *
   * Both halves, so a guard that simply refuses everything does not pass.
   */
  if public.staff_file_owner(v_gone::text || '/zz-departed.pdf') is distinct from v_gone then
    failures := failures || 'FAILED: a frozen person''s document does not resolve to them'::text;
  elsif not exists (select 1 from public.staff s
                     where s.id = public.staff_file_owner(v_gone::text || '/zz-departed.pdf')
                       and not s.active) then
    failures := failures || 'FAILED: the delete policy would not see that this record is frozen'::text;
  else
    raise notice 'ok  a document on the record of somebody no longer active is seen as frozen';
  end if;

  if exists (select 1 from public.staff s
              where s.id = public.staff_file_owner(v_oth_s::text || '/zz-theirs.pdf')
                and not s.active) then
    failures := failures || 'FAILED: a live record reads as frozen, so the freeze is just a wall'::text;
  else
    raise notice 'ok  and one on a live record does not, so the freeze is not simply a wall';
  end if;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('role', 'postgres', true);

  if has_function_privilege('anon', 'public.staff_file_owner(text)', 'execute') then
    failures := failures || 'FAILED: somebody not signed in can ask who a staff file belongs to'::text;
  else
    raise notice 'ok  and somebody not signed in cannot ask whose a file is';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- STAFF FILES VERIFIED ---';
end $$;

rollback;
