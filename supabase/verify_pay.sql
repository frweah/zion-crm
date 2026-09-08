-- Zion Vocational Rehab CRM — pay rates
--
-- A rate is the answer to "what was this person paid under, on that day". If
-- that answer can be changed after the fact, it was never an answer. So the
-- rules are: only Admin sets one, the history is not overwritten, only the
-- newest entry can be taken back, and each person sees their own and nobody
-- else's.
--
-- Runs inside a transaction that is rolled back. Nothing here is left behind.

begin;

do $$
declare
  v_admin    uuid;
  v_adm_uid  uuid;
  v_rei      uuid;
  v_rei_uid  uuid;
  v_marg     uuid;
  v_marg_uid uuid;
  v_old      uuid;
  v_new      uuid;
  v_count    int;
  v_rate     numeric;
  v_unit     text;
  v_before   date;
  v_base     int;
  failures   text[] := '{}';
begin
  select id, user_id into v_admin, v_adm_uid  from public.staff where legacy_id = 's1';
  select id, user_id into v_rei,  v_rei_uid   from public.staff where legacy_id = 's2';
  select id, user_id into v_marg, v_marg_uid  from public.staff where legacy_id = 's3';

  -- ── a contractor cannot set their own rate ─────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_rei_uid, 'role', 'authenticated')::text, true);
  begin
    perform public.set_staff_pay(v_rei, 500, 'Hourly', current_date, 'a raise for me');
    failures := failures || 'FAILED: a contractor set their own rate'::text;
  exception when insufficient_privilege then
    raise notice 'ok  a contractor cannot set their own rate';
  end;
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  -- ── as Admin ───────────────────────────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);

  begin
    perform public.set_staff_pay(v_rei, 0, 'Hourly', current_date, '');
    failures := failures || 'FAILED: a rate of zero was accepted'::text;
  exception when check_violation then
    raise notice 'ok  a rate of zero or less is refused';
  end;

  begin
    perform public.set_staff_pay(v_rei, 25, 'Weekly', current_date, '');
    failures := failures || 'FAILED: an unknown rate unit was accepted'::text;
  exception when check_violation then
    raise notice 'ok  a rate is Hourly or Flat, nothing else';
  end;

  -- Rates already on file are real and stay put, so every count below is
  -- measured against what was there before rather than against a literal. A
  -- literal was fine while the table was empty and wrong the day it was not.
  select count(*) into v_base from public.staff_pay where staff_id = v_rei;

  v_old := public.set_staff_pay(v_rei, 22.50, 'Hourly', make_date(2033, 1, 1), 'starting rate');
  v_new := public.set_staff_pay(v_rei, 25.00, 'Hourly', make_date(2033, 7, 1), 'review');

  -- ── a new rate adds to the history, it does not replace it ─
  select count(*) into v_count from public.staff_pay where staff_id = v_rei;
  if v_count <> v_base + 2 then
    failures := failures || format('FAILED: %s rates on file, expected %s', v_count, v_base + 2);
  else
    raise notice 'ok  a new rate adds to the history rather than replacing it';
  end if;

  begin
    perform public.set_staff_pay(v_rei, 30, 'Hourly', make_date(2033, 7, 1), 'again');
    failures := failures || 'FAILED: two rates were recorded from the same day'::text;
  exception when unique_violation then
    raise notice 'ok  two rates from the same day is refused, not resolved by guessing';
  end;

  -- ── work is priced at the rate of its own day ──────────────
  select pay_rate into v_rate from public.pay_rate_on(v_rei, make_date(2033, 3, 15));
  if v_rate is distinct from 22.50 then
    failures := failures || format('FAILED: March was priced at %s, expected 22.50', v_rate);
  else
    raise notice 'ok  work in March is priced at the rate that applied in March';
  end if;

  select pay_rate, rate_unit into v_rate, v_unit
    from public.pay_rate_on(v_rei, make_date(2033, 9, 1));
  if v_rate is distinct from 25.00 or v_unit <> 'Hourly' then
    failures := failures || format('FAILED: September was priced at %s', v_rate);
  else
    raise notice 'ok  work in September is priced at the later rate';
  end if;

  -- Before every rate this person has, including any already on file.
  select min(effective_from) - 1 into v_before from public.staff_pay where staff_id = v_rei;
  if exists (select 1 from public.pay_rate_on(v_rei, v_before)) then
    failures := failures || 'FAILED: a rate applied before it took effect'::text;
  else
    raise notice 'ok  a rate does not apply before the day it takes effect';
  end if;

  -- ── only the newest can be taken back ──────────────────────
  begin
    perform public.delete_staff_pay(v_old);
    failures := failures || 'FAILED: an earlier rate was deleted'::text;
  exception when check_violation then
    raise notice 'ok  an earlier rate cannot be removed — it is what somebody was paid under';
  end;

  perform public.delete_staff_pay(v_new);
  select count(*) into v_count from public.staff_pay where staff_id = v_rei;
  if v_count <> v_base + 1 then
    failures := failures || 'FAILED: the newest rate could not be removed'::text;
  else
    raise notice 'ok  the newest rate can be removed, which covers a mistyped figure';
  end if;

  -- ── the checklist notices ──────────────────────────────────
  if not (select auto_done from public.staff_checklist
           where staff_id = v_rei and auto_key = 'pay_rate_set') then
    failures := failures || 'FAILED: recording a rate did not complete the checklist item'::text;
  else
    raise notice 'ok  recording a rate completes the onboarding item by itself';
  end if;

  perform public.set_staff_pay(v_marg, 30.00, 'Hourly', make_date(2033, 1, 1), '');

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  -- ── each person sees their own and nobody else's ───────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_rei_uid, 'role', 'authenticated')::text, true);

  -- Whose rates are visible is the property; how many they have is not.
  select count(distinct staff_id) into v_count from public.staff_pay;
  if v_count <> 1 then
    failures := failures || format('FAILED: a contractor saw rates for %s people, expected only themselves', v_count);
  else
    raise notice 'ok  a contractor sees their own rates and only their own';
  end if;

  if exists (select 1 from public.staff_pay where staff_id = v_marg) then
    failures := failures || 'FAILED: a colleague''s rate was visible'::text;
  else
    raise notice 'ok  a colleague''s rate is not visible';
  end if;

  begin
    perform public.delete_staff_pay(v_old);
    failures := failures || 'FAILED: a contractor deleted their own rate'::text;
  exception when insufficient_privilege then
    raise notice 'ok  a contractor cannot delete their own rate either';
  end;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  if failures = '{}' then
    raise notice '';
    raise notice '--- PAY RATES VERIFIED ---';
  else
    raise notice '';
    raise notice '%  PROBLEM(S):', array_length(failures, 1);
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
