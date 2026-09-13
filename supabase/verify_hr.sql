-- Zion Vocational Rehab CRM — HR (contractor path) verification
--
-- Two things here are not conveniences:
--   * Time records are evidence. They are never edited in place; a mistake is
--     corrected by a new row that says what it corrects and why.
--   * Pay rates and another person's hours are not visible to colleagues.
--
-- Both are claims about the database, so both are tested against it.
--
-- Runs inside a transaction that is rolled back.

begin;

do $$
declare
  v_rei      uuid;
  v_marg     uuid;
  v_session  uuid;
  v_correct  uuid;
  v_stmt     uuid;
  v_total    numeric;
  v_baseline numeric;
  failures   text[] := '{}';
begin
  select id into v_rei  from public.staff where legacy_id = 's2';
  select id into v_marg from public.staff where legacy_id = 's3';

  -- What is already in this period before any fixture is added. Rei logs real
  -- hours now, so every total below is a difference rather than a figure.
  select coalesce(total_hours, 0) into v_baseline from public.work_session_totals
   where staff_id = v_rei and period_start = public.period_start(current_date);
  v_baseline := coalesce(v_baseline, 0);

  -- ── append-only ────────────────────────────────────────────
  insert into public.work_sessions (staff_id, worked_on, hours, description, created_by)
  values (v_rei, current_date, 6, 'ZZ job search with three clients', v_rei)
  returning id into v_session;

  begin
    update public.work_sessions set hours = 9 where id = v_session;
    failures := failures || 'FAILED: a time record was edited in place'::text;
  exception when check_violation then
    raise notice 'ok  a logged session cannot be edited';
  end;

  begin
    update public.work_sessions set worked_on = current_date - 3 where id = v_session;
    failures := failures || 'FAILED: the date on a time record was rewritten'::text;
  exception when check_violation then
    raise notice 'ok  the date on a session cannot be rewritten';
  end;

  -- ── correcting instead ─────────────────────────────────────
  insert into public.work_sessions
    (staff_id, worked_on, hours, description, created_by, corrects_id, correction_reason)
  values (v_rei, current_date, 4.5, 'ZZ job search with three clients', v_rei, v_session,
          'Logged 6 by mistake; the visit was 4.5 hours')
  returning id into v_correct;

  if not (select voided from public.work_sessions where id = v_session) then
    failures := failures || 'FAILED: the corrected session was not superseded'::text;
  else
    raise notice 'ok  the corrected session is superseded and stops counting';
  end if;

  -- The original is still there to read — that is the point of an audit trail.
  if not exists (select 1 from public.work_sessions where id = v_session) then
    failures := failures || 'FAILED: correcting deleted the original instead of superseding it'::text;
  else
    raise notice 'ok  the original entry is still on file, with the reason recorded';
  end if;

  -- Measured as a change, not as an absolute. Real hours are logged in this
  -- period now, and a literal here would have been asserting that nobody had
  -- done any work — which was only ever true because nobody had started.
  select coalesce(total_hours, 0) into v_total from public.work_session_totals
   where staff_id = v_rei and period_start = public.period_start(current_date);
  if v_total - v_baseline <> 4.5 then
    failures := failures || format('FAILED: the correction moved the period total by %s, expected 4.5',
                                   v_total - v_baseline);
  else
    raise notice 'ok  the correction leaves 4.5 in the period total, not 10.5';
  end if;

  -- A correction must say why.
  begin
    insert into public.work_sessions
      (staff_id, worked_on, hours, description, created_by, corrects_id)
    values (v_rei, current_date, 1, 'ZZ no reason given', v_rei, v_correct);
    failures := failures || 'FAILED: a correction was accepted with no reason'::text;
  exception when check_violation then
    raise notice 'ok  a correction without a reason is refused';
  end;

  -- ── an approved statement settles the hours ────────────────
  -- Arranged, not assumed. A real statement for this period can already
  -- exist - one was drafted on 2026-09-10 - and there is one per person per
  -- period, so a second insert is refused. Taking the real one over inside
  -- this rolled-back transaction leaves it exactly as it was afterwards.
  insert into public.contractor_statements (staff_id, period_start, period_end, status)
  values (v_rei, public.period_start(current_date), public.period_end(current_date), 'Draft')
  on conflict (staff_id, period_start) do update set status = excluded.status
  returning id into v_stmt;

  update public.work_sessions set statement_id = v_stmt where id = v_correct;
  update public.contractor_statements set status = 'Approved' where id = v_stmt;

  begin
    insert into public.work_sessions
      (staff_id, worked_on, hours, description, created_by, statement_id)
    values (v_rei, current_date, 2, 'ZZ late addition', v_rei, v_stmt);
    failures := failures || 'FAILED: hours were added to an approved statement'::text;
  exception when check_violation then
    raise notice 'ok  nothing can be added to an approved statement';
  end;

  begin
    insert into public.work_sessions
      (staff_id, worked_on, hours, description, created_by, corrects_id, correction_reason)
    values (v_rei, current_date, 1, 'ZZ retro change', v_rei, v_correct, 'changed my mind');
    failures := failures || 'FAILED: hours on an approved statement were corrected away'::text;
  exception when check_violation then
    raise notice 'ok  approved hours cannot be corrected without reopening the statement';
  end;

  if array_length(failures, 1) is not null then
    raise exception E'HR AUDIT FAILURES:\n  %', array_to_string(failures, E'\n  ');
  end if;
  raise notice '--- TIME RECORD AUDIT VERIFIED ---';
