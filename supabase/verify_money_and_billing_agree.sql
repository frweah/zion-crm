-- Money and Billing count the same authorizations (0290)
--
-- What has to hold:
--
--   Money's count of open authorizations is Billing's count. It read zero for
--   as long as it existed, because it filtered on a status value that has
--   never existed - and a screen that says "0 open authorizations" while
--   another says fourteen is a screen nobody can act on.
--
--   Open is one definition, in one place: not finished, not the parent of a
--   child authorization, and not on a client who has closed. Each of the three
--   is asserted by making a fixture that trips it.
--
--   And Billed is the hours where there are hours, the payment where there are
--   none, and it says which.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_client uuid; v_closed_client uuid; v_counsel uuid;
  v_plain uuid; v_parent uuid; v_child uuid; v_onclosed uuid; v_paid uuid; v_imported uuid;
  v_money integer; v_billing integer;
  r record;
  failures text[] := '{}';
begin
  -- ── the two screens agree as things stand ─────────────────
  select count(*) into v_money from public.authorization_economics where is_open;
  select count(*) into v_billing from public.billing_worklist(public.practice_today());
  if v_money <> v_billing then
    failures := failures || format('FAILED: Money counts %s open and Billing counts %s', v_money, v_billing)::text;
  else
    raise notice 'ok  Money and Billing both count % open authorization(s)', v_money;
  end if;

  -- ── and go on agreeing as each case is added ──────────────
  insert into public.counselors (name, email, office)
  values ('ZQ Money Counselor', 'zq-money@example.test', 'Salt Lake City') returning id into v_counsel;
  insert into public.clients (name, stage, status, counselor_id)
  values ('ZZ Money Testperson', 'Job Search', 'Active', v_counsel) returning id into v_client;
  insert into public.clients (name, stage, status, counselor_id)
  values ('ZZ Money Closed', 'Job Search', 'Closed', v_counsel) returning id into v_closed_client;

  -- One that is plainly open.
  insert into public.authorizations (client_id, number, service_type, rate_type, rate, total_hours,
                                     status, start_date, end_date)
  values (v_client, 'ZQ-OPEN-1', 'Job Coaching', 'Hourly', 45, 20, 'Authorized',
          public.practice_today() - 10, public.practice_today() + 50)
  returning id into v_plain;

  -- A parent and its child: the parent is not the practice's work to do.
  insert into public.authorizations (client_id, number, service_type, rate_type, rate, total_hours,
                                     status, start_date, end_date)
  values (v_client, 'ZQ-PARENT', 'Job Coaching', 'Hourly', 45, 20, 'Authorized',
          public.practice_today() - 10, public.practice_today() + 50)
  returning id into v_parent;
  -- A child carries the month it is for, by constraint.
  insert into public.authorizations (client_id, number, service_type, rate_type, rate, total_hours,
                                     status, start_date, end_date, parent_id, period)
  values (v_client, 'ZQ-CHILD', 'Job Coaching', 'Hourly', 45, 20, 'Authorized',
          public.practice_today() - 10, public.practice_today() + 50, v_parent,
          date_trunc('month', public.practice_today())::date)
  returning id into v_child;

  -- And one on a client who has closed.
  insert into public.authorizations (client_id, number, service_type, rate_type, rate, total_hours,
                                     status, start_date, end_date)
  values (v_closed_client, 'ZQ-ONCLOSED', 'Job Coaching', 'Hourly', 45, 20, 'Authorized',
          public.practice_today() - 10, public.practice_today() + 50)
  returning id into v_onclosed;

  select count(*) into v_money from public.authorization_economics where is_open;
  select count(*) into v_billing from public.billing_worklist(public.practice_today());
  if v_money <> v_billing then
    failures := failures || format('FAILED: with a parent and a closed client in play, Money counts %s and Billing counts %s',
                                   v_money, v_billing)::text;
  else
    raise notice 'ok  and they still agree with a parent, a child and a closed client in play';
  end if;

  -- Each of the three conditions, named, so a change to any one of them shows
  -- up as itself rather than as a count that drifted.
  if not (select is_open from public.authorization_economics where auth_id = v_plain) then
    failures := failures || 'FAILED: an authorized authorization on an open client does not read as open'::text;
  elsif (select is_open from public.authorization_economics where auth_id = v_parent) then
    failures := failures || 'FAILED: the parent of a child authorization reads as open'::text;
  elsif not (select is_open from public.authorization_economics where auth_id = v_child) then
    failures := failures || 'FAILED: a child authorization does not read as open'::text;
  elsif (select is_open from public.authorization_economics where auth_id = v_onclosed) then
    failures := failures || 'FAILED: an authorization on a closed client reads as open'::text;
  else
    raise notice 'ok  open is not only the status: a parent and a closed client are out of it';
  end if;

  -- ── Billed ────────────────────────────────────────────────
  -- One with hours logged and paid, and one paid with no hours at all, which
  -- is the state every hourly authorization the practice has ever been paid
  -- for is in.
  --
  -- Job Search rather than Job Coaching: coaching is a monthly service, so
  -- logging hours against the parent routes the entry to that month's child
  -- (route_entry_to_month) and the parent is left with none - which is right,
  -- and would make this fixture measure the wrong row.
  insert into public.authorizations (client_id, number, service_type, rate_type, rate, total_hours,
                                     status, start_date, end_date, paid_amount, paid_on)
  values (v_client, 'ZQ-PAID-HOURS', 'Job Search', 'Hourly', 45, 10, 'Paid',
          public.practice_today() - 60, public.practice_today() - 10, 450, public.practice_today() - 60)
  returning id into v_paid;
  insert into public.service_entries (auth_id, date, hours, notes, non_billable)
  values (v_paid, public.practice_today() - 20, 10, 'ZQ ten hours', false);

  insert into public.authorizations (client_id, number, service_type, rate_type, rate, total_hours,
                                     status, start_date, end_date, paid_amount, paid_on)
  values (v_client, 'ZQ-PAID-NOHOURS', 'Job Search', 'Hourly', 45, 10, 'Paid',
          public.practice_today() - 60, public.practice_today() - 10, 450, public.practice_today() - 60)
  returning id into v_imported;

  select billed, billed_from_payment, received into r
    from public.authorization_economics where auth_id = v_paid;
  if r.billed <> 450 then
    failures := failures || format('FAILED: ten hours at 45 came to %s billed', r.billed)::text;
  elsif r.billed_from_payment then
    failures := failures || 'FAILED: an authorization with its hours logged was billed from the payment'::text;
  else
    raise notice 'ok  where the hours are logged, Billed is the hours';
  end if;

  select billed, billed_from_payment, received into r
    from public.authorization_economics where auth_id = v_imported;
  if r.billed <> 450 then
    failures := failures || format('FAILED: a paid authorization with no hours logged is billed at %s, not what was paid', r.billed)::text;
  elsif not r.billed_from_payment then
    failures := failures || 'FAILED: a row billed from its payment does not say so, so it reads as logged work'::text;
  else
    raise notice 'ok  and where they are not, Billed is the payment, and the row says so';
  end if;

  -- Nothing not yet billed is counted as billed: an Authorized one is work to
  -- do, not money asked for.
  if (select billed from public.authorization_economics where auth_id = v_plain) <> 0 then
    failures := failures || 'FAILED: an authorization nobody has billed counts as billed'::text;
  else
    raise notice 'ok  and work nobody has billed is not billed';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- MONEY AND BILLING AGREE VERIFIED ---';
end $$;

rollback;
