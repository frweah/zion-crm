-- Zion Vocational Rehab CRM — authorized is not delivered (0325)
--
-- What has to hold:
--
--   A row with nothing delivered says "Waiting for service" and says it
--   quietly. Its bill-by date, however long past, does not make it late:
--   that was the owner's ruling of 9 November and it is the whole point.
--
--   A row whose service was delivered and which has not been invoiced is the
--   Needs billing list, and after fourteen days it is the one thing the
--   practice chases.
--
--   A delivery date cannot be in the future, cannot be before the
--   authorization began, and cannot be put on a coaching authorization whose
--   months are the thing delivered.
--
--   Changing a delivery date already recorded needs a reason, and the reason
--   goes in the correction log.
--
--   What an authorization is worth comes from the strongest evidence there
--   is, in order: invoiced, logged, flat fee, authorized - and it says which.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_admin uuid; v_admin_uid uuid := gen_random_uuid();
  v_client uuid;
  v_flat uuid; v_hourly uuid; v_parent uuid; v_month uuid;
  v_amount numeric; v_basis text;
  v_attention text; v_urgency integer;
  v_text text; v_rows integer;
  failures text[] := '{}';
begin
  -- ── the practice ───────────────────────────────────────────
  insert into public.staff (name, email, role, active)
  values ('ZZ Delivery Admin', 'zz-delivery-admin@example.test', 'Admin', true) returning id into v_admin;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_admin_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-delivery-admin@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_admin_uid where id = v_admin;

  insert into public.clients (name, stage, status, assigned_staff_id)
  values ('ZZ Delivered Person', 'Job Search', 'Active', v_admin) returning id into v_client;

  -- A flat fee whose bill-by date went by a month ago. Before the ruling this
  -- row read "Overdue - meant to be billed by ..." in red.
  insert into public.authorizations
    (client_id, number, service_type, rate_type, rate, total_hours, status,
     start_date, end_date, bill_by)
  values (v_client, 'V0000931', 'WSA Tier 2', 'Flat Fee', 585, null, 'Due',
          public.practice_today() - 120, public.practice_today() + 60,
          public.practice_today() - 30)
  returning id into v_flat;

  -- Life Skills rather than Job Coaching: coaching is the one monthly service,
  -- and an hour logged against a coaching authorization is routed onto a month
  -- of it, so the hours would land somewhere other than this row. Which is
  -- correct, and is why this row is a service that has no months.
  insert into public.authorizations
    (client_id, number, service_type, rate_type, rate, total_hours, status, start_date, end_date)
  values (v_client, 'V0000932', 'Life Skills', 'Hourly', 45, 20, 'Due',
          public.practice_today() - 60, public.practice_today() + 60)
  returning id into v_hourly;

  insert into public.authorizations
    (client_id, number, service_type, rate_type, rate, total_hours, status, start_date, end_date)
  values (v_client, 'V0000933', 'Job Coaching', 'Hourly', 45, 20, 'Authorized',
          public.practice_today() - 60, public.practice_today() + 60)
  returning id into v_parent;
  insert into public.authorizations
    (client_id, parent_id, service_type, rate_type, rate, status, period, start_date, end_date)
  values (v_client, v_parent, 'Job Coaching', 'Hourly', 45, 'Authorized',
          date_trunc('month', public.practice_today())::date,
          public.practice_today() - 60, public.practice_today() + 60)
  returning id into v_month;

  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_admin_uid, 'role', 'authenticated')::text, true);

  -- ── a bill-by date that has gone by is not a late bill ─────
  select attention, urgency into v_attention, v_urgency
    from public.authorization_attention(v_flat);
  if v_attention <> 'Waiting for service' then
    failures := failures || format(
      'FAILED: a flat fee 30 days past its bill-by date with nothing delivered says "%s"', v_attention)::text;
  elsif v_urgency <= 6 then
    failures := failures || format(
      'FAILED: "Waiting for service" came back at urgency %s, which puts a colour on it', v_urgency)::text;
  else
    raise notice 'ok  nothing delivered is "Waiting for service", whatever the bill-by date says';
  end if;

  -- ── delivered and not invoiced is the one thing to do ──────
  perform public.set_service_delivered(v_flat, public.practice_today() - 3, '');
  select attention, urgency into v_attention, v_urgency
    from public.authorization_attention(v_flat);
  if v_attention not like 'Delivered %not invoiced' then
    failures := failures || format('FAILED: delivered three days ago and not invoiced says "%s"', v_attention)::text;
  elsif v_urgency <> 6 then
    failures := failures || format('FAILED: delivered and not invoiced came back at urgency %s', v_urgency)::text;
  else
    raise notice 'ok  delivered and not invoiced is the Needs billing row, and it is amber';
  end if;

  -- ── and fourteen days of it is the chase ───────────────────
  perform public.set_service_delivered(v_flat, public.practice_today() - 14,
                                       'Checking what fourteen days reads as');
  select attention, urgency into v_attention, v_urgency
    from public.authorization_attention(v_flat);
  if v_attention not like '%not invoiced after 14 days' then
    failures := failures || format('FAILED: fourteen days delivered and not invoiced says "%s"', v_attention)::text;
  elsif v_urgency > 3 then
    failures := failures || format('FAILED: the only chase there is came back at urgency %s', v_urgency)::text;
  else
    raise notice 'ok  fourteen days delivered and not invoiced is the chase, and it is red';
  end if;

  -- ── the reason is on the record ────────────────────────────
  select count(*) into v_rows from public.authorization_corrections
   where auth_id = v_flat and field = 'Service delivered'
     and reason = 'Checking what fourteen days reads as';
  if v_rows <> 1 then
    failures := failures || format(
      'FAILED: changing the delivery date wrote %s correction-log row(s), not one', v_rows)::text;
  else
    raise notice 'ok  changing a delivery date already recorded is in the correction log, with its reason';
  end if;

  -- ── and a change with no reason is refused ─────────────────
  v_text := '';
  begin
    perform public.set_service_delivered(v_flat, public.practice_today() - 1, '');
    v_text := 'allowed';
  exception when check_violation then
    v_text := sqlerrm;
  end;
  if v_text = 'allowed' then
    failures := failures || 'FAILED: a delivery date was changed with no reason given'::text;
  elsif v_text not like '%Say why%' then
    failures := failures || format('FAILED: refused, but not in a sentence: %s', v_text)::text;
  else
    raise notice 'ok  changing a delivery date without saying why is refused, in a sentence';
  end if;

  -- ── clearing it puts the row back to waiting ───────────────
  perform public.set_service_delivered(v_flat, null, 'It was not finished after all');
  select attention into v_attention from public.authorization_attention(v_flat);
  if v_attention <> 'Waiting for service' then
    failures := failures || format('FAILED: a cleared delivery date leaves the row saying "%s"', v_attention)::text;
  else
    raise notice 'ok  clearing the date puts the row back to waiting for service';
  end if;

  -- ── tomorrow has not happened ──────────────────────────────
  v_text := '';
  begin
    perform public.set_service_delivered(v_hourly, public.practice_today() + 1, '');
    v_text := 'allowed';
  exception when check_violation then
    v_text := sqlerrm;
  end;
  if v_text = 'allowed' then
    failures := failures || 'FAILED: a service was delivered tomorrow'::text;
  else
    raise notice 'ok  a service cannot have been delivered tomorrow';
  end if;

  -- ── nor before the authorization began ─────────────────────
  v_text := '';
  begin
    perform public.set_service_delivered(v_hourly, public.practice_today() - 100, '');
    v_text := 'allowed';
  exception when check_violation then
    v_text := sqlerrm;
  end;
  if v_text = 'allowed' then
    failures := failures || 'FAILED: a service was delivered before the authorization started'::text;
  else
    raise notice 'ok  nor before the authorization it is on began';
  end if;

  -- ── a coaching authorization is not delivered ──────────────
  v_text := '';
  begin
    perform public.set_service_delivered(v_parent, public.practice_today(), '');
    v_text := 'allowed';
  exception when check_violation then
    v_text := sqlerrm;
  end;
  if v_text = 'allowed' then
    failures := failures || 'FAILED: a coaching authorization was marked delivered rather than its month'::text;
  elsif v_text not like '%its months are%' then
    failures := failures || format('FAILED: refused, but not in a sentence: %s', v_text)::text;
  else
    raise notice 'ok  a coaching authorization is not delivered — its months are';
  end if;

  perform public.set_service_delivered(v_month, public.practice_today(), '');
  raise notice 'ok  and the month is';

  -- ── what the row is worth, and on what evidence ────────────
  select amount, basis into v_amount, v_basis
    from public.authorization_amount_for(array[v_hourly]);
  if v_basis <> 'Authorized' or v_amount <> 900 then
    failures := failures || format(
      'FAILED: an hourly row with nothing logged came to %s on %s, not 900.00 on Authorized',
      v_amount, v_basis)::text;
  else
    raise notice 'ok  nothing invoiced and nothing logged: what the authorization allows, said to be that';
  end if;

  insert into public.service_entries (auth_id, date, hours, notes, staff_id)
  values (v_hourly, public.practice_today() - 10, 4, 'ZZ life skills session', v_admin);
  select amount, basis into v_amount, v_basis
    from public.authorization_amount_for(array[v_hourly]);
  if v_basis <> 'Logged' or v_amount <> 180 then
    failures := failures || format('FAILED: four hours at 45 came to %s on %s', v_amount, v_basis)::text;
  else
    raise notice 'ok  hours logged beat the ceiling, at the rate on the record';
  end if;

  insert into public.invoices (client_id, auth_id, submitted_on, submitted_by, amount, source)
  values (v_client, v_hourly, public.practice_today(), v_admin, 225, 'Backfill');
  select amount, basis into v_amount, v_basis
    from public.authorization_amount_for(array[v_hourly]);
  if v_basis <> 'Invoiced' or v_amount <> 225 then
    failures := failures || format(
      'FAILED: an invoice for 225 against four logged hours came to %s on %s', v_amount, v_basis)::text;
  else
    raise notice 'ok  and what was invoiced beats the hours — a figure sent to the state is a fact';
  end if;

  select amount, basis into v_amount, v_basis
    from public.authorization_amount_for(array[v_flat]);
  if v_basis <> 'Flat fee' or v_amount <> 585 then
    failures := failures || format('FAILED: a flat fee came to %s on %s', v_amount, v_basis)::text;
  else
    raise notice 'ok  a flat fee is the fee';
  end if;

  -- ── and an invoiced row is no longer waiting to be billed ──
  select attention into v_attention from public.authorization_attention(v_hourly);
  if v_attention like 'Delivered%' then
    failures := failures || format(
      'FAILED: an invoiced row is still on the Needs billing list: "%s"', v_attention)::text;
  else
    raise notice 'ok  an invoiced row is off the Needs billing list';
  end if;

  perform set_config('request.jwt.claims', '', true);

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
