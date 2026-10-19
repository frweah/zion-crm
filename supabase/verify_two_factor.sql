-- Zion Vocational Rehab CRM — a second factor (0217)
--
-- The cryptography is Supabase's and is not re-tested here. What is tested is
-- the practice's side of it, which is where this could go wrong quietly:
--
--   It is off. It ships off on purpose - enrolment cannot be rehearsed on
--   somebody else's phone, so the first person through that screen is the
--   first real test of it, and a wrong screen with the setting already on
--   would lock out the person who has to fix it. This assertion is the one
--   that has to be deleted deliberately when the owner turns it on.
--
--   A factor that was started and never confirmed does not count as having
--   one. Otherwise somebody who closed the tab halfway through is let past
--   by a second factor that does not exist.
--
--   The roster is Admin's. Who is protected and who is not is exactly the
--   list somebody attacking the practice would want, and it is the one thing
--   here that is worth more to an attacker than to anybody else.
--
--   Neither function tells anybody a secret.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_person uuid;
  v_p_uid  uuid := gen_random_uuid();
  v_admin  uuid;
  v_a_uid  uuid;
  v_req    boolean;
  v_has    boolean;
  v_n      integer;
  v_def    text;
  failures text[] := '{}';
begin
  select id, user_id into v_admin, v_a_uid from public.staff
   where role = 'Admin' and active and user_id is not null order by created_at limit 1;

  -- ── it is off ─────────────────────────────────────────────
  select require_two_factor into v_req from public.org_settings limit 1;
  if v_req is not false then
    failures := failures ||
      'FAILED: a second factor is required and this script still says it should not be. If the owner turned it on, this assertion is the one to change.'::text;
  else
    raise notice 'ok  a second factor is not required yet, which is how it ships';
  end if;

  insert into public.staff (name, email, role, active)
  values ('ZZ Factor Person', 'zz-factor@example.test', 'Job Search', true) returning id into v_person;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_p_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-factor@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_p_uid where id = v_person;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_p_uid, 'role', 'authenticated')::text, true);

  -- ── somebody with nothing set up ──────────────────────────
  select enrolled into v_has from public.two_factor_state();
  if v_has is not false then
    failures := failures || 'FAILED: somebody with no factor reads as enrolled'::text;
  else
    raise notice 'ok  somebody with nothing set up does not read as enrolled';
  end if;

  -- ── a half-finished enrolment does not count ──────────────
  -- Written as postgres: auth.mfa_factors is nobody's to write, which is
  -- itself part of the point.
  perform set_config('role', 'postgres', true);
  insert into auth.mfa_factors (id, user_id, friendly_name, factor_type, status, created_at, updated_at, secret)
  values (gen_random_uuid(), v_p_uid, 'ZZ half done', 'totp', 'unverified', now(), now(), 'ZZNOTAREALSECRET');
  perform set_config('role', 'authenticated', true);

  select enrolled into v_has from public.two_factor_state();
  if v_has is not false then
    failures := failures ||
      'FAILED: an unverified factor counts as a second factor, so somebody who closed the tab halfway is let past'::text;
  else
    raise notice 'ok  a started-but-unconfirmed factor does not count';
  end if;

  -- ── a confirmed one does ──────────────────────────────────
  perform set_config('role', 'postgres', true);
  update auth.mfa_factors set status = 'verified' where user_id = v_p_uid;
  perform set_config('role', 'authenticated', true);

  select enrolled into v_has from public.two_factor_state();
  if v_has is not true then
    failures := failures || 'FAILED: a confirmed factor does not read as enrolled'::text;
  else
    raise notice 'ok  and a confirmed one does';
  end if;

  -- ── debris from abandoned attempts changes nothing ────────
  --
  -- Pressing "Set it up" and walking away leaves an unverified factor behind,
  -- and on 19 Oct somebody did that several times over while the screen
  -- appeared to be doing nothing. So a person can hold a confirmed factor and
  -- a pile of half-finished ones at the same time, and neither answer may
  -- wobble: they are enrolled, and they are one person in the roster, not one
  -- row per factor.
  perform set_config('role', 'postgres', true);
  insert into auth.mfa_factors (id, user_id, friendly_name, factor_type, status, created_at, updated_at, secret)
  values (gen_random_uuid(), v_p_uid, 'ZZ abandoned', 'totp', 'unverified', now(), now(), 'ZZNOTAREALSECRET'),
         (gen_random_uuid(), v_p_uid, 'ZZ abandoned too', 'totp', 'unverified', now(), now(), 'ZZNOTAREALSECRET');
  perform set_config('role', 'authenticated', true);

  select enrolled into v_has from public.two_factor_state();
  if v_has is not true then
    failures := failures ||
      'FAILED: an abandoned attempt alongside a confirmed factor stops the person reading as enrolled'::text;
  else
    raise notice 'ok  abandoned attempts alongside a confirmed factor leave them enrolled';
  end if;

  -- ── the roster is Admin''s ────────────────────────────────
  select count(*) into v_n from public.two_factor_roster();
  if v_n > 0 then
    failures := failures ||
      format('FAILED: somebody who is not an Admin read %s rows of the roster - who is unprotected is not for them', v_n)::text;
  else
    raise notice 'ok  somebody who is not an Admin reads nothing from the roster';
  end if;

  if v_a_uid is not null then
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_a_uid, 'role', 'authenticated')::text, true);
    select count(*) into v_n from public.two_factor_roster();
    if v_n = 0 then
      failures := failures || 'FAILED: Admin cannot read the roster'::text;
    else
      raise notice 'ok  Admin reads it, all % of them', v_n;
    end if;

    -- About the fixture person, not about a total. Real staff enrol over
    -- time - the first did on 19 Oct - and an assertion that counts everybody
    -- starts failing the day the practice starts using the thing it guards.
    --
    -- Once each, too: this person is carrying two abandoned attempts as well
    -- as the confirmed factor, so a roster that joined the factors naively
    -- would list them three times.
    select count(*) into v_n from public.two_factor_roster() r
     where r.staff_id = v_person and r.enrolled;
    if v_n <> 1 then
      failures := failures || format(
        'FAILED: the roster shows the person just confirmed %s times, not once', v_n)::text;
    else
      raise notice 'ok  and it shows the one just confirmed, exactly once';
    end if;
  end if;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('role', 'postgres', true);

  -- ── neither function hands out a secret ───────────────────
  for v_def in
    select pg_get_functiondef(p.oid)
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname in ('two_factor_state', 'two_factor_roster')
  loop
    if position('secret' in lower(v_def)) > 0 then
      failures := failures || 'FAILED: one of the two-factor functions reads the secret column'::text;
    end if;
  end loop;
  raise notice 'ok  neither function so much as reads the secret';

  -- ── and anon cannot ask ───────────────────────────────────
  if has_function_privilege('anon', 'public.two_factor_state()', 'execute')
     or has_function_privilege('anon', 'public.two_factor_roster()', 'execute') then
    failures := failures || 'FAILED: anon may ask about second factors'::text;
  else
    raise notice 'ok  anon cannot ask about them at all';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- TWO FACTOR VERIFIED ---';
end $$;

rollback;
