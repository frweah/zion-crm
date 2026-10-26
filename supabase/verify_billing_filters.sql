-- Zion Vocational Rehab CRM — Past, Current, Upcoming, and the month a
-- payment lands in (0256, and correct_payment_date from 0255)
--
-- The client's Billing tab now groups one list three ways instead of showing
-- a working list with the paid ones folded underneath. The groups are decided
-- by `client_authorizations` rather than by the screen, so what has to hold is
-- what the owner asked for on 26 Oct 2026:
--
--   a payment dated last month is counted under last month;
--   correcting the date moves it to the month it really arrived;
--   a paid authorization never shows in Current.
--
-- And the three things that follow from the groups existing at all: every row
-- is in exactly one of them, an authorization that starts next week is
-- Upcoming, and one whose dates have run out and whose money has not arrived
-- is still Current - because it is money owed and calling it Past would hide
-- the rows the practice most needs to chase.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_admin    uuid;
  v_uid      uuid;
  v_client   uuid;
  v_paid     uuid;
  v_soon     uuid;
  v_lapsed   uuid;
  v_last     date := (date_trunc('month', public.practice_today()::timestamp) - interval '1 day')::date;
  v_this     date := public.practice_today();
  v_row      public.authorizations;
  v_bucket   text;
  v_month    date;
  v_n        integer;
  failures   text[] := '{}';
begin
  select s.id, s.user_id into v_admin, v_uid from public.staff s
   where s.active and s.user_id is not null and s.role = 'Admin'
     and not coalesce(s.is_system, false)
   order by s.created_at limit 1;
  if v_admin is null then raise exception 'No Admin to act as.'; end if;

  insert into public.clients (name, status, stage)
  values ('ZZ Billing Filters', 'Active', 'Job Placement')
  returning id into v_client;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid::text, 'role', 'authenticated')::text, true);

  -- ── 1. a payment dated last month ─────────────────────────
  v_paid := public.add_authorization(
    v_client, 'V0000801', 'Job Placement', 'Flat Fee', 1500, null,
    v_last - 60, v_last - 10, '', 'Utah VR', null, v_last - 61,
    v_last, 1500, 'W-80001');

  select bucket into v_bucket from public.client_authorizations where id = v_paid;
  if v_bucket is distinct from 'Past' then
    failures := failures || format('FAILED: a paid authorization is in %s, not Past', v_bucket)::text;
  else
    raise notice 'ok  a paid authorization is Past';
  end if;

  -- Money reads `billed_work`, which is where every figure on the Money
  -- screen comes from. The month is the month the warrant arrived.
  select date_trunc('month', w.paid_on)::date into v_month
    from public.billed_work w where w.auth_id = v_paid;
  if v_month is distinct from date_trunc('month', v_last::timestamp)::date then
    failures := failures ||
      format('FAILED: a payment dated %s is counted under %s', v_last, v_month)::text;
  else
    raise notice 'ok  and a payment dated last month is counted under last month';
  end if;

  -- ── 2. and it is never in Current ─────────────────────────
  select count(*)::int into v_n
    from public.client_authorizations c
   where c.status in ('Paid', 'Closed') and c.bucket = 'Current';
  if v_n <> 0 then
    failures := failures ||
      format('FAILED: %s settled authorization(s) are showing as Current', v_n)::text;
  else
    raise notice 'ok  nothing paid or closed is in Current, for any client in the practice';
  end if;

  -- ── 3. correcting the date moves the month ────────────────
  perform public.correct_payment_date(v_paid, v_this, 'The warrant is dated the day it arrived.');

  select * into v_row from public.authorizations where id = v_paid;
  select date_trunc('month', w.paid_on)::date into v_month
    from public.billed_work w where w.auth_id = v_paid;

  if v_row.paid_on is distinct from v_this then
    failures := failures || format('FAILED: the payment date is %s, not the day given', v_row.paid_on)::text;
  elsif v_month is distinct from date_trunc('month', v_this::timestamp)::date then
    failures := failures || format('FAILED: corrected to %s, it is still counted under %s', v_this, v_month)::text;
  elsif v_row.status <> 'Paid' then
    failures := failures || format('FAILED: correcting the date left it %s', v_row.status)::text;
  else
    raise notice 'ok  correcting the date moves it to the month it arrived, and it is still Paid';
  end if;

  -- And the correction is on the record, not only in the column.
  select count(*)::int into v_n
    from public.authorization_corrections c
   -- The log stores the name a person reads, not the column name.
   where c.auth_id = v_paid and c.field = 'Paid on';
  if v_n = 0 then
    failures := failures || 'FAILED: the payment date moved and nothing was logged'::text;
  else
    raise notice 'ok  and the move is in the correction log';
  end if;

  -- ── 4. what a correction refuses ──────────────────────────
  begin
    perform public.correct_payment_date(v_paid, v_this - 3, '   ');
    failures := failures || 'FAILED: a payment date moved with no reason given'::text;
  exception when check_violation then
    raise notice 'ok  a correction with no reason is refused';
  end;

  begin
    perform public.correct_payment_date(v_paid, v_this + 1, 'Typed it wrong.');
    failures := failures || 'FAILED: a payment was dated in the future'::text;
  exception when check_violation then
    raise notice 'ok  and it cannot be moved into the future';
  end;

  -- ── 5. Upcoming is what has not started ───────────────────
  v_soon := public.add_authorization(
    v_client, 'V0000802', 'Job Coaching', 'Hourly', 45, 20,
    v_this + 7, v_this + 97, '', 'Utah VR', null, v_this);

  select bucket into v_bucket from public.client_authorizations where id = v_soon;
  if v_bucket is distinct from 'Upcoming' then
    failures := failures ||
      format('FAILED: an authorization starting in a week is in %s, not Upcoming', v_bucket)::text;
  else
    raise notice 'ok  an authorization that starts next week is Upcoming';
  end if;

  begin
    perform public.correct_payment_date(v_soon, v_this, 'It was paid.');
    failures := failures || 'FAILED: a payment date was corrected on an authorization nobody has paid'::text;
  exception when check_violation then
    raise notice 'ok  and a payment date is corrected on a paid record, not an authorized one';
  end;

  -- ── 6. money owed stays Current, however old ──────────────
  --
  -- The deliberate reading. Its dates ran out a month ago and USOR has not
  -- paid, so it is not Past: it is the row somebody has to chase.
  v_lapsed := public.add_authorization(
    v_client, 'V0000803', 'Job Development', 'Flat Fee', 560, null,
    v_last - 120, v_last - 30, '', 'Utah VR', null, v_last - 121);

  select bucket into v_bucket from public.client_authorizations where id = v_lapsed;
  if v_bucket is distinct from 'Current' then
    failures := failures ||
      format('FAILED: an unpaid authorization whose dates have run out is in %s, not Current', v_bucket)::text;
  else
    raise notice 'ok  money owed on an authorization whose dates have run out is still Current';
  end if;

  -- ── 7. one group each, and only one ───────────────────────
  select count(*)::int into v_n
    from public.client_authorizations c
   where c.bucket is null or c.bucket not in ('Past', 'Current', 'Upcoming');
  if v_n <> 0 then
    failures := failures || format('FAILED: %s authorization(s) are in no group at all', v_n)::text;
  else
    raise notice 'ok  every authorization in the practice is in exactly one of the three groups';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- BILLING FILTERS VERIFIED ---';
end $$;

rollback;
