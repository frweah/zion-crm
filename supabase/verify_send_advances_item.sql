-- Zion Vocational Rehab CRM — the send is what makes an item Submitted (0128)
--
-- What has to hold, each tried from the direction that would break it:
--
--   Sending a packet for an authorization that has no item opens one, already
--   Submitted, with the address it went to and the moment it went.
--
--   Sending for an authorization that has one moves that one, rather than
--   opening a second beside it.
--
--   The month's item is billed for the month that was sent, not for whatever
--   month it is today.
--
--   An item already Paid is not dragged backwards by a later send.
--
--   The move is written down, like every other move.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_staff uuid;
  v_client uuid;
  v_auth uuid;
  v_flat uuid;
  v_item uuid;
  v_again uuid;
  v_month date := (date_trunc('month', public.practice_today()) - interval '1 month')::date;
  it public.billing_items;
  v_n integer;
  failures text[] := '{}';
begin
  insert into public.staff (name, email, role, active) values ('ZZ Send Staff', 'zz-send@example.test', 'Billing', true) returning id into v_staff;
  insert into public.clients (name, stage, status, assigned_staff_id, billing_staff_id)
  values ('ZZ Send Client', 'Job Coaching', 'Active', v_staff, v_staff) returning id into v_client;

  insert into public.authorizations (client_id, number, service_type, total_hours, rate_type, rate, status, start_date, end_date)
  values (v_client, 'V0000921', 'Job Coaching', 40, 'Hourly', 45, 'Open', public.practice_today() - 90, public.practice_today() + 30)
  returning id into v_auth;
  insert into public.authorizations (client_id, number, service_type, rate_type, rate, status, start_date, end_date)
  values (v_client, 'V0000922', 'Job Placement', 'Flat Fee', 2250, 'Open', public.practice_today() - 90, public.practice_today() + 30)
  returning id into v_flat;

  -- ── nothing there yet: the send opens it ──────────────────
  v_item := public.submit_item_for_form(v_auth, to_char(v_month, 'YYYY-MM'), 'billing@example.test', v_staff);
  select * into it from public.billing_items where id = v_item;
  if v_item is null then
    failures := failures || 'FAILED: sending opened no item at all'::text;
  else
    if it.status <> 'Submitted' then
      failures := failures || format('FAILED: a sent packet left its item at %s', it.status);
    end if;
    if it.recipient is distinct from 'billing@example.test' or it.submitted_at is null then
      failures := failures || 'FAILED: the item does not say where the packet went, or when'::text;
    end if;
    if it.period is distinct from v_month then
      failures := failures || format('FAILED: the month sent was %s and the item says %s', v_month, it.period);
    else
      raise notice 'ok  sending opens the month''s item, already Submitted, and says where it went';
    end if;
  end if;

  -- ── sending again moves the same item ─────────────────────
  v_again := public.submit_item_for_form(v_auth, to_char(v_month, 'YYYY-MM'), 'billing2@example.test', v_staff);
  select count(*) into v_n from public.billing_items
   where client_id = v_client and service = 'Job Coaching' and period = v_month;
  if v_again is distinct from v_item or v_n <> 1 then
    failures := failures || format('FAILED: sending twice left %s items for one month', v_n);
  else
    raise notice 'ok  sending again moves the same item rather than opening a second';
  end if;

  -- ── a one-time service gets one item, with no period ──────
  v_item := public.submit_item_for_form(v_flat, '', 'billing@example.test', v_staff);
  select * into it from public.billing_items where id = v_item;
  if it.period is not null then
    failures := failures || 'FAILED: a one-time service was given a month'::text;
  elsif it.service_end is not null then
    failures := failures || 'FAILED: a one-time item was given a service end date the send does not know'::text;
  else
    raise notice 'ok  a one-time item has no month, and no date the send could not know';
  end if;

  -- ── a paid item is not dragged backwards ──────────────────
  update public.billing_items
     set status = 'Paid', paid_on = public.practice_today(), paid_amount = 2250
   where id = v_item;
  perform public.submit_item_for_form(v_flat, '', 'billing@example.test', v_staff);
  select * into it from public.billing_items where id = v_item;
  if it.status <> 'Paid' then
    failures := failures || format('FAILED: a later send moved a paid item to %s', it.status);
  else
    raise notice 'ok  a paid item is not dragged backwards by a later send';
  end if;

  -- ── and it is written down ────────────────────────────────
  select count(*) into v_n from public.billing_item_events e
   where e.item_id = v_item and e.became = 'Submitted';
  if v_n < 1 then
    failures := failures || 'FAILED: the send left no history on the item'::text;
  else
    raise notice 'ok  the send is written down like every other move';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