end $$;

-- ─────────────────────────────────────────────────────────────
-- Who can see whose hours, statements and rates
-- ─────────────────────────────────────────────────────────────
do $$
declare
  v_rei    uuid;
  v_marg   uuid;
  r        record;
  n_mine         int;
  n_theirs       int;
  n_expected      int;
  n_rates        int;
  n_others_rates int;
  n_type         int;
  failures       text[] := '{}';
begin
  select id into v_rei  from public.staff where legacy_id = 's2';
  select id into v_marg from public.staff where legacy_id = 's3';

  insert into public.work_sessions (staff_id, worked_on, hours, description, created_by)
  values (v_marg, current_date, 3, 'ZZ margaret session', v_marg);

  insert into public.staff_pay (staff_id, pay_rate, effective_from)
  values (v_rei, 28.00, current_date), (v_marg, 30.00, current_date);

  for r in
    select s.id, s.name, s.role, u.id as uid
      from public.staff s join auth.users u on u.id = s.user_id
     where s.active order by s.legacy_id
  loop
    -- What they should see is every rate of their own, whatever that number is
    -- today. Asserting a literal 1 was fine while the table was empty and broke
    -- the moment a real rate was entered — the count is not the property being
    -- tested, the privacy is.
    select count(*) into n_expected from public.staff_pay where staff_id = r.id;

    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims',
                       json_build_object('sub', r.uid, 'role', 'authenticated')::text, true);

    select count(*) into n_mine   from public.work_sessions where staff_id = r.id;
    select count(*) into n_theirs from public.work_sessions where staff_id <> r.id;
    select count(*) into n_rates  from public.staff_pay where staff_id = r.id;
    select count(*) into n_others_rates from public.staff_pay where staff_id <> r.id;
    select count(*) into n_type   from public.staff_employment;

    perform set_config('role', 'postgres', true);
    perform set_config('request.jwt.claims', '', true);

    raise notice '  % (%): sessions own=% others=% | pay rows own=% others=% | employment rows=%',
      r.name, r.role, n_mine, n_theirs, n_rates, n_others_rates, n_type;

    if r.role = 'Admin' then
      if n_rates + n_others_rates < 2 then failures := failures || 'Admin should see every pay rate'::text; end if;
    else
      if n_theirs <> 0 then
        failures := failures || format('LEAK: %s can see another person''s time records', r.name);
      end if;

      -- A contractor may see their own rate: they agreed it and invoice
      -- against it. Everybody else's stays private.
      if n_rates <> n_expected then
        failures := failures || format('%s should see all %s of their own pay rates, saw %s',
                                      r.name, n_expected, n_rates);
      end if;
      if n_others_rates <> 0 then
        failures := failures || format('LEAK: %s can see someone else''s pay rate', r.name);
      end if;

      if n_type <> 1 then
        failures := failures || format('LEAK: %s sees %s employment rows, should see only their own', r.name, n_type);
      end if;
    end if;
  end loop;

  if array_length(failures, 1) is not null then
    raise exception E'HR PRIVACY FAILURES:\n  %', array_to_string(failures, E'\n  ');
  end if;
  raise notice '--- HR PRIVACY VERIFIED ---';
end $$;

rollback;
