-- Zion Vocational Rehab CRM — one view of the money this month (0337)
--
-- What has to hold:
--
--   The month is this month. An invoice sent last month is not in this
--   month's figure, and a payment dated last month is not either - by the
--   warrant's date, not by the day somebody typed it in.
--
--   "To bill" is delivered and not invoiced, which is the owner's ruling of
--   9 November. A row whose bill-by date has gone by with nothing delivered
--   is not in it, and neither is one that has been invoiced.
--
--   "Overdue" is a fortnight of that, and nothing else.
--
--   "Outstanding" is sent and not paid in full. A rejected invoice is not
--   money owed: it is an invoice to raise again.
--
--   And the figure the Home tile shows is the figure this function gives,
--   because the owner's rule is that the tile and the screen it opens read
--   one view.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_admin uuid; v_admin_uid uuid := gen_random_uuid();
  v_client uuid;
  v_delivered uuid; v_late uuid; v_waiting uuid; v_invoiced uuid;
  v_before numeric; v_after numeric;
  v_count integer; v_tile integer;
  r record;
  failures text[] := '{}';
begin
  insert into public.staff (name, email, role, active)
  values ('ZZ Overview Admin', 'zz-overview-admin@example.test', 'Admin', true) returning id into v_admin;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_admin_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-overview-admin@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_admin_uid where id = v_admin;

  insert into public.clients (name, stage, status, assigned_staff_id, phone)
  values ('ZZ Overview Person', 'Job Search', 'Active', v_admin, '+13855550201') returning id into v_client;

  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_admin_uid, 'role', 'authenticated')::text, true);

  select * into r from public.billing_overview();
  v_before := r.to_bill;

  -- ── delivered and not invoiced is the work to bill ─────────
  insert into public.authorizations
    (client_id, number, service_type, rate_type, rate, status, start_date, end_date, bill_by, delivered_on)
  values (v_client, 'V0000961', 'WSA Tier 2', 'Flat Fee', 585, 'Due',
          public.practice_today() - 60, public.practice_today() + 60,
          public.practice_today() - 2, public.practice_today() - 2)
  returning id into v_delivered;

  select * into r from public.billing_overview();
  if r.to_bill <> v_before + 585 then
    failures := failures || format('FAILED: a delivered row of 585 moved "to bill" from %s to %s',
                                   v_before, r.to_bill)::text;
  elsif r.overdue_count <> 0 then
    failures := failures || format('FAILED: delivered two days ago counts as %s overdue', r.overdue_count)::text;
  else
    raise notice 'ok  delivered and not invoiced is the work to bill, and two days is not overdue';
  end if;

  -- ── a fortnight of it is overdue ───────────────────────────
  insert into public.authorizations
    (client_id, number, service_type, rate_type, rate, status, start_date, end_date, bill_by, delivered_on)
  values (v_client, 'V0000962', 'Job Development', 'Flat Fee', 560, 'Due',
          public.practice_today() - 90, public.practice_today() + 30,
          public.practice_today() - 20, public.practice_today() - 20)
  returning id into v_late;

  select * into r from public.billing_overview();
  if r.overdue_count <> 1 then
    failures := failures || format('FAILED: one row delivered twenty days ago counts as %s overdue',
                                   r.overdue_count)::text;
  else
    raise notice 'ok  a fortnight delivered and not invoiced is the overdue count';
  end if;

  -- ── and nothing delivered is in neither ────────────────────
  v_before := r.to_bill;
  insert into public.authorizations
    (client_id, number, service_type, rate_type, rate, status, start_date, end_date, bill_by)
  values (v_client, 'V0000963', 'Job Placement', 'Flat Fee', 2250, 'Due',
          public.practice_today() - 120, public.practice_today() + 30,
          public.practice_today() - 40)
  returning id into v_waiting;

  select * into r from public.billing_overview();
  if r.to_bill <> v_before then
    failures := failures || format(
      'FAILED: a row 40 days past its bill-by date with nothing delivered moved "to bill" to %s', r.to_bill)::text;
  else
    raise notice 'ok  a bill-by date that has gone by is not work to bill — the owner''s ruling';
  end if;

  -- ── what went out this month, and what did not ─────────────
  select * into r from public.billing_overview();
  v_before := r.submitted_this_month;

  insert into public.invoices (client_id, auth_id, number, submitted_on, submitted_by, amount, source)
  values (v_client, v_delivered, 990101,
          greatest(date_trunc('month', public.practice_today())::date, public.practice_today() - 3),
          v_admin, 585, 'Backfill');
  insert into public.invoices (client_id, auth_id, number, submitted_on, submitted_by, amount, source)
  values (v_client, v_waiting, 990102,
          (date_trunc('month', public.practice_today()) - interval '1 month')::date,
          v_admin, 2250, 'Backfill');

  select * into r from public.billing_overview();
  if r.submitted_this_month <> v_before + 585 then
    failures := failures || format(
      'FAILED: one invoice of 585 this month and one of 2250 last month moved the figure from %s to %s',
      v_before, r.submitted_this_month)::text;
  else
    raise notice 'ok  the month is this month, and last month''s invoice is not in it';
  end if;

  -- ── and an invoiced row is no longer to bill ───────────────
  select * into r from public.billing_overview();
  if exists (select 1 from public.billing_worklist() w
              where w.id = v_delivered and w.delivered_on is not null and not w.invoiced) then
    failures := failures || 'FAILED: an invoiced row is still delivered-and-not-invoiced'::text;
  else
    raise notice 'ok  an invoiced row comes off the work to bill';
  end if;

  -- ── outstanding is sent and not paid in full ───────────────
  select outstanding, outstanding_count into v_before, v_count from public.billing_overview();
  update public.invoices set status = 'Rejected' where number = 990102;
  select outstanding, outstanding_count into v_after, v_count from public.billing_overview();
  if v_after <> v_before - 2250 then
    failures := failures || format(
      'FAILED: rejecting a 2250 invoice moved what is owed from %s to %s', v_before, v_after)::text;
  else
    raise notice 'ok  a rejected invoice is not money owed — it is one to raise again';
  end if;

  -- ── what came back, by the warrant''s date ─────────────────
  select paid_this_month into v_before from public.billing_overview();
  insert into public.payments
    (auth_id, amount, warrant_no, warrant_date, voucher, source, recorded_by, recorded_by_name)
  values (v_delivered, 585, 'F99000999',
          greatest(date_trunc('month', public.practice_today())::date, public.practice_today() - 1),
          '99AW00000000011', 'By hand', v_admin, 'ZZ Overview Admin');
  insert into public.payments
    (auth_id, amount, warrant_no, warrant_date, voucher, source, recorded_by, recorded_by_name)
  values (v_late, 560, 'F99000998',
          (date_trunc('month', public.practice_today()) - interval '1 month')::date,
          '99AW00000000012', 'By hand', v_admin, 'ZZ Overview Admin');

  select paid_this_month into v_after from public.billing_overview();
  if v_after <> v_before + 585 then
    failures := failures || format(
      'FAILED: one warrant this month and one last month moved what was paid from %s to %s',
      v_before, v_after)::text;
  else
    raise notice 'ok  what came back is counted by the warrant''s date, not by the day it was typed';
  end if;

  -- ── and the tile reads this view ───────────────────────────
  select needs_attention into v_count from public.billing_overview();
  v_tile := public.billing_needs_action();
  if v_count is distinct from v_tile then
    failures := failures || format(
      'FAILED: the overview says %s rows need something and the Home tile says %s', v_count, v_tile)::text;
  else
    raise notice 'ok  the Home tile and the Billing overview are the same number';
  end if;

  perform set_config('request.jwt.claims', '', true);

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, chr(10));
  end if;
end $$;

rollback;
