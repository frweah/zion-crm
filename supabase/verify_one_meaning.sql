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
  values ('ZZ Meaning Client', 'Placement', 'Active', v_staff) returning id into v_client;

  -- A flat fee, completed inside its dates and not yet invoiced.
  insert into public.authorizations (client_id, number, service_type, rate_type, rate, status, start_date, end_date)
  values (v_client, 'V0000771', 'Job Placement', 'Flat Fee', 2250, 'Open', public.practice_today() - 20, public.practice_today() + 10)
  returning id into v_flat;
  update public.completions set completion = public.practice_today() - 2 where auth_id = v_flat;

  -- An hourly one with nothing logged.
  insert into public.authorizations (client_id, number, service_type, total_hours, rate_type, rate, status, start_date, end_date)
  values (v_client, 'V0000772', 'Job Coaching', 20, 'Hourly', 45, 'Open', public.practice_today() - 20, public.practice_today() + 10)
  returning id into v_hourly;

  select detail into v_detail from public.client_next_actions(v_client) where title like '%V0000771%';
  select unbilled into v_unbilled from public.authorization_economics where auth_id = v_flat;

  if v_detail is null or v_detail not like '%earned and not yet invoiced%' then
    failures := failures || format('FAILED: a completed flat fee says "%s"', coalesce(v_detail, 'nothing'));
  elsif v_detail not like '%' || trim(to_char(v_unbilled, 'FM$999,990.00')) || '%' then
    failures := failures || format('FAILED: the card says %s where the record''s unbilled figure is %s', v_detail, v_unbilled);
  elsif v_detail like '%hours logged%' then
    failures := failures || 'FAILED: a flat fee was told it has no hours logged'::text;
  else
    raise notice 'ok  a completed flat fee says what the header says: earned, and not yet invoiced';
  end if;

  select detail into v_detail from public.client_next_actions(v_client) where title like '%V0000772%';
  if v_detail is null or v_detail not like '%not yet earned%' then
    failures := failures || format('FAILED: work nobody has done yet is not called unearned: "%s"', coalesce(v_detail, 'nothing'));
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
