-- Zion Vocational Rehab CRM — the staff documents vault
--
-- A personnel file is the most private thing in this system after a client's
-- restricted tier: somebody's licence, their background check, whatever they
-- signed when they joined. Three questions, and the answers have to hold in
-- the database rather than in whichever screen happens to be drawing.
--
--   Who can put something on somebody's file?
--   Who can take it off?
--   And who has been through it?
--
-- The storage bucket cannot be exercised from here, so what is checked is the
-- part that decides — the row, and the function that says whether a download
-- link may be minted.
--
-- Runs inside a transaction that is rolled back. Nothing here is left behind.

begin;

do $$
declare
  v_admin   uuid;
  v_adm_uid uuid;
  v_other   uuid;
  v_oth_uid uuid;
  v_file    uuid;
  v_before  bigint;
  v_count   int;
  v_ok      boolean;
  failures  text[] := '{}';
begin
  select id, user_id into v_admin, v_adm_uid from public.staff
   where role = 'Admin' and active order by created_at limit 1;
  select id, user_id into v_other, v_oth_uid from public.staff
   where active and id <> v_admin order by created_at limit 1;

  -- ── a person may add to their own file ─────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_oth_uid, 'role', 'authenticated')::text, true);

  insert into public.staff_files
    (staff_id, storage_path, filename, mime_type, size_bytes, category, note, uploaded_by)
  values (v_other, 'ZZ/' || gen_random_uuid() || '-cpr.pdf', 'ZZ cpr card.pdf',
          'application/pdf', 1024, 'Certificate', 'ZZ my own card', v_other)
  returning id into v_file;
  raise notice 'ok  somebody can put a document on their own file — "send us your CPR card" is a thing they do';

  -- ── but not on anybody else's ──────────────────────────────
  begin
    insert into public.staff_files
      (staff_id, storage_path, filename, mime_type, size_bytes, category, uploaded_by)
    values (v_admin, 'ZZ/' || gen_random_uuid() || '-x.pdf', 'ZZ theirs.pdf',
            'application/pdf', 1024, 'Other', v_other);
    failures := failures || 'FAILED: somebody put a document on a colleague''s file'::text;
  exception when insufficient_privilege then
    raise notice 'ok  and not onto somebody else''s';
  end;

  -- ── nor pretend somebody else uploaded it ──────────────────
  begin
    insert into public.staff_files
      (staff_id, storage_path, filename, mime_type, size_bytes, category, uploaded_by)
    values (v_other, 'ZZ/' || gen_random_uuid() || '-y.pdf', 'ZZ forged.pdf',
            'application/pdf', 1024, 'Other', v_admin);
    failures := failures || 'FAILED: a document was recorded as uploaded by somebody else'::text;
  exception when insufficient_privilege then
    raise notice 'ok  and cannot record it as having come from somebody else';
  end;

  -- ── an invented category is refused ────────────────────────
  begin
    insert into public.staff_files
      (staff_id, storage_path, filename, mime_type, size_bytes, category, uploaded_by)
    values (v_other, 'ZZ/' || gen_random_uuid() || '-z.pdf', 'ZZ odd.pdf',
            'application/pdf', 1024, 'Sandwich receipt', v_other);
    failures := failures || 'FAILED: a document was filed under an invented category'::text;
  exception when foreign_key_violation then
    raise notice 'ok  a category has to be one that exists';
  end;

  -- ── whose file it is ───────────────────────────────────────
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);

  select count(*) into v_count from public.staff_files where id = v_file;
  if v_count <> 1 then
    failures := failures || 'FAILED: Admin cannot see a document on somebody''s file'::text;
  else
    raise notice 'ok  Admin sees it';
  end if;

  -- A third person sees nothing. Skipped where the practice has only two
  -- accounts that are not Admin, and said out loud rather than passing
  -- quietly on an empty set.
  if exists (
    select 1 from public.staff
     where active and id not in (v_admin, v_other) and user_id is not null
  ) then
    perform set_config('request.jwt.claims',
      json_build_object('sub',
        (select user_id from public.staff
          where active and id not in (v_admin, v_other) and user_id is not null limit 1),
        'role', 'authenticated')::text, true);

    select count(*) into v_count from public.staff_files where id = v_file;
    if v_count <> 0 then
      failures := failures || 'FAILED: a colleague can see somebody else''s personnel document'::text;
    else
      raise notice 'ok  and a colleague sees nothing at all';
    end if;
  else
    raise notice 'note  no third account to check the colleague case with';
  end if;

  -- ── who may take one off ───────────────────────────────────
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_oth_uid, 'role', 'authenticated')::text, true);

  delete from public.staff_files where id = v_file;
  if not exists (select 1 from public.staff_files where id = v_file) then
    failures := failures || 'FAILED: somebody deleted a document from their own file'::text;
  else
    raise notice 'ok  nobody empties their own personnel file, including of things they put there';
  end if;

  -- ── opening one is recorded, unless it is your own ──────────
  select count(*) into v_before from public.access_log;

  select public.note_staff_file_access(v_file) into v_ok;
  if not v_ok then
    failures := failures || 'FAILED: somebody was refused their own document'::text;
  elsif (select count(*) from public.access_log) <> v_before then
    failures := failures || 'FAILED: opening your own document was recorded, which buries the ones that matter'::text;
  else
    raise notice 'ok  opening your own document is not an event — the log answers who else has been through it';
  end if;

  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);

  select count(*) into v_before from public.access_log;
  select public.note_staff_file_access(v_file) into v_ok;
  if not v_ok then
    failures := failures || 'FAILED: Admin was refused a document'::text;
  elsif (select count(*) from public.access_log) <> v_before + 1 then
    failures := failures || 'FAILED: Admin opening somebody''s document was not recorded'::text;
  else
    raise notice 'ok  somebody else opening it is recorded, with what they opened';
  end if;

  if not exists (
    select 1 from public.access_log
     where subject = 'Staff document' and about_staff = v_other
       and purpose like 'opened Certificate%'
  ) then
    failures := failures || 'FAILED: the entry does not say whose document, or which'::text;
  else
    raise notice 'ok  and says whose file it was and which document';
  end if;

  -- ── a credential leaning on a document says so ─────────────
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  insert into public.staff_credentials (staff_id, type_key, issued_on, expires_on, file_id)
  values (v_other, 'cpr', public.practice_today(), public.practice_today() + 700, v_file);

  if not (select backs_a_credential from public.staff_documents where id = v_file) then
    failures := failures || 'FAILED: a document a credential relies on does not say so'::text;
  else
    raise notice 'ok  a document standing behind a credential says so, so removing it can warn';
  end if;

  -- ── a tax form signed in the app is not uploadable ─────────
  if not (select system_only from public.staff_file_categories where key = 'W-9') then
    failures := failures || 'FAILED: a W-9 is offered as something to upload'::text;
  else
    raise notice 'ok  a W-9 is signed in the app, not uploaded — the catalogue says so';
  end if;

  if failures = '{}' then
    raise notice '';
    raise notice '--- STAFF DOCUMENTS VERIFIED ---';
  else
    raise notice '';
    raise notice '%  PROBLEM(S):', array_length(failures, 1);
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
