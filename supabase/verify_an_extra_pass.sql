-- Zion Vocational Rehab CRM — Run now, and who may ask (0382)
--
-- The agent reads the client folders at ten and at seven. Run now on
-- Admin → Documents asks for an extra pass, and what has to hold is:
--
--   whoever may open that screen may ask - Admin, or somebody holding a
--   billing edit grant - and nobody else;
--
--   they ask as themselves, so "who asked for this" is answerable;
--
--   nobody signed in marks one done or deletes one. The agent does that, as
--   the service role, which is what makes the row the record of whether the
--   pass actually happened rather than of somebody having pressed a button;
--
--   and asking writes nothing anywhere else: no document, no client, no log.
--
-- Everything is rolled back.

begin;

do $$
declare
  failures text[] := array[]::text[];
  v_mark   integer;
  v_admin  uuid; v_admin_uid uuid := gen_random_uuid();
  v_coach  uuid; v_coach_uid uuid := gen_random_uuid();
  v_grant  uuid; v_grant_uid uuid := gen_random_uuid();
  v_id     uuid;
  v_n      integer;
  v_docs   integer;
begin
  insert into public.staff (name, email, role, active)
  values ('ZZ Pass Admin', 'zz-pass-admin@example.test', 'Admin', true) returning id into v_admin;
  insert into public.staff (name, email, role, active)
  values ('ZZ Pass Coach', 'zz-pass-coach@example.test', 'Job Coach', true) returning id into v_coach;
  insert into public.staff (name, email, role, active)
  values ('ZZ Pass Grantee', 'zz-pass-grantee@example.test', 'Job Search', true) returning id into v_grant;

  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_admin_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-pass-admin@example.test', '{}', '{}', now(), now()),
         (v_coach_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-pass-coach@example.test', '{}', '{}', now(), now()),
         (v_grant_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-pass-grantee@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_admin_uid where id = v_admin;
  update public.staff set user_id = v_coach_uid where id = v_coach;
  update public.staff set user_id = v_grant_uid where id = v_grant;

  -- The grant that opens the document inbox, which is the other way in.
  insert into public.staff_access_grants (staff_id, area, level, granted_by, reason)
  values (v_grant, 'billing', 'edit', v_admin, 'ZZ verify: the other way into the document inbox');

  select count(*) into v_docs from public.inbox_documents;

  -- ── 1. Admin may ask, as themselves ──────────────────────────
  v_mark := coalesce(array_length(failures, 1), 0);
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin_uid, 'role', 'authenticated')::text, true);

  insert into public.inbox_scan_requests (asked_by, asked_by_name)
  values (v_admin, 'ZZ Pass Admin') returning id into v_id;
  if v_id is null then
    failures := failures || 'FAILED: an Admin could not ask for a pass'::text;
  end if;

  -- And not in somebody else's name.
  begin
    insert into public.inbox_scan_requests (asked_by, asked_by_name)
    values (v_coach, 'ZZ Pass Coach');
    failures := failures || 'FAILED: a request was written in somebody else''s name'::text;
  exception when insufficient_privilege then null;
  end;

  -- Nor already answered.
  begin
    insert into public.inbox_scan_requests (asked_by, asked_by_name, done_at)
    values (v_admin, 'ZZ Pass Admin', now());
    failures := failures || 'FAILED: a request was written already done'::text;
  exception when insufficient_privilege then null;
  end;
  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  an Admin asks, as themselves, and not for a pass that has already happened';
  end if;

  -- ── 2. the grant that opens the screen may ask too ───────────
  v_mark := coalesce(array_length(failures, 1), 0);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_grant_uid, 'role', 'authenticated')::text, true);
  begin
    insert into public.inbox_scan_requests (asked_by, asked_by_name)
    values (v_grant, 'ZZ Pass Grantee');
  exception when others then
    failures := failures || format('FAILED: a billing edit grant could not ask: %s', sqlerrm)::text;
  end;
  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  so does somebody holding a billing edit grant, which is who else opens the screen';
  end if;

  -- ── 3. and nobody else ───────────────────────────────────────
  v_mark := coalesce(array_length(failures, 1), 0);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_coach_uid, 'role', 'authenticated')::text, true);
  begin
    insert into public.inbox_scan_requests (asked_by, asked_by_name)
    values (v_coach, 'ZZ Pass Coach');
    failures := failures || 'FAILED: a Job Coach asked the agent for a pass'::text;
  exception when insufficient_privilege then null;
  end;

  perform set_config('request.jwt.claims', '', true);
  begin
    insert into public.inbox_scan_requests (asked_by, asked_by_name)
    values (null, 'nobody');
    failures := failures || 'FAILED: somebody not signed in asked the agent for a pass'::text;
  exception when others then null;
  end;
  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  a role that cannot open the screen cannot ask, and neither can a stranger';
  end if;

  -- ── 4. nobody signed in says it happened ─────────────────────
  v_mark := coalesce(array_length(failures, 1), 0);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin_uid, 'role', 'authenticated')::text, true);
  update public.inbox_scan_requests set done_at = now() where id = v_id;
  select count(*) into v_n from public.inbox_scan_requests where id = v_id and done_at is not null;
  if v_n <> 0 then
    failures := failures || 'FAILED: an Admin marked a pass as having happened'::text;
  end if;
  delete from public.inbox_scan_requests where id = v_id;
  select count(*) into v_n from public.inbox_scan_requests where id = v_id;
  if v_n <> 1 then
    failures := failures || 'FAILED: an Admin deleted the record of an ask'::text;
  end if;
  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  the agent says whether a pass happened, and nobody signed in can say it for them';
  end if;

  -- ── 5. and asking writes nothing else ────────────────────────
  v_mark := coalesce(array_length(failures, 1), 0);
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  select count(*) into v_n from public.inbox_documents;
  if v_n <> v_docs then
    failures := failures || 'FAILED: asking for a pass changed the document inbox'::text;
  end if;
  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  asking is an ask: nothing else was written';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception E'\n%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- AN EXTRA PASS VERIFIED ---';
end $$;

rollback;
