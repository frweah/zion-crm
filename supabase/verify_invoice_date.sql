-- Zion Vocational Rehab CRM — the date on an invoice (0113)
--
-- What has to hold, each tried from the direction that would break it:
--
--   An invoice is dated by the CRP billing pathway's rule for its service,
--   not by the day somebody raised it: coaching by the first coaching day of
--   the month being billed, placement by the first day of work, the High
--   Quality Indicators by the stability date, job development by the first
--   meeting to look for work.
--
--   A month already invoiced is not billed again, so coaching moves on to
--   the next month with hours in it. A non-billable entry never dates one.
--
--   Where the pathway says nothing, the date says so. Where the CRM has
--   nothing to go on, the date is today and says why.
--
--   The Draft a completed form earns carries the pathway's date too.
--
-- Everything is rolled back.

begin;

do $$
declare
  failures text[] := '{}';
  v_c uuid; v_jc uuid; v_jp uuid; v_hq uuid; v_jd uuid; v_ls uuid; v_empty uuid;
  v_on date; v_basis text;
begin
  insert into public.clients (name, stage, status) values ('ZZ Dates Client', 'Job Coaching', 'Active') returning id into v_c;
  insert into public.authorizations (client_id, number, service_type, total_hours, rate_type, rate, status)
    values (v_c, 'V9001', 'Job Coaching', 100, 'Hourly', 45, 'Open') returning id into v_jc;
  insert into public.authorizations (client_id, number, service_type, rate_type, rate, status)
    values (v_c, 'V9002', 'Job Placement', 'Flat Fee', 2250, 'Open') returning id into v_jp;
  insert into public.authorizations (client_id, number, service_type, rate_type, rate, status)
    values (v_c, 'V9003', 'HQ Indicator', 'Flat Fee', 560, 'Open') returning id into v_hq;
  insert into public.authorizations (client_id, number, service_type, rate_type, rate, status)
    values (v_c, 'V9004', 'Job Development', 'Flat Fee', 560, 'Open') returning id into v_jd;
  insert into public.authorizations (client_id, number, service_type, total_hours, rate_type, rate, status)
    values (v_c, 'V9005', 'Life Skills', 40, 'Hourly', 30, 'Open') returning id into v_ls;
  insert into public.authorizations (client_id, number, service_type, total_hours, rate_type, rate, status)
    values (v_c, 'V9006', 'Job Coaching', 100, 'Hourly', 45, 'Open') returning id into v_empty;

  insert into public.service_entries (auth_id, date, hours, notes, non_billable, primary_code, secondary_code) values
    (v_jc, '2026-08-12', 3, 'ZZ', false, '', ''), (v_jc, '2026-08-20', 2, 'ZZ', false, '', ''),
    (v_jc, '2026-09-03', 3, 'ZZ', false, '', ''), (v_jc, '2026-09-09', 2, 'ZZ', false, '', ''),
    (v_jc, '2026-08-01', 1, 'ZZ non-billable, earlier than any real day', true, '', ''),
    (v_jd, '2026-06-10', 2, 'ZZ', false, '', ''), (v_jd, '2026-06-20', 2, 'ZZ', false, '', ''),
    (v_ls, '2026-07-15', 2, 'ZZ', false, '', '');
  insert into public.placements (client_id, employer, title, start_date, stability_on)
    values (v_c, 'ZZ Employer', 'ZZ Job', '2026-08-04', '2026-09-05');

  -- ── coaching: the first billable day, then the next month ───
  select on_date into v_on from public.invoice_date_for(v_jc);
  if v_on is distinct from '2026-08-12'::date then
    failures := failures || format('FAILED: coaching was dated %s, not its first billable day 2026-08-12', v_on);
  end if;
  insert into public.invoices (auth_id, number, date, amount, status) values (v_jc, 'ZZ-1', '2026-08-12', 225, 'Draft');
  select on_date into v_on from public.invoice_date_for(v_jc);
  if v_on is distinct from '2026-09-03'::date then
    failures := failures || format('FAILED: with August invoiced, coaching was dated %s, not 2026-09-03', v_on);
  else
    raise notice 'ok  coaching is dated by the first coaching day of the month not yet invoiced';
  end if;

  -- ── placement, HQI, development ────────────────────────────
  if (select on_date from public.invoice_date_for(v_jp)) is distinct from '2026-08-04'::date then
    failures := failures || 'FAILED: a placement invoice was not dated the first day of work'::text;
  end if;
  if (select on_date from public.invoice_date_for(v_hq)) is distinct from '2026-09-05'::date then
    failures := failures || 'FAILED: an HQI invoice was not dated the stability date'::text;
  end if;
  if (select on_date from public.invoice_date_for(v_jd)) is distinct from '2026-06-10'::date then
    failures := failures || 'FAILED: a job development invoice was not dated the first meeting'::text;
  else
    raise notice 'ok  placement, indicators and development take the pathway''s dates';
  end if;

  -- ── where the pathway is silent, it says so ────────────────
  select on_date, basis into v_on, v_basis from public.invoice_date_for(v_ls);
  if v_on is distinct from '2026-07-15'::date or v_basis not like '%pathway does not give one%' then
    failures := failures || format('FAILED: Life Skills was dated %s (%s) without saying the rule is the CRM''s', v_on, v_basis);
  end if;

  -- ── nothing to go on: today, and why ───────────────────────
  select on_date, basis into v_on, v_basis from public.invoice_date_for(v_empty);
  if v_on is distinct from public.practice_today() or v_basis not like '%so today%' then
    failures := failures || 'FAILED: with nothing logged the date was not today, or did not say why'::text;
  else
    raise notice 'ok  a date the pathway does not give, or the CRM cannot find, says so';
  end if;

  -- ── the Draft the gate raises uses the rule ────────────────
  -- The body of draft_invoice_for_authorization, read back: its dating line.
  if position('invoice_date_for' in pg_get_functiondef('public.draft_invoice_for_authorization(uuid)'::regprocedure)) = 0 then
    failures := failures || 'FAILED: the Draft raised by the billing gate is not dated by the pathway'::text;
  end if;

  -- ── nobody signed in ───────────────────────────────────────
  if has_function_privilege('anon', 'public.invoice_date_for(uuid)', 'execute') then
    failures := failures || 'FAILED: somebody not signed in can ask for an invoice date'::text;
  end if;
  if not has_function_privilege('authenticated', 'public.invoice_date_for(uuid)', 'execute') then
    failures := failures || 'FAILED: staff cannot ask for an invoice date'::text;
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
