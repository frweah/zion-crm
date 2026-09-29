-- Zion Vocational Rehab CRM — the billing item keeps its own rules (0123-0125)
--
-- What has to hold, each tried from the direction that would break it:
--
--   The same authorization cannot be billed twice for the same period, and
--   two authorizations for one client, service and month can both be billed -
--   because the year's paperwork says that happened nine times.
--
--   An item cannot carry a service its authorization is not for.
--
--   Submitted without a date or a recipient, Paid without a payment, and
--   Closed without a reason are all impossible - not discouraged.
--
--   A closed item is locked to everybody but an Admin.
--
--   Every change of status writes down who made it.
--
--   The gate notices service dates that were copied from the authorization,
--   and passes once they are the work's own.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_staff uuid;
  v_client uuid;
  v_auth_a uuid;
  v_auth_b uuid;
  v_other uuid;
  v_item uuid;
  v_item_b uuid;
  v_n integer;
  v_detail text;
  v_passed boolean;
  failures text[] := '{}';
begin
  insert into public.staff (name, email, role, active) values ('ZZ Item Staff', 'zz-item@example.test', 'Billing', true) returning id into v_staff;
  insert into public.clients (name, stage, status, assigned_staff_id, billing_staff_id)
  values ('ZZ Item Client', 'Job Coaching', 'Active', v_staff, v_staff) returning id into v_client;

  insert into public.authorizations (client_id, number, service_type, total_hours, rate_type, rate, status, start_date, end_date)
  values (v_client, 'V0000901', 'Job Coaching', 40, 'Hourly', 45, 'Open', public.practice_today() - 60, public.practice_today() + 30)
  returning id into v_auth_a;
  insert into public.authorizations (client_id, number, service_type, total_hours, rate_type, rate, status, start_date, end_date)
  values (v_client, 'V0000902', 'Job Coaching', 40, 'Hourly', 45, 'Open', public.practice_today() - 60, public.practice_today() + 30)
  returning id into v_auth_b;
  insert into public.authorizations (client_id, number, service_type, rate_type, rate, status, start_date, end_date)
  values (v_client, 'V0000903', 'Job Placement', 'Flat Fee', 2250, 'Open', public.practice_today() - 60, public.practice_today() + 30)
  returning id into v_other;

  insert into public.billing_items (client_id, auth_id, service, period, status, billing_type, rate)
  values (v_client, v_auth_a, 'Job Coaching', date_trunc('month', public.practice_today())::date, 'Service in progress', 'Hourly', 45)
  returning id into v_item;

  -- ── the same authorization, the same month, twice ─────────
  begin
    insert into public.billing_items (client_id, auth_id, service, period, status)
    values (v_client, v_auth_a, 'Job Coaching', date_trunc('month', public.practice_today())::date, 'Service in progress');
    failures := failures || 'FAILED: the same authorization was billed twice for one month'::text;
  exception when unique_violation then null;
  end;

  -- ── a second authorization for the same month is allowed ──
  begin
    insert into public.billing_items (client_id, auth_id, service, period, status, billing_type, rate)
    values (v_client, v_auth_b, 'Job Coaching', date_trunc('month', public.practice_today())::date, 'Service in progress', 'Hourly', 45)
    returning id into v_item_b;
    raise notice 'ok  one item per authorization: the same one twice is refused, a second authorization is not';
  exception when unique_violation then
    failures := failures || 'FAILED: a client with two coaching authorizations cannot bill both for a month'::text;
  end;

  -- ── an item cannot carry the wrong service ────────────────
  begin
    update public.billing_items set auth_id = v_other where id = v_item;
    failures := failures || 'FAILED: a Job Coaching item took a Job Placement authorization'::text;
  exception when check_violation then
    raise notice 'ok  an item cannot carry a service its authorization is not for';
  end;

  -- ── Submitted, Paid and Closed cannot be typed ────────────
  begin
    update public.billing_items set status = 'Submitted' where id = v_item;
    failures := failures || 'FAILED: Submitted without a submission date or a recipient'::text;
  exception when check_violation then null;
  end;

  begin
    update public.billing_items set status = 'Paid' where id = v_item;
    failures := failures || 'FAILED: Paid without a payment date or an amount'::text;
  exception when check_violation then null;
  end;

  begin
    update public.billing_items set status = 'Closed' where id = v_item;
    failures := failures || 'FAILED: Closed without a reason'::text;
  exception when check_violation then
    raise notice 'ok  Submitted, Paid and Closed each refuse to be a status somebody typed';
  end;

  -- ── every move is written down ────────────────────────────
  update public.billing_items
     set status = 'Service period complete', service_end = public.practice_today() - 1
   where id = v_item;
  select count(*) into v_n from public.billing_item_events
   where item_id = v_item and became = 'Service period complete';
  if v_n <> 1 then
    failures := failures || format('FAILED: a change of status wrote %s history rows, not 1', v_n);
  else
    raise notice 'ok  every change of status is written down';
  end if;

  -- ── the gate notices the authorization's dates copied over ─
  update public.billing_items
     set service_start = (select start_date from public.authorizations where id = v_auth_a),
         service_end = (select end_date from public.authorizations where id = v_auth_a)
   where id = v_item;
  select passed, detail into v_passed, v_detail
    from public.billing_item_gate(v_item) where line = 'Service dates recorded, and their own';
  if v_passed then
    failures := failures || 'FAILED: the gate accepted the authorization''s dates as the service''s own'::text;
  end if;

  update public.billing_items
     set service_start = public.practice_today() - 20, service_end = public.practice_today() - 2
   where id = v_item;
  select passed into v_passed
    from public.billing_item_gate(v_item) where line = 'Service dates recorded, and their own';
  if not v_passed then
    failures := failures || 'FAILED: the gate refused dates that are the work''s own'::text;
  else
    raise notice 'ok  service dates are the work''s own, and the gate can tell';
  end if;

  -- ── a closed item is locked ───────────────────────────────
  update public.billing_items
     set status = 'Closed', closed_reason = 'ZZ the client stopped services'
   where id = v_item;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
  begin
    update public.billing_items set notes = 'ZZ changed after closing' where id = v_item;
    get diagnostics v_n = row_count;
    if v_n > 0 then
      failures := failures || 'FAILED: a closed item was changed by somebody who is not an Admin'::text;
    else
      raise notice 'ok  a closed item is locked - and the rules do not even show it to a stranger';
    end if;
  exception when check_violation then
    raise notice 'ok  a closed item refuses to be changed by anybody but an Admin';
  end;
  perform set_config('role', 'postgres', true);

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
