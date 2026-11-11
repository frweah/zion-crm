-- The phone works without signal (0342)
--
-- What the brief asks to be shown: something sent twice is done once, and a
-- clock pressed with no signal is recorded at the time it was pressed. And
-- what the bounds are for: a time in the future, a time more than a day back,
-- a clock-in before the last session ended, and a key that is somebody
-- else's are each refused.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_uid   uuid := gen_random_uuid();
  v_uid2  uuid := gen_random_uuid();
  v_me    uuid;
  v_other uuid;
  v_key   uuid := gen_random_uuid();
  v_out   uuid := gen_random_uuid();
  v_said  text;
  v_n     integer;
  v_start timestamptz;
  failures text[] := '{}';
begin
  insert into public.staff (name, email, role, active)
  values ('ZZ Phone Coach', 'zz-phone@example.test', 'Job Coach', true) returning id into v_me;
  insert into public.staff (name, email, role, active)
  values ('ZZ Phone Other', 'zz-phone-2@example.test', 'Job Coach', true) returning id into v_other;
  insert into public.staff_employment (staff_id, employment_type) values (v_me, 'Employee');
  insert into public.staff_employment (staff_id, employment_type) values (v_other, 'Employee');
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-phone@example.test', '{}', '{}', now(), now()),
         (v_uid2, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-phone-2@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_uid where id = v_me;
  update public.staff set user_id = v_uid2 where id = v_other;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);

  -- ── the time it was pressed, not the time it arrived ──────
  v_start := date_trunc('second', now() - interval '40 minutes');
  v_said := public.phone_clock(v_key, 'clock in', v_start);
  perform set_config('role', 'postgres', true);
  if v_said <> 'done' then
    failures := failures || format('FAILED: the first clock-in said %s', v_said)::text;
  elsif (select started_at from public.work_session_timers where staff_id = v_me) <> v_start then
    failures := failures || 'FAILED: the clock-in was recorded at the time it arrived, not when it was pressed'::text;
  else
    raise notice 'ok  a clock-in sent forty minutes late starts when it was pressed';
  end if;

  -- ── twice is once ─────────────────────────────────────────
  perform set_config('role', 'authenticated', true);
  v_said := public.phone_clock(v_key, 'clock in', v_start);
  if v_said <> 'already' then
    failures := failures || format('FAILED: the same clock-in sent again said %s rather than already', v_said)::text;
  else
    raise notice 'ok  the same clock-in sent again is answered already, not refused and not done twice';
  end if;

  -- ── the break, inside the session, at its own times ───────
  perform public.phone_clock(gen_random_uuid(), 'break', v_start + interval '10 minutes');
  perform public.phone_clock(gen_random_uuid(), 'back', v_start + interval '25 minutes');
  perform set_config('role', 'postgres', true);
  if (select break_seconds from public.work_session_timers where staff_id = v_me) <> 900 then
    failures := failures || 'FAILED: a fifteen-minute break sent late was not fifteen minutes'::text;
  else
    raise notice 'ok  a break sent late is the length it was taken';
  end if;

  perform set_config('role', 'authenticated', true);
  v_said := public.phone_clock(v_out, 'clock out', v_start + interval '35 minutes');
  v_said := public.phone_clock(v_out, 'clock out', v_start + interval '35 minutes');
  perform set_config('role', 'postgres', true);
  select count(*) into v_n from public.work_sessions where staff_id = v_me;
  if v_n <> 1 then
    failures := failures || format('FAILED: a clock-out sent twice made %s sessions', v_n)::text;
  elsif (select hours from public.work_sessions where staff_id = v_me) <> 0.33 then
    failures := failures || format('FAILED: 35 minutes less a 15-minute break came to %s hours',
                                   (select hours from public.work_sessions where staff_id = v_me))::text;
  else
    raise notice 'ok  a clock-out sent twice is one session, of the time actually worked';
  end if;
  if (select count(*) from public.phone_receipts where staff_id = v_me) <> 4 then
    failures := failures || 'FAILED: the receipts are not one per thing pressed'::text;
  elsif exists (select 1 from public.phone_receipts where staff_id = v_me and received_at = happened_at) then
    failures := failures || 'FAILED: a receipt lost the time it was pressed'::text;
  else
    raise notice 'ok  every receipt keeps when it was pressed and when it arrived';
  end if;

  -- ── the bounds ────────────────────────────────────────────
  perform set_config('role', 'authenticated', true);
  begin
    perform public.phone_clock(gen_random_uuid(), 'clock in', now() + interval '1 hour');
    failures := failures || 'FAILED: a clock-in an hour in the future was taken'::text;
  exception when check_violation then
    raise notice 'ok  a time in the future is refused';
  end;
  begin
    perform public.phone_clock(gen_random_uuid(), 'clock in', now() - interval '2 days');
    failures := failures || 'FAILED: a clock-in two days back was taken'::text;
  exception when check_violation then
    raise notice 'ok  a time more than a day back is refused';
  end;
  begin
    perform public.phone_clock(gen_random_uuid(), 'clock in', v_start + interval '5 minutes');
    failures := failures || 'FAILED: a clock-in inside a session already worked was taken'::text;
  exception when check_violation then
    raise notice 'ok  a clock-in before the last session ended is refused';
  end;

  -- A refusal leaves no receipt, so the phone can be corrected and send again.
  perform set_config('role', 'postgres', true);
  if (select count(*) from public.phone_receipts where staff_id = v_me) <> 4 then
    failures := failures || 'FAILED: a refused clock left a receipt behind'::text;
  else
    raise notice 'ok  a refusal leaves no receipt, so it can be sent again';
  end if;

  -- ── a key is its owner's ──────────────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_uid2, 'role', 'authenticated')::text, true);
  begin
    perform public.phone_clock(v_key, 'clock in', now());
    failures := failures || 'FAILED: somebody else''s key was answered as already done'::text;
  exception when insufficient_privilege then
    raise notice 'ok  a key that is somebody else''s is refused';
  end;
  if (select count(*) from public.phone_receipts) <> 0 then
    failures := failures || 'FAILED: one person can read another''s receipts'::text;
  else
    raise notice 'ok  a person reads their own receipts and nobody else''s';
  end if;

  -- ── and nobody claims a key directly ──────────────────────
  begin
    perform public.phone_claim(gen_random_uuid(), 'clock in', now());
    failures := failures || 'FAILED: phone_claim can be called directly'::text;
  exception when insufficient_privilege then
    raise notice 'ok  a key is claimed only through the work it is for';
  end;

  perform set_config('role', 'postgres', true);
  if not exists (
    select 1 from storage.buckets where id = 'client-files' and 'audio/webm' = any (allowed_mime_types)
  ) or not exists (
    select 1 from storage.buckets where id = 'client-files' and 'audio/mp4' = any (allowed_mime_types)
  ) then
    failures := failures || 'FAILED: the client-files bucket refuses a recording'::text;
  else
    raise notice 'ok  a recording can go on a client''s Documents';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception E'\n%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
