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
  values (v_client, 'ZZ-HOURLY', 'Job Coaching', 10, 45, 'Hourly', 'Authorized', public.practice_today(), 0)
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

  -- ── submitting is asking for the money (§1, §10) ──────────
  --
  -- The invoice is gone. Draft, Sent, Paid and Void on an invoice are now
  -- the authorization's own status, so the shapes this script used to try -
  -- a part-invoiced authorization, a voided invoice - no longer exist to be
  -- tried. What is left is the sequence that does exist.
  --
  -- The forms rule came across from the invoice, where it was
  -- check_invoice_forms: a packet does not go to USOR with a required form
  -- outstanding, and that block now sits on the submit.
  update public.authorizations set status = 'Due' where id = v_hourly;
  begin
    update public.authorizations set status = 'Submitted', recipient = 'ZZ' where id = v_hourly;
    failures := failures || 'FAILED: an authorization was submitted with USOR forms outstanding'::text;
  exception when check_violation then
    raise notice 'ok  the database refuses to submit while a required USOR form is unfinished';
  end;

  insert into public.forms (template_id, client_id, auth_id, status, data)
  select t.id, v_client, v_hourly, 'Completed', '{}'::jsonb
    from public.form_templates t
   where t.required_for_billing and 'Job Coaching' = any (t.services);

  update public.authorizations set status = 'Submitted', recipient = 'ZZ USOR' where id = v_hourly;
  select * into r from public.authorization_economics where auth_id = v_hourly;
  if r.invoiced <> 135 or r.outstanding <> 135 or r.unbilled <> 0 then
    failures := failures || format('FAILED: submitted reads invoiced %s / outstanding %s / unbilled %s',
                                   r.invoiced, r.outstanding, r.unbilled);
  else
    raise notice 'ok  submitting asks for the work done, and leaves nothing unbilled';
  end if;

  update public.authorizations
     set status = 'Paid', paid_on = public.practice_today(), paid_amount = 135
   where id = v_hourly;
  select * into r from public.authorization_economics where auth_id = v_hourly;
  if r.received <> 135 or r.outstanding <> 0 then
    failures := failures || format('FAILED: paid reads received %s / outstanding %s',
                                   r.received, r.outstanding);
  else
    raise notice 'ok  paid moves out of owed and into received';
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
  values (v_client, 'ZZ-FLAT', 'Job Placement', 1000, 'Flat Fee', 'Authorized', public.practice_today())
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
  -- Closed, not Paid: §4 allows Closed from any state, and v_flat has never
  -- been submitted, so it could not be paid.
  update public.authorizations
     set status = 'Closed', closed_reason = 'ZZ settled' where id in (v_hourly, v_flat);

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
