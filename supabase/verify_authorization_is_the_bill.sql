-- Zion Vocational Rehab CRM — the authorization is the bill (0155-0158)
--
-- What has to hold, each tried from the direction that would break it:
--
--   Every authorization has a status and a bill-by, and the money that was
--   on the billing items is still there to the penny. §7's own test.
--
--   The status moves the way the work moves and no other way.
--
--   Submitting is refused when the work happened outside the authorized
--   period, and refused when the authorization is more than the grace past
--   its end date. It is allowed, with a warning on the list, when it is
--   inside the grace or has no end date at all - because a wall built on
--   inherited data stops the close over something nobody did.
--
--   Moving the end date needs a reason, and the reason is kept.
--
--   A coaching parent holds the hours; its months hold the billing. No new
--   month once the hours are gone. An empty month closes itself.
--
--   The ledger posts from the authorization: revenue when submitted, cash
--   when paid, a reversal when either comes undone - and no reversal when a
--   paid authorization is merely closed.
--
--   Every row on the worklist says one thing, not four.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_entity   uuid;
  v_client   uuid;
  v_staff    uuid;
  v_adm_uid  uuid := gen_random_uuid();
  v_auth     uuid;
  v_parent   uuid;
  v_child    uuid;
  v_ar       uuid;
  v_rev      uuid;
  v_und      uuid;
  v_n        integer;
  v_amount   numeric;
  v_amount2  numeric;
  v_text     text;
  v_status   text;
  failures   text[] := '{}';
