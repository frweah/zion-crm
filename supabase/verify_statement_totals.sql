-- Zion Vocational Rehab CRM — statement totals
--
-- The figure on a statement is what somebody expects to be paid, so the ways
-- it can be quietly wrong are the ones worth proving against: work priced at
-- today's rate instead of the day's, an approved statement restated by a
-- back-dated rate, hours on days no rate covers folded in at zero as though
-- the work were free, and an adjustment with no reason attached.
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
  v_st       uuid;
  v_st2      uuid;
  v_st3      uuid;
  v_hours    numeric;
  v_amount   numeric;
  v_unpriced numeric;
  v_count    int;
  v_before   date;
  failures   text[] := '{}';
begin
  select id, user_id into v_admin, v_adm_uid from public.staff where legacy_id = 's1';
  select id, user_id into v_rei,  v_rei_uid  from public.staff where legacy_id = 's2';
  select id             into v_marg          from public.staff where legacy_id = 's3';

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);

  -- ── hourly, with the rate changing mid-period ──────────────
  perform public.set_staff_pay(v_rei, 20.00, 'Hourly', make_date(2034, 1, 1), 'starting');
  perform public.set_staff_pay(v_rei, 30.00, 'Hourly', make_date(2034, 3, 10), 'review');

  insert into public.contractor_statements (staff_id, period_start, period_end, status)
  values (v_rei, make_date(2034, 3, 1), make_date(2034, 3, 14), 'Draft')
  returning id into v_st;

  insert into public.work_sessions (staff_id, worked_on, hours, statement_id, created_by)
  values (v_rei, make_date(2034, 3, 5),  4, v_st, v_admin),   -- 4 x 20 = 80
         (v_rei, make_date(2034, 3, 12), 3, v_st, v_admin);   -- 3 x 30 = 90

  select total_hours, total_amount into v_hours, v_amount
    from public.contractor_statement_totals where statement_id = v_st;

  if v_hours is distinct from 7 then
    failures := failures || format('FAILED: hours came to %s, expected 7', v_hours);
  else
    raise notice 'ok  the hours add up';
  end if;

  if v_amount is distinct from 170.00 then
    failures := failures || format('FAILED: the total came to %s, expected 170.00', v_amount);
  else
    raise notice 'ok  a rate change mid-period splits the period, without anyone splitting it';
  end if;

  -- ── a voided session is not work done ──────────────────────
  insert into public.work_sessions (staff_id, worked_on, hours, statement_id, voided, created_by)
  values (v_rei, make_date(2034, 3, 6), 8, v_st, true, v_admin);

  select total_amount into v_amount
    from public.contractor_statement_totals where statement_id = v_st;
  if v_amount is distinct from 170.00 then
    failures := failures || format('FAILED: a voided session was paid — total %s', v_amount);
  else
    raise notice 'ok  a voided session is not priced';
  end if;

  -- ── hours no rate covers are reported, not valued at zero ──
  -- The day has to be before every rate this person has, including any real
  -- one already on file. A fixed date here would quietly start being priced
  -- the moment somebody back-dated a rate past it, and the check would fail
  -- for a reason that has nothing to do with what it is testing.
  select min(effective_from) - 1 into v_before
    from public.staff_pay where staff_id = v_rei;

  -- On its own statement, because work_sessions is append-only: there is no
  -- delete policy at all, so a tidy-up afterwards would remove nothing and
  -- silently leave these hours on the statement being measured. The first
  -- version of this file did exactly that.
  insert into public.contractor_statements (staff_id, period_start, period_end, status)
  values (v_rei, make_date(2034, 4, 1), make_date(2034, 4, 14), 'Draft')
  returning id into v_st3;

  insert into public.work_sessions (staff_id, worked_on, hours, statement_id, created_by)
  values (v_rei, v_before, 5, v_st3, v_admin);

  select total_hours, unpriced_hours, total_amount
    into v_hours, v_unpriced, v_amount
    from public.contractor_statement_totals where statement_id = v_st3;

  if v_unpriced is distinct from 5 then
    failures := failures || format('FAILED: unpriced hours came to %s, expected 5', v_unpriced);
  else
    raise notice 'ok  hours on days no rate covers are reported as unpriced';
  end if;
  if v_hours is distinct from 5 then
    failures := failures || format('FAILED: hours came to %s, expected 5', v_hours);
  else
    raise notice 'ok  unpriced hours still count as hours worked';
  end if;
  if v_amount is distinct from 0 then
    failures := failures || format('FAILED: unpriced work was valued at %s, expected nothing', v_amount);
  else
    raise notice 'ok  unpriced work is not folded in at zero, which would read as free work';
  end if;

  -- ── an adjustment needs a reason ───────────────────────────
  begin
    perform public.set_statement_adjustment(v_st, 25.00, '');
    failures := failures || 'FAILED: an adjustment was accepted with no reason'::text;
  exception when check_violation then
    raise notice 'ok  an adjustment needs a reason';
  end;

  perform public.set_statement_adjustment(v_st, -20.00, 'overpaid last period');
  select total_amount into v_amount
    from public.contractor_statement_totals where statement_id = v_st;
  if v_amount is distinct from 150.00 then
    failures := failures || format('FAILED: after the adjustment the total is %s, expected 150.00', v_amount);
  else
    raise notice 'ok  an adjustment moves the total, in either direction';
  end if;

  -- ── approving fixes the figures ────────────────────────────
  update public.contractor_statements
     set status = 'Approved', decided_at = now(), decided_by = v_admin
   where id = v_st;

  select approved_hours, approved_amount into v_hours, v_amount
    from public.contractor_statement_totals where statement_id = v_st;
  if v_amount is distinct from 150.00 or v_hours is distinct from 7 then
    failures := failures || format('FAILED: the snapshot recorded %s hours and %s', v_hours, v_amount);
  else
    raise notice 'ok  approving records what the statement came to';
  end if;

  -- A back-dated rate is legitimate, and must not restate what was paid.
  perform public.set_staff_pay(v_rei, 99.00, 'Hourly', make_date(2034, 2, 1), 'back-dated');

  select total_amount into v_amount
    from public.contractor_statement_totals where statement_id = v_st;
  if v_amount is distinct from 150.00 then
    failures := failures || format('FAILED: a back-dated rate restated an approved statement to %s', v_amount);
  else
    raise notice 'ok  a back-dated rate does not restate an approved statement';
  end if;

  begin
    perform public.set_statement_adjustment(v_st, 5.00, 'second thoughts');
    failures := failures || 'FAILED: an approved statement was adjusted'::text;
  exception when check_violation then
    raise notice 'ok  an approved statement cannot be adjusted, only returned';
  end;

  -- ── a flat rate is the period amount, once ─────────────────
  perform public.set_staff_pay(v_marg, 1500.00, 'Flat', make_date(2034, 1, 1), 'flat per period');

  insert into public.contractor_statements (staff_id, period_start, period_end, status)
  values (v_marg, make_date(2034, 3, 1), make_date(2034, 3, 14), 'Draft')
  returning id into v_st2;

  insert into public.work_sessions (staff_id, worked_on, hours, statement_id, created_by)
  values (v_marg, make_date(2034, 3, 5), 10, v_st2, v_admin),
         (v_marg, make_date(2034, 3, 6), 10, v_st2, v_admin);

  select total_hours, total_amount into v_hours, v_amount
    from public.contractor_statement_totals where statement_id = v_st2;

  if v_amount is distinct from 1500.00 then
    failures := failures || format('FAILED: the flat period came to %s, expected 1500.00', v_amount);
  else
    raise notice 'ok  a flat rate is the period amount once, whatever the hours';
  end if;
  if v_hours is distinct from 20 then
    failures := failures || format('FAILED: flat hours came to %s, expected 20', v_hours);
  else
    raise notice 'ok  hours are still recorded on a flat statement';
  end if;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  -- ── each contractor sees their own total and no other ──────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_rei_uid, 'role', 'authenticated')::text, true);

  select total_amount into v_amount
    from public.contractor_statement_totals where statement_id = v_st;
  if v_amount is distinct from 150.00 then
    failures := failures || format('FAILED: a contractor sees %s for their own statement', v_amount);
  else
    raise notice 'ok  a contractor sees the total of their own statement';
  end if;

  select count(*) into v_count
    from public.contractor_statement_totals where statement_id = v_st2;
  if v_count <> 0 then
    failures := failures || 'FAILED: a colleague''s statement total was visible'::text;
  else
    raise notice 'ok  a colleague''s statement total is not visible';
  end if;

  begin
    perform public.set_statement_adjustment(v_st, 100.00, 'a bonus for me');
    failures := failures || 'FAILED: a contractor adjusted their own statement'::text;
  exception when insufficient_privilege then
    raise notice 'ok  a contractor cannot adjust their own statement';
  end;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  if failures = '{}' then
    raise notice '';
    raise notice '--- STATEMENT TOTALS VERIFIED ---';
  else
    raise notice '';
    raise notice '%  PROBLEM(S):', array_length(failures, 1);
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
