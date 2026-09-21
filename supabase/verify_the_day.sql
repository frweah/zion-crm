-- Zion Vocational Rehab CRM — putting an alert aside (0119)
--
-- What has to hold, each tried from the direction that would break it:
--
--   An alert put aside is put aside for the person who did it. Somebody else
--   cannot see it, change it, or put an alert aside in another's name.
--
--   The alert itself is untouched: still open, for everybody.
--
--   Nobody signed in reads or writes any of it.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_a uuid; v_a_uid uuid := gen_random_uuid();
  v_b uuid; v_b_uid uuid := gen_random_uuid();
  v_alert uuid;
  v_n integer;
  failures text[] := '{}';
begin
  insert into public.staff (name, email, role, active) values ('ZZ Day A', 'zz-day-a@example.test', 'Admin', true) returning id into v_a;
  insert into public.staff (name, email, role, active) values ('ZZ Day B', 'zz-day-b@example.test', 'Admin', true) returning id into v_b;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_a_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-day-a@example.test', '{}', '{}', now(), now()),
         (v_b_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-day-b@example.test', '{}', '{}', now(), now());
  insert into public.notifications (dedupe_key, kind, level, text, roles)
  values ('zz-day-alert', 'zz', 'warn', 'ZZ an alert', array['Admin']) returning id into v_alert;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_a_uid, 'role', 'authenticated')::text, true);
  insert into public.staff_alert_snoozes (staff_id, notification_id, until) values (v_a, v_alert, public.practice_today() + 1);

  begin
    insert into public.staff_alert_snoozes (staff_id, notification_id, until) values (v_b, v_alert, public.practice_today() + 1);
    failures := failures || 'FAILED: an alert was put aside in somebody else''s name'::text;
  exception when insufficient_privilege or check_violation then null;
  end;

  perform set_config('request.jwt.claims', json_build_object('sub', v_b_uid, 'role', 'authenticated')::text, true);
  select count(*) into v_n from public.staff_alert_snoozes;
  if v_n <> 0 then
    failures := failures || 'FAILED: somebody can see the alerts another person put aside'::text;
  end if;
  update public.staff_alert_snoozes set until = public.practice_today() + 30;
  get diagnostics v_n = row_count;
  if v_n <> 0 then
    failures := failures || 'FAILED: somebody changed how long another person put an alert aside'::text;
  end if;

  perform set_config('role', 'postgres', true);
  if (select resolved_at from public.notifications where id = v_alert) is not null then
    failures := failures || 'FAILED: putting an alert aside resolved it for everybody'::text;
  else
    raise notice 'ok  an alert put aside is put aside for that person only, and stays open for everybody else';
  end if;

  if has_table_privilege('anon', 'public.staff_alert_snoozes', 'select') or has_table_privilege('anon', 'public.staff_alert_snoozes', 'insert') then
    failures := failures || 'FAILED: somebody not signed in can reach the alerts put aside'::text;
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
