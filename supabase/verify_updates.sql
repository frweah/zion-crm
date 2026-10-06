-- Zion Vocational Rehab CRM — Updates, and who has read them (0136)
--
-- What has to hold, each tried from the direction that would break it:
--
--   Only an Admin posts. Anybody else's post is refused, not quietly dropped.
--
--   An update for one role is invisible to another, and an update for nobody
--   in particular is everybody's.
--
--   A person records their own reading and cannot record somebody else's -
--   which is the whole value of the who-has-not-read list.
--
--   Admin can see who has read; a colleague sees only their own reading.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_admin uuid; v_admin_uid uuid := gen_random_uuid();
  v_billing uuid; v_billing_uid uuid := gen_random_uuid();
  v_search uuid; v_search_uid uuid := gen_random_uuid();
  v_all uuid;
  v_billing_only uuid;
  v_n integer;
  failures text[] := '{}';
begin
  insert into public.staff (name, email, role, active) values ('ZZ Up Admin', 'zz-up-admin@example.test', 'Admin', true) returning id into v_admin;
  insert into public.staff (name, email, role, active) values ('ZZ Up Billing', 'zz-up-bill@example.test', 'Billing', true) returning id into v_billing;
  insert into public.staff (name, email, role, active) values ('ZZ Up Search', 'zz-up-search@example.test', 'Job Search', true) returning id into v_search;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_admin_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-up-admin@example.test', '{}', '{}', now(), now()),
         (v_billing_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-up-bill@example.test', '{}', '{}', now(), now()),
         (v_search_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-up-search@example.test', '{}', '{}', now(), now());

  -- ── only an Admin posts ───────────────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_search_uid, 'role', 'authenticated')::text, true);
  begin
    insert into public.updates (title, text) values ('ZZ not allowed', 'posted by somebody who may not');
    failures := failures || 'FAILED: somebody who is not an Admin posted an update'::text;
  exception when insufficient_privilege then null;
  end;

  perform set_config('request.jwt.claims', json_build_object('sub', v_admin_uid, 'role', 'authenticated')::text, true);
  insert into public.updates (title, text, posted_by, posted_by_name)
  values ('ZZ everybody', 'This one is for everybody.', v_admin, 'ZZ Up Admin') returning id into v_all;
  insert into public.updates (title, text, audience, requires_ack, pinned, posted_by, posted_by_name)
  values ('ZZ billing only', 'This one is for Billing.', array['Billing'], true, true, v_admin, 'ZZ Up Admin')
  returning id into v_billing_only;
  raise notice 'ok  only an Admin posts, and the refusal is the database''s';

  -- ── who sees which ────────────────────────────────────────
  perform set_config('request.jwt.claims', json_build_object('sub', v_search_uid, 'role', 'authenticated')::text, true);
  select count(*) into v_n from public.updates where id = v_billing_only;
  if v_n <> 0 then
    failures := failures || 'FAILED: an update for Billing was visible to Job Search'::text;
  end if;
  select count(*) into v_n from public.updates where id = v_all;
  if v_n <> 1 then
    failures := failures || 'FAILED: an update for everybody was not visible to Job Search'::text;
  else
    raise notice 'ok  an update for a role is that role''s; one for nobody in particular is everybody''s';
  end if;

  -- ── reading is your own ───────────────────────────────────
  insert into public.update_reads (update_id, staff_id) values (v_all, v_search);
  begin
    insert into public.update_reads (update_id, staff_id) values (v_all, v_billing);
    failures := failures || 'FAILED: somebody recorded a colleague as having read an update'::text;
  exception when insufficient_privilege then
    raise notice 'ok  a person records their own reading and nobody else''s';
  end;

  -- ── who can see the reading ───────────────────────────────
  select count(*) into v_n from public.update_reads where update_id = v_all;
  if v_n <> 1 then
    failures := failures || format('FAILED: a colleague sees %s reading rows, and should see only their own', v_n);
  end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_admin_uid, 'role', 'authenticated')::text, true);
  select count(*) into v_n from public.update_reads where update_id = v_all;
  if v_n <> 1 then
    failures := failures || 'FAILED: Admin cannot see who has read an update, which is what it is posted for'::text;
  else
    raise notice 'ok  Admin sees who has read; a colleague sees only their own';
  end if;

  perform set_config('role', 'postgres', true);
  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