begin
  -- ── §7: nothing was lost in the fold ──────────────────────
  select count(*) into v_n from public.authorizations where status is null;
  if v_n > 0 then
    failures := failures || format('FAILED: %s authorization(s) with no status', v_n)::text;
  end if;
  select count(*) into v_n from public.authorizations where bill_by is null;
  if v_n > 0 then
    failures := failures || format('FAILED: %s authorization(s) with no bill-by', v_n)::text;
  end if;
  select count(*) into v_n from public.authorizations where received_on is null;
  if v_n > 0 then
    failures := failures || format('FAILED: %s authorization(s) with no received date', v_n)::text;
  else
    raise notice 'ok  every authorization has a status, a bill-by and a received date';
  end if;

  -- The money. The billing item table is still there until §10 removes it,
  -- so while it is, the two have to agree.
  if exists (select 1 from information_schema.tables
              where table_schema = 'public' and table_name = 'billing_items') then
    execute 'select coalesce(sum(paid_amount), 0) from public.billing_items' into v_amount;
    select coalesce(sum(paid_amount), 0) into v_amount2 from public.authorizations;
    if round(v_amount, 2) <> round(v_amount2, 2) then
      failures := failures || format('FAILED: paid totals differ - %s on items, %s on authorizations', v_amount, v_amount2)::text;
    else
      raise notice 'ok  the paid total survived the fold exactly: %', round(v_amount, 2);
    end if;
  end if;

  -- ── the ground to test on ─────────────────────────────────
  select id into v_entity from public.ledger_entities where is_default;
  update public.ledger_settings set books_start = date '2020-01-01' where entity_id = v_entity;
  update public.org_settings set stale_grace_days = 90, stale_soon_days = 14 where id;

  v_ar  := public.ledger_account('ar');
  v_und := public.ledger_account('undeposited');
  v_rev := public.ledger_revenue_account('Job Coaching');

  insert into public.staff (name, email, role, active)
  values ('ZZ Bill Admin', 'zz-bill@example.test', 'Admin', true) returning id into v_staff;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_adm_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-bill@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_adm_uid where id = v_staff;

  insert into public.clients (name, stage, status) values ('ZZ Bill Client', 'Placement', 'Active')
  returning id into v_client;

  -- ── §2 and §3: a new authorization fills in its own dates ──
  insert into public.authorizations (
    client_id, number, service_type, rate_type, rate, total_hours,
    start_date, end_date, received_on
  ) values (
    v_client, 'ZZ-A-1', 'WSA Tier 1', 'Hourly', 50, 10,
    date '2026-09-01', date '2026-12-31', date '2026-10-01'
  ) returning id into v_auth;

  if (select bill_by from public.authorizations where id = v_auth) <> date '2026-10-08' then
    failures := failures || format('FAILED: WSA bill-by is %s, not seven days after received',
      (select bill_by from public.authorizations where id = v_auth))::text;
  else
    raise notice 'ok  bill-by is the service default counted from the received date';
  end if;
  if (select stale_date from public.authorizations where id = v_auth) <> date '2026-12-31' then
    failures := failures || 'FAILED: a new authorization did not take its end date as its stale date'::text;
  else
    raise notice 'ok  and the stale date is the authorization''s own end date, with no reason asked for';
  end if;

  -- ── §4: the moves the flow allows ─────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);

  begin
    update public.authorizations set status = 'Paid', paid_on = public.practice_today()
     where id = v_auth;
    failures := failures || 'FAILED: an authorization jumped from Authorized to Paid'::text;
  exception when check_violation then
    raise notice 'ok  an authorization does not jump from Authorized to Paid';
  end;

  update public.authorizations set status = 'Due' where id = v_auth;
  if (select status from public.authorizations where id = v_auth) <> 'Due' then
    failures := failures || 'FAILED: Authorized to Due was refused'::text;
  else
    raise notice 'ok  Authorized to Due is allowed';
  end if;

  -- ── the hard block: work outside the authorized period ────
  update public.authorizations
     set service_start = date '2026-08-01', service_end = date '2026-08-31'
   where id = v_auth;
  begin
    update public.authorizations set status = 'Submitted' where id = v_auth;
    failures := failures || 'FAILED: work done before the authorization started was submitted'::text;
  exception when check_violation then
    raise notice 'ok  work outside the authorized period cannot be submitted';
  end;

  update public.authorizations
     set service_start = date '2026-09-05', service_end = date '2026-09-20'
   where id = v_auth;

  -- ── hours and the amount ──────────────────────────────────
  insert into public.service_entries (auth_id, date, hours, non_billable, notes)
  values (v_auth, date '2026-09-10', 4, false, 'ZZ');
  if public.authorization_amount(v_auth) <> 200 then
    failures := failures || format('FAILED: four hours at 50 came to %s', public.authorization_amount(v_auth))::text;
  else
    raise notice 'ok  the amount is the hours logged at the rate, worked out in one place';
  end if;

  -- ── the USOR forms the service needs ──────────────────────
  --
  -- This block came across from the invoice, where it was
  -- check_invoice_forms. It is the rule that stops a packet reaching USOR
  -- without its forms, and it would have been lost with the invoice.
  begin
    update public.authorizations set status = 'Submitted', recipient = 'ZZ USOR' where id = v_auth;
    failures := failures || 'FAILED: submitted with a required USOR form outstanding'::text;
  exception when check_violation then
    raise notice 'ok  a required USOR form left unfinished stops the submission';
  end;

  insert into public.forms (template_id, client_id, auth_id, status, data)
  select t.id, v_client, v_auth, 'Completed', '{}'::jsonb
    from public.form_templates t
   where t.required_for_billing and 'WSA Tier 1' = any (t.services);

  -- ── submitted posts the revenue ───────────────────────────
  update public.authorizations set status = 'Submitted', recipient = 'ZZ USOR' where id = v_auth;

  if (select submitted_on from public.authorizations where id = v_auth) is null then
    failures := failures || 'FAILED: submitting did not stamp the date'::text;
  end if;
  if (select followup_due from public.authorizations where id = v_auth)
     <> public.practice_today() + 14 then
    failures := failures || 'FAILED: submitting did not start the 14-day clock'::text;
  else
    raise notice 'ok  submitting stamps the date and starts the chase';
  end if;

  select coalesce(sum(l.debit), 0) into v_amount
    from public.journal_lines l
    join public.journals j on j.id = l.journal_id
   where j.source_kind = 'Authorization' and j.source_id = v_auth and l.account_id = v_ar;
  if v_amount <> 200 then
    failures := failures || format('FAILED: submitting put %s into receivables, not 200', v_amount)::text;
  else
    raise notice 'ok  submitting an authorization is money owed to the practice';
  end if;

  -- ── paid posts the cash ───────────────────────────────────
  update public.authorizations
     set status = 'Paid', paid_on = date '2026-10-20', paid_amount = 200, warrant = 'ZZ-W-9'
   where id = v_auth;

  select coalesce(sum(l.debit), 0) into v_amount
    from public.journal_lines l
    join public.journals j on j.id = l.journal_id
   where j.source_kind = 'Authorization' and j.source_id = v_auth and l.account_id = v_und;
  if v_amount <> 200 then
    failures := failures || format('FAILED: payment put %s in hand, not 200', v_amount)::text;
  else
    raise notice 'ok  a warrant paid is money in hand, against receivables';
  end if;

  -- ── closing a paid authorization does not un-pay it ───────
  update public.authorizations
     set status = 'Closed', closed_reason = 'ZZ finished' where id = v_auth;
  select count(*) into v_n from public.journals j
   where j.source_kind = 'Reversal'
     and j.reverses_id in (select id from public.journals
                            where source_kind = 'Authorization' and source_id = v_auth
                              and source_event like 'Paid%');
  if v_n <> 0 then
    failures := failures || 'FAILED: closing a paid authorization reversed the money'::text;
  else
    raise notice 'ok  closing something that was paid leaves the money where it is';
  end if;

  -- ── the grace: inside it warns, past it refuses ───────────
  insert into public.authorizations (
    client_id, number, service_type, rate_type, rate,
    start_date, end_date, received_on, stale_date, status, bill_by
  ) values (
    v_client, 'ZZ-A-2', 'Life Skills', 'Flat Fee', 400,
    date '2026-01-01', public.practice_today() - 30, public.practice_today() - 60,
    public.practice_today() - 30, 'Due', public.practice_today() - 20
  ) returning id into v_auth;

  insert into public.forms (template_id, client_id, auth_id, status, data)
  select t.id, v_client, v_auth, 'Completed', '{}'::jsonb
    from public.form_templates t
   where t.required_for_billing and 'Life Skills' = any (t.services);
  insert into public.forms (template_id, client_id, auth_id, status, data)
  select t.id, v_client, v_auth, 'Completed', '{}'::jsonb
    from public.form_templates t
   where t.required_for_billing and 'Job Readiness' = any (t.services);
  insert into public.forms (template_id, client_id, auth_id, status, data)
  select t.id, v_client, v_auth, 'Completed', '{}'::jsonb
    from public.form_templates t
   where t.required_for_billing and 'Job Search' = any (t.services);
  update public.authorizations set status = 'Submitted', recipient = 'ZZ USOR' where id = v_auth;
  if (select status from public.authorizations where id = v_auth) <> 'Submitted' then
    failures := failures || 'FAILED: an authorization 30 days past its end date was refused'::text;
  else
    raise notice 'ok  past the end date but inside the grace, submitting is allowed';
  end if;

  update public.authorizations set status = 'Due' where id = v_auth;
  update public.authorizations
     set stale_date = public.practice_today() - 120,
         stale_reason = 'ZZ testing the grace'
   where id = v_auth;
  begin
    update public.authorizations set status = 'Submitted' where id = v_auth;
    failures := failures || 'FAILED: an authorization 120 days past its end date was submitted'::text;
  exception when check_violation then
    raise notice 'ok  past the grace, submitting is refused';
  end;

  -- ── moving the end date needs a reason, and keeps it ──────
  begin
    update public.authorizations
       set stale_date = public.practice_today() + 30, stale_reason = '' where id = v_auth;
    failures := failures || 'FAILED: the end date moved with no reason given'::text;
  exception when check_violation then
    raise notice 'ok  moving the end date needs a reason';
  end;

  update public.authorizations
     set stale_date = public.practice_today() + 30, stale_reason = 'ZZ new authorization received'
   where id = v_auth;
  -- Not "the latest event": now() is the same for everything in one
  -- transaction, so ordering by it cannot tell two of them apart.
  select count(*)::text into v_text from public.authorization_events
   where auth_id = v_auth and was like 'stale%' and note = 'ZZ new authorization received';
  if v_text = '0' then
    failures := failures || 'FAILED: the reason for moving the end date was not kept'::text;
  else
    raise notice 'ok  and the reason is kept against the record';
  end if;

  -- ── no end date never blocks ──────────────────────────────
  insert into public.authorizations (
    client_id, number, service_type, rate_type, rate,
    start_date, received_on, status, bill_by
  ) values (
    v_client, 'ZZ-A-3', 'Job Readiness', 'Flat Fee', 300,
    date '2026-01-01', public.practice_today() - 40, 'Due', public.practice_today() - 10
  ) returning id into v_auth;

  insert into public.forms (template_id, client_id, auth_id, status, data)
  select t.id, v_client, v_auth, 'Completed', '{}'::jsonb
    from public.form_templates t
   where t.required_for_billing and 'Job Readiness' = any (t.services);
  update public.authorizations set status = 'Submitted', recipient = 'ZZ USOR' where id = v_auth;
  if (select status from public.authorizations where id = v_auth) <> 'Submitted' then
    failures := failures || 'FAILED: an authorization with no end date was blocked'::text;
  else
    raise notice 'ok  no end date warns and never blocks';
  end if;

  perform set_config('role', 'postgres', true);

  -- ── what the old billing-item script used to hold ─────────
  --
  -- verify_billing_items.sql goes with its table (§13.17). These are the
  -- three rules it checked that still matter, asked of the authorization.
  insert into public.authorizations (
    client_id, number, service_type, rate_type, rate, start_date, end_date, received_on
  ) values (
    v_client, 'ZZ-A-4', 'Job Search', 'Flat Fee', 250,
    date '2026-01-01', date '2026-12-31', public.practice_today()
  ) returning id into v_auth;

  -- Paid always ends up with a date. Not by refusing one without it - the
  -- flow fills in today, which is what somebody marking a warrant paid
  -- means - but it can never be left empty, which is what the constraint is
  -- there to guarantee if the filling were ever removed.
  update public.authorizations set status = 'Due' where id = v_auth;
  update public.authorizations set status = 'Submitted', recipient = 'ZZ' where id = v_auth;
  update public.authorizations set status = 'Paid', paid_on = null, paid_amount = 250
   where id = v_auth;
  if (select paid_on from public.authorizations where id = v_auth) is null then
    failures := failures || 'FAILED: Paid with no date given stayed empty'::text;
  else
    raise notice 'ok  Paid cannot be dateless: the day it was marked is the day it took';
  end if;

  begin
    update public.authorizations set status = 'Closed', closed_reason = '' where id = v_auth;
    failures := failures || 'FAILED: Closed was accepted with no reason'::text;
  exception when check_violation then
    raise notice 'ok  and Closed refuses to be a status without a reason';
  end;

  -- Every change of status is written down.
  select count(*) into v_n from public.authorization_events
   where auth_id = v_auth and was is not null and became is not null;
  if v_n < 2 then
    failures := failures || format('FAILED: %s event(s) for an authorization moved twice', v_n)::text;
  else
    raise notice 'ok  every change of status is written down, with who and when';
  end if;

  -- Reopening a closed authorization is Admin's alone.
  update public.authorizations
     set status = 'Closed', closed_reason = 'ZZ for the reopen test' where id = v_auth;
  perform set_config('role', 'postgres', true);
  insert into public.staff (name, email, role, active)
  values ('ZZ Bill Clerk', 'zz-clerk@example.test', 'Billing', true) returning id into v_staff;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-clerk@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = (select id from auth.users where email = 'zz-clerk@example.test')
   where id = v_staff;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object(
    'sub', (select user_id from public.staff where id = v_staff), 'role', 'authenticated')::text, true);
  begin
    update public.authorizations set status = 'Due' where id = v_auth;
    failures := failures || 'FAILED: somebody who is not an Admin reopened a closed authorization'::text;
  exception when check_violation then
    raise notice 'ok  reopening a closed authorization is an Admin''s alone';
  end;
  perform set_config('role', 'postgres', true);

  -- ── §5: the parent holds the hours, the months hold the bill ──
  insert into public.authorizations (
    client_id, number, service_type, rate_type, rate, total_hours,
    start_date, end_date, received_on, stale_date, bill_by, status
  ) values (
    v_client, 'ZZ-COACH-1', 'Job Coaching', 'Hourly', 45, 8,
    date '2026-08-01', date '2026-12-31', date '2026-08-01', date '2026-12-31',
    date '2026-08-08', 'Authorized'
  ) returning id into v_parent;

  select public.open_coaching_months_for(date '2026-09-01') into v_n;
  if v_n < 1 then
    failures := failures || 'FAILED: a coaching parent made no month'::text;
  else
    raise notice 'ok  a coaching parent makes its month';
  end if;

  select id into v_child from public.authorizations
   where parent_id = v_parent and period = date '2026-09-01';
  if v_child is null then
    failures := failures || 'FAILED: the month was not made as a child'::text;
  end if;
  if (select number from public.authorizations where id = v_child) <> '' then
    failures := failures || 'FAILED: the child carries a USOR number of its own'::text;
  else
    raise notice 'ok  the month carries no number: the number is the parent''s';
  end if;
  if (select bill_by from public.authorizations where id = v_child) <> date '2026-10-07' then
    failures := failures || format('FAILED: the month bills by %s, not seven days after it ended',
      (select bill_by from public.authorizations where id = v_child))::text;
  else
    raise notice 'ok  a coaching month bills seven days after the month ends';
  end if;

  -- Running it twice makes one month.
  perform public.open_coaching_months_for(date '2026-09-01');
  select count(*) into v_n from public.authorizations
   where parent_id = v_parent and period = date '2026-09-01';
  if v_n <> 1 then
    failures := failures || format('FAILED: running it twice made %s months', v_n)::text;
  else
    raise notice 'ok  running it twice for one month makes one month';
  end if;

  -- Hours on the month roll up to the parent.
  insert into public.service_entries (auth_id, date, hours, non_billable, notes)
  values (v_child, date '2026-09-15', 8, false, 'ZZ');

  -- Asked of this parent, not of the count: the function serves every
  -- coaching parent in the practice, so a global zero would be wrong.
  perform public.open_coaching_months_for(date '2026-10-01');
  if exists (select 1 from public.authorizations
              where parent_id = v_parent and period = date '2026-10-01') then
    failures := failures || 'FAILED: a month was made after the parent''s hours were used up'::text;
  else
    raise notice 'ok  no new month once the authorized hours are gone';
  end if;

  -- ── §13.8: an empty month closes itself ───────────────────
  insert into public.authorizations (
    client_id, number, service_type, rate_type, rate, total_hours,
    start_date, end_date, received_on, stale_date, bill_by, status
  ) values (
    v_client, 'ZZ-COACH-2', 'Job Coaching', 'Hourly', 45, 40,
    date '2026-08-01', date '2026-12-31', date '2026-08-01', date '2026-12-31',
    date '2026-08-08', 'Authorized'
  ) returning id into v_parent;
  perform public.open_coaching_months_for(date '2026-08-01');

  select public.close_empty_coaching_months(date '2026-10-01') into v_n;
  if v_n < 1 then
    failures := failures || 'FAILED: a finished month with no hours did not close itself'::text;
  else
    raise notice 'ok  a finished month with no hours closes itself, with a reason';
  end if;
  select status into v_status from public.authorizations
   where parent_id = v_parent and period = date '2026-08-01';
  if v_status <> 'Closed' then
    failures := failures || format('FAILED: the empty month is %s', v_status)::text;
  end if;

  -- ── §13.11: one line per row, not four flags ──────────────
  select count(*) into v_n from public.billing_worklist()
   where attention is null;
  if v_n > 0 then
    failures := failures || 'FAILED: a worklist row has no attention line at all'::text;
  end if;
  select count(*) into v_n from public.billing_worklist() where attention like '%;%';
  if v_n > 0 then
    failures := failures || format('FAILED: %s worklist row(s) say more than one thing', v_n)::text;
  else
    raise notice 'ok  every row on the worklist says one thing';
  end if;

  -- A coaching parent is not itself a bill.
  select count(*) into v_n from public.billing_worklist() w
   where w.id in (select parent_id from public.authorizations where parent_id is not null);
  if v_n > 0 then
    failures := failures || 'FAILED: a coaching parent appeared on the billing worklist'::text;
  else
    raise notice 'ok  a coaching parent is not a bill; its months are';
  end if;

  -- Paid and Closed are off the working list (§9).
  select count(*) into v_n from public.billing_worklist() w
   join public.authorizations a on a.id = w.id
   where a.status in ('Paid', 'Closed');
  if v_n > 0 then
    failures := failures || 'FAILED: Paid or Closed rows are on the working list'::text;
  else
    raise notice 'ok  Paid and Closed do not appear on the working list';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
