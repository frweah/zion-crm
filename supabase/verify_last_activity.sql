-- Zion Vocational Rehab CRM — "last activity" says what the feed says
--
-- What has to hold, each tried from the direction that would break it:
--
--   For every client, client_last_activity gives exactly max(at) over
--   client_activity - read as Admin, and read as a member of staff who is not,
--   because what each person may see (notes kept to Admin, restricted forms)
--   is part of the answer.
--
--   Something new on a client's feed moves their last activity to it.
--
-- Runs inside a transaction that is rolled back. Nothing here is left behind.

begin;

do $$
declare
  v_admin    uuid;
  v_adm_uid  uuid;
  v_other    uuid;
  v_oth_uid  uuid;
  v_client   uuid;
  v_bad      bigint;
  v_at       timestamptz;
  r          record;
  failures   text[] := '{}';
begin
  select id, user_id into v_admin, v_adm_uid from public.staff
   where role = 'Admin' and active and user_id is not null order by created_at, id limit 1;
  select id, user_id into v_other, v_oth_uid from public.staff
   where role <> 'Admin' and active and user_id is not null order by created_at, id limit 1;

  insert into public.clients (name, stage, status, assigned_staff_id)
  values ('ZZ Last Activity', 'Job Coaching', 'Active', v_admin) returning id into v_client;
  -- A note only Admin may read, dated in the future so it is the latest thing
  -- on the feed for Admin and invisible to anybody else.
  insert into public.notes (client_id, staff_id, staff_name, text, type, visible_roles, at)
  values (v_client, v_admin, 'ZZ Admin', 'ZZ for Admin only', 'General', array['Admin'], current_date + 5);

  perform set_config('role', 'authenticated', true);

  for r in select * from (values ('Admin', v_adm_uid), ('not Admin', v_oth_uid)) as x(who, uid) where x.uid is not null loop
    perform set_config('request.jwt.claims', json_build_object('sub', r.uid, 'role', 'authenticated')::text, true);

    select count(*) into v_bad
      from public.client_last_activity n
      full join (
        select c.id as client_id, max(a.at) as last_activity_at
          from public.clients c
          left join public.client_activity a on a.client_id = c.id
         group by c.id
      ) o on o.client_id = n.client_id
     where n.client_id is null or o.client_id is null
        or n.last_activity_at is distinct from o.last_activity_at;

    if v_bad > 0 then
      failures := failures || format('FAILED: read as %s, %s clients'' last activity differs from their feed', r.who, v_bad)::text;
    else
      raise notice 'ok  read as %, every client''s last activity is exactly the latest thing on their feed', r.who;
    end if;
  end loop;

  -- The Admin-only note moves the date for Admin and for nobody else.
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);
  select last_activity_at into v_at from public.client_last_activity where client_id = v_client;
  if v_at::date <> current_date + 5 then
    failures := failures || 'FAILED: a new note did not become the client''s last activity'::text;
  end if;
  if v_oth_uid is not null then
    perform set_config('request.jwt.claims', json_build_object('sub', v_oth_uid, 'role', 'authenticated')::text, true);
    select last_activity_at into v_at from public.client_last_activity where client_id = v_client;
    if v_at is not null and v_at::date = current_date + 5 then
      failures := failures || 'FAILED: a note kept to Admin set the last activity for somebody who cannot read it'::text;
    else
      raise notice 'ok  a note moves the date for those who can read it, and only them';
    end if;
  end if;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('role', 'postgres', true);

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- LAST ACTIVITY VERIFIED ---';
end $$;

rollback;
