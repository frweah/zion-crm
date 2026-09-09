-- Zion Vocational Rehab CRM — what an authorization is worth
--
-- A revenue screen is believed on sight. The ways it can lie are all
-- arithmetic: counting a non-billable hour as money, counting a flat fee
-- before the service was completed, counting a voided invoice, or showing a
-- closed authorization as owing something nobody will ever collect.
--
-- Runs inside a transaction that is rolled back. Nothing here is left behind.

begin;

do $$
declare
  v_admin   uuid;
  v_client  uuid;
  v_hourly  uuid;
  v_flat    uuid;
  v_invoice uuid;
  r         record;
  failures  text[] := '{}';
begin
  select id into v_admin from public.staff where role = 'Admin' and active order by created_at limit 1;
  select id into v_client from public.clients order by created_at limit 1;

  -- ── hourly: earns by the hour, and only billable hours ─────
  insert into public.authorizations (client_id, number, service_type, total_hours, rate,
                                     rate_type, status, start_date, carried_used)
  values (v_client, 'ZZ-HOURLY', 'Job Coaching', 10, 45, 'Hourly', 'Open', public.practice_today(), 0)
  returning id into v_hourly;

  select * into r from public.authorization_economics where auth_id = v_hourly;
  if r.authorized <> 450 then
    failures := failures || format('FAILED: ten hours at $45 is authorized as %s', r.authorized);
  elsif r.earned <> 0 or r.committed <> 450 then
    failures := failures || format('FAILED: before any work, earned is %s and committed %s',
                                   r.earned, r.committed);
  else
    raise notice 'ok  ten hours at $45 is $450 authorized, none of it earned yet';
  end if;

  insert into public.service_entries (auth_id, date, hours, staff_id, primary_code)
  values (v_hourly, public.practice_today(), 3, v_admin, 'JC');

  select * into r from public.authorization_economics where auth_id = v_hourly;
  if r.earned <> 135 or r.unbilled <> 135 or r.committed <> 315 then
    failures := failures || format('FAILED: after 3 hours, earned %s / unbilled %s / committed %s',
                                   r.earned, r.unbilled, r.committed);
  else
    raise notice 'ok  three hours earns $135, all of it not yet invoiced';
  end if;

  insert into public.service_entries (auth_id, date, hours, staff_id, primary_code, non_billable)
  values (v_hourly, public.practice_today(), 2, v_admin, 'JC', true);

  select * into r from public.authorization_economics where auth_id = v_hourly;
  if r.earned <> 135 then
    failures := failures || format('FAILED: two non-billable hours moved earned to %s', r.earned);
  else
    raise notice 'ok  a non-billable hour is worth nothing, which is what non-billable means';
  end if;

  -- ── an invoice is money asked for, a void one is not ───────
  insert into public.invoices (auth_id, number, date, amount, status, service_type)
  values (v_hourly, 'ZZ-INV-1', public.practice_today(), 100, 'Draft', 'Job Coaching')
  returning id into v_invoice;

  select * into r from public.authorization_economics where auth_id = v_hourly;
  if r.unbilled <> 35 or r.outstanding <> 0 then
    failures := failures || format('FAILED: after a $100 draft, unbilled %s / outstanding %s',
                                   r.unbilled, r.outstanding);
  else
    raise notice 'ok  a draft invoice claims the work, but nobody owes us anything yet';
  end if;

  -- The revenue screen tells people paperwork can block an invoice. That rule
  -- lives in the database, and this is it: sending is refused while a USOR
  -- form the service requires is unfinished.
  begin
    update public.invoices set status = 'Sent' where id = v_invoice;
    failures := failures || 'FAILED: an invoice was sent with USOR forms outstanding'::text;
  exception when others then
    raise notice 'ok  the database refuses to send an invoice while a required form is unfinished';
  end;

  insert into public.forms (template_id, client_id, auth_id, month, status, created_by, completed_at)
  select t.id, v_client, v_hourly,
         case when t.monthly then to_char(public.practice_today(), 'YYYY-MM') else null end,
         'Completed', v_admin, now()
    from public.form_templates t
   where t.required_for_billing and 'Job Coaching' = any(t.services);

  update public.invoices set status = 'Sent' where id = v_invoice;

  select * into r from public.authorization_economics where auth_id = v_hourly;
  if r.unbilled <> 35 or r.outstanding <> 100 or r.received <> 0 then
    failures := failures || format('FAILED: after sending $100, unbilled %s / outstanding %s / received %s',
                                   r.unbilled, r.outstanding, r.received);
  else
    raise notice 'ok  invoicing $100 of $135 leaves $35 not asked for, and $100 owed to us';
  end if;

  update public.invoices set status = 'Paid', paid_date = public.practice_today() where id = v_invoice;
  select * into r from public.authorization_economics where auth_id = v_hourly;
  if r.received <> 100 or r.outstanding <> 0 then
    failures := failures || format('FAILED: a paid invoice reads received %s / outstanding %s',
                                   r.received, r.outstanding);
  else
    raise notice 'ok  paid moves out of owed and into received';
  end if;

  update public.invoices set status = 'Void' where id = v_invoice;
  select * into r from public.authorization_economics where auth_id = v_hourly;
  if r.invoiced <> 0 or r.unbilled <> 135 then
    failures := failures || format('FAILED: a voided invoice still counts — invoiced %s, unbilled %s',
                                   r.invoiced, r.unbilled);
  else
    raise notice 'ok  a voided invoice is not money asked for, and the work goes back to unbilled';
  end if;

  -- ── you cannot work past what USOR authorized ──────────────
  -- The revenue screen warns when an authorization is nearly spent. This is
  -- why that warning is worth reading: the hours after it are simply refused.
  begin
    insert into public.service_entries (auth_id, date, hours, staff_id, primary_code)
    values (v_hourly, public.practice_today(), 9, v_admin, 'JC');
    failures := failures || 'FAILED: nine hours went onto an authorization with seven left'::text;
  exception when others then
    raise notice 'ok  hours beyond the authorization are refused, not quietly earned';
  end;

  -- ── an amendment downward does not become negative money ───
  -- A counselor can amend an authorization to fewer hours than have already
  -- been worked. That is a conversation to have, not a negative number.
  update public.authorizations set total_hours = 2 where id = v_hourly;

  select * into r from public.authorization_economics where auth_id = v_hourly;
  if r.committed <> 0 or r.hours_left <> 0 then
    failures := failures || format('FAILED: an authorization amended below what was worked shows committed %s, hours left %s',
                                   r.committed, r.hours_left);
  else
    raise notice 'ok  amended below what was already worked, it shows nothing left rather than less than nothing';
  end if;

  update public.authorizations set total_hours = 10 where id = v_hourly;

  -- ── flat fee earns on completion, not on effort ────────────
  insert into public.authorizations (client_id, number, service_type, rate, rate_type,
                                     status, start_date)
  values (v_client, 'ZZ-FLAT', 'Job Placement', 1000, 'Flat Fee', 'Open', public.practice_today())
  returning id into v_flat;

  insert into public.service_entries (auth_id, date, hours, staff_id, primary_code)
  values (v_flat, public.practice_today(), 20, v_admin, 'JP');

  select * into r from public.authorization_economics where auth_id = v_flat;
  if r.earned <> 0 or r.authorized <> 1000 then
    failures := failures || format('FAILED: twenty hours on a flat fee earned %s of %s',
                                   r.earned, r.authorized);
  else
    raise notice 'ok  twenty hours on a flat fee earns nothing until the service is completed';
  end if;

  insert into public.completions (auth_id, start_date, completion)
  values (v_flat, public.practice_today(), public.practice_today());

  select * into r from public.authorization_economics where auth_id = v_flat;
  if r.earned <> 1000 or r.unbilled <> 1000 or r.committed <> 0 then
    failures := failures || format('FAILED: on completion, earned %s / unbilled %s / committed %s',
                                   r.earned, r.unbilled, r.committed);
  else
    raise notice 'ok  completing it earns the whole fee, and the whole fee is owed to us';
  end if;

  -- ── a closed authorization is settled ──────────────────────
  update public.authorizations set status = 'Paid' where id in (v_hourly, v_flat);

  select sum(unbilled) as u, sum(committed) as c into r
    from public.authorization_economics where auth_id in (v_hourly, v_flat);
  if r.u <> 0 or r.c <> 0 then
    failures := failures || format('FAILED: closed authorizations still show %s unbilled and %s to earn',
                                   r.u, r.c);
  else
    raise notice 'ok  a closed authorization owes nothing and promises nothing — nobody can act on it';
  end if;

  -- ── carried-over hours are hours ───────────────────────────
  -- Everything before the migration lives in carried_used. Ignoring it would
  -- show a year of finished work as still to do.
  if not exists (
    select 1 from public.authorization_economics e
     join public.authorizations a on a.id = e.auth_id
    where coalesce(a.carried_used, 0) > 0 and e.hours_used >= a.carried_used
  ) and exists (select 1 from public.authorizations where coalesce(carried_used, 0) > 0) then
    failures := failures || 'FAILED: hours carried over at migration are not counted as used'::text;
  else
    raise notice 'ok  hours carried over at migration count as used';
  end if;

  if failures = '{}' then
    raise notice '';
    raise notice '--- AUTHORIZATION ECONOMICS VERIFIED ---';
  else
    raise notice '';
    raise notice '%  PROBLEM(S):', array_length(failures, 1);
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
