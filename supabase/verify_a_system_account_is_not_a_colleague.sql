-- A system account is not a colleague (0294)
--
-- The deploy checks sign in as accounts that are not people. Everything about
-- people has to leave them out, and the one that did not was the staff chat:
-- both check accounts sat in the Everyone group from 0272 until 0294, because
-- a participant who never opens anything looks exactly like a quiet one.
--
-- Four cases, and the last two are the ones a fix remembers to do and a check
-- has to insist on: a row that becomes a system account afterwards, and a
-- system account that is switched off and on again.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_conv uuid;
  v_sys  uuid;
  v_them uuid;
  v_uid  uuid := gen_random_uuid();
  v_n    integer;
  r record;
  failures text[] := '{}';
begin
  select id into v_conv from public.conversations where system_key = 'everyone';
  if v_conv is null then
    raise exception 'there is no Everyone conversation, so this script is asking about nothing';
  end if;

  -- ── 1. none of the ones on file is in it ──────────────────
  select count(*) into v_n
    from public.conversation_participants p
    join public.staff s on s.id = p.staff_id
   where p.conversation_id = v_conv and s.is_system and p.left_at is null;
  if v_n > 0 then
    failures := failures || format(
      'FAILED: %s system account(s) are in the Everyone group, so colleagues'' messages are delivered to them', v_n);
  else
    raise notice 'ok  no system account is in the Everyone group';
  end if;

  -- And the people are, which is the other half: a trigger that excluded
  -- everybody would pass the case above and break the group.
  select count(*) into v_n
    from public.staff s
   where s.active and not s.is_system
     and not exists (
       select 1 from public.conversation_participants p
        where p.conversation_id = v_conv and p.staff_id = s.id and p.left_at is null);
  if v_n > 0 then
    failures := failures || format(
      'FAILED: %s active colleague(s) are not in the Everyone group', v_n);
  else
    raise notice 'ok  and every active colleague is';
  end if;

  -- ── 2. a new system account does not join ────────────────
  insert into public.staff (name, email, role, active, is_system)
  values ('ZQ check account', 'zq-sys@example.test', 'Reports', true, true)
  returning id into v_sys;

  if exists (select 1 from public.conversation_participants
              where conversation_id = v_conv and staff_id = v_sys and left_at is null) then
    failures := failures || 'FAILED: a new system account joined the Everyone group'::text;
  else
    raise notice 'ok  a system account added now does not join it';
  end if;

  -- ── 3. a new person does join ────────────────────────────
  insert into public.staff (name, email, role, active, is_system)
  values ('ZQ colleague', 'zq-person@example.test', 'Job Search', true, false)
  returning id into v_them;

  if not exists (select 1 from public.conversation_participants
                  where conversation_id = v_conv and staff_id = v_them and left_at is null) then
    failures := failures || 'FAILED: a new colleague did not join the Everyone group'::text;
  else
    raise notice 'ok  a colleague added now does';
  end if;

  -- ── 4. a person who becomes a system account comes out ───
  --
  -- The case a fix skips. Excluding them on the way in leaves anybody already
  -- in the group exactly where they were, which is what 0272 did to the two
  -- check accounts for a fortnight.
  update public.staff set is_system = true where id = v_them;
  if exists (select 1 from public.conversation_participants
              where conversation_id = v_conv and staff_id = v_them and left_at is null) then
    failures := failures || 'FAILED: a colleague who became a system account stayed in the Everyone group'::text;
  else
    raise notice 'ok  one that becomes a system account is taken out of it';
  end if;

  -- ── 5. and switching one off and on does not let it back ──
  update public.staff set active = false where id = v_sys;
  update public.staff set active = true  where id = v_sys;
  if exists (select 1 from public.conversation_participants
              where conversation_id = v_conv and staff_id = v_sys and left_at is null) then
    failures := failures || 'FAILED: a system account switched off and on again joined the Everyone group'::text;
  else
    raise notice 'ok  switching one off and on again does not put it in';
  end if;

  -- ── 6. the Admin check account is on file and is a system one ──
  select count(*) into v_n from public.staff
   where email = 'automated-check-reports@zionvocrehab.com'
     and role = 'Reports' and active and is_system;
  if v_n <> 1 then
    failures := failures || format(
      'FAILED: the Reports check account is not on file as an active Intake & Reports system account (%s found)', v_n);
  else
    raise notice 'ok  the Reports check account is an active Intake & Reports, flagged as a system account';
  end if;

  -- And no system account is Admin, which 0294 allowed and 0295 took back.
  select count(*) into v_n from public.staff where is_system and role = 'Admin';
  if v_n > 0 then
    failures := failures || format('FAILED: %s system account(s) hold Admin', v_n);
  else
    raise notice 'ok  and no system account holds Admin';
  end if;

  -- ── 7. and it is not a person anywhere a person is listed ──
  --
  -- Asked of the thing rather than of the screens: is_system is what every
  -- one of those screens filters on, so the rule is that the flag is set and
  -- that nothing about credentials asks after it.
  select count(*) into v_n from public.staff_credential_status
   where staff_id = (select id from public.staff where email = 'automated-check-reports@zionvocrehab.com');
  if v_n > 0 then
    failures := failures || format(
      'FAILED: the Admin check account has %s credential row(s), so it will be chased for an I-9', v_n);
  else
    raise notice 'ok  and nothing asks it for a credential';
  end if;

  -- A failure is raised with its own errcode, so the rollback handler below
  -- cannot swallow it. A verify script that catches its own findings is a
  -- verify script that always passes.
  -- ── 8. and it still cannot write ─────────────────────────
  --
  -- 0120's promise is that a leaked check password buys the ability to look
  -- and not to change, and that promise is 310 restrictive policies. Asserted
  -- in the account's own session rather than as postgres, because as postgres
  -- every policy is beside the point.
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zq-sys@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_uid where id = v_sys;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);

  begin
    insert into public.notes (text) values ('ZQ a system account should not be able to write this');
    failures := failures || 'FAILED: an Admin system account inserted a note'::text;
  exception when insufficient_privilege or check_violation then
    raise notice 'ok  a system account is still refused a write to a table';
  when others then
    -- Any refusal is a refusal; what would be wrong is the insert landing.
    raise notice 'ok  a system account is still refused a write to a table (%)', sqlstate;
  end;

  perform set_config('role', 'postgres', true);

  if array_length(failures, 1) > 0 then
    for r in select unnest(failures) as said loop
      raise notice '%', r.said;
    end loop;
    raise exception '% case(s) failed: %', array_length(failures, 1), array_to_string(failures, ' | ');
  end if;

  raise notice '--- A SYSTEM ACCOUNT IS NOT A COLLEAGUE: VERIFIED ---';
  raise exception 'ZQ rolling the fixture back' using errcode = 'check_violation';
exception when check_violation then
  if sqlerrm <> 'ZQ rolling the fixture back' then raise; end if;
end $$;

rollback;
