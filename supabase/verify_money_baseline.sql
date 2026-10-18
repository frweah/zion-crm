-- Zion Vocational Rehab CRM — the baseline (0219)
--
-- The books open on 1 January 2027, so 2026 is outside the ledger and there
-- is otherwise nothing to say what the practice had done before it started
-- keeping formal books.
--
-- What has to hold:
--
--   It is frozen. A baseline that can be edited is not a baseline, and a
--   baseline that is recomputed is worse than one that can be edited: an
--   authorization corrected in March would silently change what December
--   said, and nobody would know the comparison had moved.
--
--   One per day, taken once. A second one for the same day is a mistake
--   somebody is in the middle of making.
--
--   The figures are the ones the Money screen shows, not a second opinion.
--
--   A note can be added afterwards, because explaining a row is not altering
--   it.
--
--   Admin's, and not the agent account's.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_admin  uuid;
  v_a_uid  uuid;
  v_other  uuid;
  v_o_uid  uuid := gen_random_uuid();
  v_id     uuid;
  v_as_of  date := public.practice_today() - 1;
  v_screen numeric;
  v_kept   numeric;
  v_n      integer;
  failures text[] := '{}';
begin
  select id, user_id into v_admin, v_a_uid from public.staff
   where role = 'Admin' and active and user_id is not null order by created_at limit 1;

  insert into public.staff (name, email, role, active)
  values ('ZZ Baseline Other', 'zz-baseline@example.test', 'Billing', true) returning id into v_other;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_o_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-baseline@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_o_uid where id = v_other;

  perform set_config('role', 'authenticated', true);

  -- ── it is Admin's ─────────────────────────────────────────
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_o_uid, 'role', 'authenticated')::text, true);
  begin
    perform public.take_money_baseline(v_as_of, 'ZZ not mine to take');
    failures := failures || 'FAILED: somebody who is not an Admin took a baseline'::text;
  exception when insufficient_privilege then
    raise notice 'ok  the practice''s baseline is Admin''s to take';
  end;

  if v_a_uid is null then
    raise notice '--  no Admin with a sign-in to test the rest as';
  else
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_a_uid, 'role', 'authenticated')::text, true);

    -- ── the figures are the screen's ────────────────────────
    select coalesce(sum(e.received), 0) into v_screen
      from public.authorization_economics e
      join public.authorizations a on a.id = e.auth_id
     where a.received_on is null or a.received_on <= v_as_of;

    select public.take_money_baseline(v_as_of, 'ZZ baseline') into v_id;

    select received into v_kept from public.money_baselines where id = v_id;
    if round(coalesce(v_kept, -1), 2) <> round(v_screen, 2) then
      failures := failures ||
        format('FAILED: the baseline kept %s received and the screen shows %s', v_kept, v_screen)::text;
    else
      raise notice 'ok  what it kept is what the Money screen shows (% received)', round(v_kept, 2);
    end if;

    -- ── taken once ──────────────────────────────────────────
    begin
      perform public.take_money_baseline(v_as_of, 'ZZ again');
      failures := failures || 'FAILED: a second baseline was taken for the same day'::text;
    exception when unique_violation then
      raise notice 'ok  and only once for a day';
    end;

    -- ── a day that has not happened ─────────────────────────
    begin
      perform public.take_money_baseline(public.practice_today() + 30, 'ZZ the future');
      failures := failures || 'FAILED: a baseline was taken for a day that has not happened'::text;
    exception when check_violation then
      raise notice 'ok  and not for a day that has not happened yet';
    end;

    -- ── frozen ──────────────────────────────────────────────
    begin
      update public.money_baselines set received = 999999 where id = v_id;
      failures := failures || 'FAILED: a baseline figure was edited after it was taken'::text;
    exception when check_violation or insufficient_privilege then
      raise notice 'ok  a figure cannot be changed after it is taken';
    end;

    /*
     * Checked by looking for the row afterwards, not by waiting for a
     * refusal. There is no delete policy, so RLS matches no rows and reports
     * success - an assertion that expected an exception would have passed
     * whether or not the row survived. The trigger is still there for
     * anybody later granted delete.
     */
    delete from public.money_baselines where id = v_id;
    select count(*) into v_n from public.money_baselines where id = v_id;
    if v_n <> 1 then
      failures := failures || 'FAILED: a baseline was deleted'::text;
    else
      raise notice 'ok  and it cannot be deleted';
    end if;

    -- ── but a note may be added ─────────────────────────────
    update public.money_baselines set note = 'ZZ checked against the bank' where id = v_id;
    if (select note from public.money_baselines where id = v_id) <> 'ZZ checked against the bank' then
      failures := failures || 'FAILED: a note could not be added to a baseline'::text;
    else
      raise notice 'ok  while a note may be added, because explaining it is not altering it';
    end if;
  end if;

  -- ── somebody who is not an Admin cannot read them ─────────
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_o_uid, 'role', 'authenticated')::text, true);
  select count(*) into v_n from public.money_baselines;
  if v_n > 0 then
    failures := failures || 'FAILED: somebody who is not an Admin read the practice''s baselines'::text;
  else
    raise notice 'ok  and nobody but Admin reads them';
  end if;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('role', 'postgres', true);

  if has_function_privilege('anon', 'public.take_money_baseline(date, text)', 'execute') then
    failures := failures || 'FAILED: anon may take a baseline'::text;
  else
    raise notice 'ok  anon cannot take one';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- BASELINE VERIFIED ---';
end $$;

rollback;
