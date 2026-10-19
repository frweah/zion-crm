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
  v_client uuid;
  v_id2    uuid;
  v_dts    numeric;
  v_dtp    numeric;
  v_place  integer;
  v_r4     integer;
  v_k4     integer;
  v_r90    integer;
  v_k90    integer;
  v_stages jsonb;
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


    /*
     * The work, not only the money.
     *
     * The distinction these assertions protect: a measure with nothing to
     * measure is *unknown*, not nought. "0 days to submit" reads as "same
     * day" and "0 of 0 retained" reads as "nobody kept their job", and both
     * would be quoted at the practice by somebody who had not read the
     * footnote.
     */
    -- The fixtures are written as postgres: an authorization is added
    -- through add_authorization in the app and RLS refuses a direct insert,
    -- which is itself a rule tested elsewhere.
    perform set_config('role', 'postgres', true);
    insert into public.clients (name, stage, status) values ('ZZ Measure Client', 'Placement', 'Active')
    returning id into v_client;

    -- An authorization that took ten days to submit and thirty more to pay.
    insert into public.authorizations (client_id, number, service_type, rate_type, rate,
                                       start_date, end_date, received_on, status,
                                       submitted_on, paid_on, paid_amount)
    values (v_client, 'ZZ-M-1', 'Job Placement', 'Flat Fee', 1000,
            v_as_of - 90, v_as_of - 10, v_as_of - 60, 'Paid',
            v_as_of - 50, v_as_of - 20, 1000);

    -- A placement that started long enough ago to have been checked, and was.
    insert into public.placements (client_id, employer, title, start_date, check30, check90)
    values (v_client, 'ZZ Employer', 'ZZ Job', v_as_of - 120, v_as_of - 90, v_as_of - 30);
    -- And one too recent for a 90-day check to be owed.
    insert into public.placements (client_id, employer, title, start_date)
    values (v_client, 'ZZ Employer', 'ZZ Recent', v_as_of - 30);

    perform set_config('role', 'authenticated', true);
    select public.take_money_baseline(v_as_of - 1, 'ZZ measured') into v_id2;

    select days_to_submit, days_to_pay, placements, retained_4w, known_4w,
           retained_90d, known_90d, by_stage
      into v_dts, v_dtp, v_place, v_r4, v_k4, v_r90, v_k90, v_stages
      from public.money_baselines where id = v_id2;

    if coalesce(v_dts, -1) <> 10 then
      failures := failures || format('FAILED: the median to submit reads %s, not the 10 days it took', v_dts)::text;
    else
      raise notice 'ok  the median days to submit is measured (%)', v_dts;
    end if;

    if coalesce(v_dtp, -1) <> 30 then
      failures := failures || format('FAILED: the median to pay reads %s, not 30', v_dtp)::text;
    else
      raise notice 'ok  and the median days to pay (%)', v_dtp;
    end if;

    if v_place < 2 then
      failures := failures || format('FAILED: %s placements counted, not the 2 started this year', v_place)::text;
    else
      raise notice 'ok  placements started in the year are counted (%)', v_place;
    end if;

    /*
     * Asserted as a relationship rather than as totals, because the practice
     * has real placements on file and a fixture cannot know how many. The
     * first version expected "1 of 2" and failed at "1 of 8" - the measure
     * was right and the assertion was counting a table it did not own.
     */
    if v_r4 < 1 or v_r4 > v_k4 then
      failures := failures || format('FAILED: 4-week retention reads %s of %s', v_r4, v_k4)::text;
    else
      raise notice 'ok  4-week retention is % of %, and never more than were eligible', v_r4, v_k4;
    end if;

    if v_r90 < 1 or v_r90 > v_k90 then
      failures := failures || format('FAILED: 90-day retention reads %s of %s', v_r90, v_k90)::text;
    elsif v_k90 >= v_k4 then
      failures := failures ||
        format('FAILED: the 90-day denominator (%s) is not smaller than the 4-week one (%s), so a placement too recent to have been checked is being counted against it', v_k90, v_k4)::text;
    else
      raise notice 'ok  and the 90-day denominator (%) is smaller than the 4-week one (%), so a placement too recent to have been checked is not counted against it', v_k90, v_k4;
    end if;

    if coalesce(v_stages ->> 'Placement', '0')::int < 1 then
      failures := failures || 'FAILED: the stage counts do not include the client just added'::text;
    else
      raise notice 'ok  clients are counted by stage (% at Placement)', v_stages ->> 'Placement';
    end if;

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
