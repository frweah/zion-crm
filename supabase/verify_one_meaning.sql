-- Zion Vocational Rehab CRM — one meaning for each figure (0122)
--
-- What has to hold, each tried from the direction that would break it:
--
--   A flat fee with a completion says what the record's header says: that
--   much earned and not yet invoiced, the same figure as its unbilled.
--
--   Money nobody has earned yet is never called "not invoiced" - the header
--   would be showing one number and the card beside it another.
--
--   A flat fee is never told it has no hours. It has none to log.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_staff uuid;
  v_client uuid;
  v_flat uuid;
  v_hourly uuid;
  v_detail text;
  v_unbilled numeric;
  failures text[] := '{}';
begin
  insert into public.staff (name, email, role, active) values ('ZZ Meaning Staff', 'zz-meaning@example.test', 'Job Search', true) returning id into v_staff;
  insert into public.clients (name, stage, status, assigned_staff_id)
  values ('ZZ Meaning Client', 'Job Placement', 'Active', v_staff) returning id into v_client;

  -- A flat fee, completed inside its dates and not yet invoiced.
  insert into public.authorizations (client_id, number, service_type, rate_type, rate, status, start_date, end_date)
  values (v_client, 'V0000771', 'Job Placement', 'Flat Fee', 2250, 'Authorized', public.practice_today() - 20, public.practice_today() + 10)
  returning id into v_flat;
  update public.completions set completion = public.practice_today() - 2 where auth_id = v_flat;

  -- An hourly one with nothing logged.
  insert into public.authorizations (client_id, number, service_type, total_hours, rate_type, rate, status, start_date, end_date)
  values (v_client, 'V0000772', 'Job Coaching', 20, 'Hourly', 45, 'Authorized', public.practice_today() - 20, public.practice_today() + 10)
  returning id into v_hourly;

  select what into v_detail from public.next_steps('client', null, v_client) where what like '%V0000771%';
  select unbilled into v_unbilled from public.authorization_economics where auth_id = v_flat;

  -- The owner's audit of 25 September 2026 - each figure said in the words it
  -- means - lived in the prose of client_next_actions, which the one-engine
  -- phase removed. The engine carries the sentence the board and the bell
  -- share, and the money words cannot move into it because the board shows
  -- what it returns and that screen carries no money.
  --
  -- So this asserts what is still true, and says what is waiting on a
  -- decision rather than quietly dropping it.
  raise notice 'PENDING: the 25 Sept wording of the money figures has no home since the strip stopped carrying it';

  if v_detail is null then
    failures := failures || 'FAILED: a completed flat fee raises nothing at all'::text;
  elsif v_detail like '%hours logged%' then
    failures := failures || 'FAILED: a flat fee was told it has no hours logged'::text;
  else
    raise notice 'ok  a completed flat fee with money on it is still flagged';
  end if;

  select what into v_detail from public.next_steps('client', null, v_client) where what like '%V0000772%';
  if v_detail is null then
    failures := failures || 'FAILED: work nobody has done yet raises nothing at all'::text;
  elsif v_detail like '%not invoiced%' then
    failures := failures || 'FAILED: money nobody has earned is being called "not invoiced"'::text;
  else
    raise notice 'ok  money nobody has earned yet is never called "not invoiced"';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
