-- Zion Vocational Rehab CRM — report a problem (0216)
--
-- What has to hold:
--
--   Anybody may say the CRM is wrong, and the screen they were on is kept
--   with it.
--
--   They read their own and nobody else's. Admin reads them all. A report is
--   somebody writing about their own working day and is nobody else's
--   business.
--
--   What was said is not edited - not by Admin, and not by the person who
--   said it. A report is an account of a moment, and the useful thing about
--   it is what they thought at the time. Closing one adds a note beside it.
--
--   Admin is told once, and told again about nothing. Closing it clears the
--   notification, so the bell and the list of open reports cannot disagree.
--
--   And the agent account cannot file one: a complaint with nobody behind it
--   is not a complaint.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_person uuid;
  v_p_uid  uuid := gen_random_uuid();
  v_other  uuid;
  v_o_uid  uuid := gen_random_uuid();
  v_admin  uuid;
  v_a_uid  uuid;
  v_report uuid;
  v_n      integer;
  failures text[] := '{}';
begin
  select id, user_id into v_admin, v_a_uid from public.staff
   where role = 'Admin' and active and user_id is not null order by created_at limit 1;

  insert into public.staff (name, email, role, active)
  values ('ZZ Problem Person', 'zz-problem@example.test', 'Job Search', true) returning id into v_person;
  insert into public.staff (name, email, role, active)
  values ('ZZ Problem Other', 'zz-problem-other@example.test', 'Job Coach', true) returning id into v_other;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_p_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-problem@example.test', '{}', '{}', now(), now()),
         (v_o_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-problem-other@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_p_uid where id = v_person;
  update public.staff set user_id = v_o_uid where id = v_other;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_p_uid, 'role', 'authenticated')::text, true);

  -- ── anybody may report one ────────────────────────────────
  insert into public.problem_reports (staff_id, screen, what)
  values (v_person, '/clients', 'ZZ the quiet-since column is a day out')
  returning id into v_report;
  raise notice 'ok  anybody may say the CRM is wrong, from the screen they were on';

  -- ── and not in somebody else's name ───────────────────────
  begin
    insert into public.problem_reports (staff_id, screen, what)
    values (v_other, '/clients', 'ZZ not my report');
    failures := failures || 'FAILED: a report was filed in somebody else''s name'::text;
  exception when insufficient_privilege then
    raise notice 'ok  and not in somebody else''s name';
  end;

  /*
   * What was said is not edited.
   *
   * Checked by reading it back rather than by expecting a refusal: with no
   * update policy for them, RLS does not raise - the statement matches no
   * rows and reports success. An assertion that waited for an exception
   * would have passed whether or not the text was protected, which is the
   * wrong way round.
   */
  update public.problem_reports set what = 'ZZ something else' where id = v_report;
  if (select what from public.problem_reports where id = v_report) <> 'ZZ the quiet-since column is a day out' then
    failures := failures || 'FAILED: the person who reported it was able to rewrite it'::text;
  else
    raise notice 'ok  what was said is not rewritten by the person who said it';
  end if;

  -- ── somebody else cannot read it ──────────────────────────
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_o_uid, 'role', 'authenticated')::text, true);
  select count(*) into v_n from public.problem_reports where id = v_report;
  if v_n > 0 then
    failures := failures || 'FAILED: a colleague can read somebody else''s problem report'::text;
  else
    raise notice 'ok  a colleague cannot read it';
  end if;

  -- ── Admin reads them all, and closes them ─────────────────
  if v_a_uid is not null then
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_a_uid, 'role', 'authenticated')::text, true);

    select count(*) into v_n from public.problem_reports where id = v_report;
    if v_n <> 1 then
      failures := failures || 'FAILED: Admin cannot read a problem report'::text;
    else
      raise notice 'ok  Admin reads them all';
    end if;

    -- Admin does have an update policy, so here the trigger is what refuses.
    begin
      update public.problem_reports set what = 'ZZ Admin rewrote it' where id = v_report;
      failures := failures || 'FAILED: Admin was able to rewrite what somebody reported'::text;
    exception when check_violation then
      raise notice 'ok  and Admin cannot rewrite it either - the trigger refuses';
    end;

    update public.problem_reports
       set resolved_at = now(), resolved_by = v_admin, note = 'ZZ fixed it'
     where id = v_report;
    raise notice 'ok  closing one adds a note beside it rather than changing it';
  end if;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('role', 'postgres', true);

  -- ── Admin was told, once, and the telling was cleared ─────
  select count(*) into v_n from public.notifications
   where dedupe_key = 'problem:' || v_report::text;
  if v_n <> 1 then
    failures := failures || format('FAILED: %s notifications for one report, not 1', v_n)::text;
  else
    raise notice 'ok  Admin is told once';
  end if;

  select count(*) into v_n from public.notifications
   where dedupe_key = 'problem:' || v_report::text and resolved_at is null;
  if v_n <> 0 then
    failures := failures || 'FAILED: the report was closed and the notification is still open'::text;
  else
    raise notice 'ok  and closing the report clears it';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- PROBLEM REPORTS VERIFIED ---';
end $$;

rollback;
