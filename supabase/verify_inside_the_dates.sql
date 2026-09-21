-- Zion Vocational Rehab CRM — work inside the dates (0116)
--
-- What has to hold, each tried from the direction that would break it:
--
--   A new flat-fee authorization has a completion to record.
--
--   A completion outside the authorization's dates, before the work
--   started, or in the future is refused.
--
--   Billable hours outside the authorization's dates are refused; the same
--   hours marked non-billable are not.
--
--   A flat-fee invoice cannot be sent until a completion is recorded, and
--   can be once it is.
--
--   The client record says when an authorization ends within a month with
--   money on it - a flat fee with nothing recorded, and hours with nothing
--   logged - and stops saying so once it is invoiced.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_client uuid;
  v_flat   uuid;
  v_hourly uuid;
  v_inv    uuid;
  v_detail text;
  failures text[] := '{}';
begin
  insert into public.clients (name, stage, status) values ('ZZ Dates Window', 'Placement', 'Active') returning id into v_client;
  insert into public.authorizations (client_id, number, service_type, rate_type, rate, status, start_date, end_date)
  values (v_client, 'V0000881', 'Job Placement', 'Flat Fee', 2250, 'Open', public.practice_today() - 40, public.practice_today() + 9)
  returning id into v_flat;
  insert into public.authorizations (client_id, number, service_type, total_hours, rate_type, rate, status, start_date, end_date)
  values (v_client, 'V0000882', 'Job Coaching', 20, 'Hourly', 45, 'Open', public.practice_today() - 40, public.practice_today() + 9)
  returning id into v_hourly;

  -- ── a completion to record ────────────────────────────────
  if not exists (select 1 from public.completions where auth_id = v_flat) then
    failures := failures || 'FAILED: a new flat-fee authorization has nowhere to record its completion'::text;
  end if;

  -- ── the ending-soon line, before anything is done ─────────
  select detail into v_detail from public.client_next_actions(v_client) where title like 'Authorization V0000881%';
  if v_detail is null or v_detail not like 'No completion recorded%' then
    failures := failures || format('FAILED: a flat fee ending in 9 days with nothing recorded was not flagged (%s)', v_detail);
  end if;
  select detail into v_detail from public.client_next_actions(v_client) where title like 'Authorization V0000882%';
  if v_detail is null or v_detail not like 'No hours logged%' then
    failures := failures || format('FAILED: hourly work ending in 9 days with nothing logged was not flagged (%s)', v_detail);
  else
    raise notice 'ok  an authorization ending within a month with money on it is flagged, whatever kind it is';
  end if;

  -- ── a completion inside the dates ──────────────────────────
  begin
    update public.completions set completion = public.practice_today() + 1 where auth_id = v_flat;
    failures := failures || 'FAILED: a completion in the future was recorded'::text;
  exception when check_violation then null;
  end;
  begin
    update public.completions set completion = public.practice_today() - 60 where auth_id = v_flat;
    failures := failures || 'FAILED: a completion before the authorization began was recorded'::text;
  exception when check_violation then null;
  end;

  -- ── hours inside the dates ────────────────────────────────
  begin
    insert into public.service_entries (auth_id, date, hours, notes, non_billable, primary_code, secondary_code)
    values (v_hourly, public.practice_today() - 50, 2, 'ZZ before the dates', false, '', '');
    failures := failures || 'FAILED: billable hours before the authorization began were logged'::text;
  exception when check_violation then null;
  end;
  insert into public.service_entries (auth_id, date, hours, notes, non_billable, primary_code, secondary_code)
  values (v_hourly, public.practice_today() - 50, 2, 'ZZ before the dates, not billed', true, '', '');
  insert into public.service_entries (auth_id, date, hours, notes, non_billable, primary_code, secondary_code)
  values (v_hourly, public.practice_today() - 5, 2, 'ZZ inside the dates', false, '', '');
  raise notice 'ok  completions and billable hours outside the dates are refused; non-billable hours are not';

  -- ── a flat fee is not sent without its completion ──────────
  insert into public.invoices (auth_id, number, date, amount, status) values (v_flat, 'ZZ-881', public.practice_today(), 2250, 'Draft')
  returning id into v_inv;
  begin
    update public.invoices set status = 'Sent' where id = v_inv;
    failures := failures || 'FAILED: a flat-fee invoice was sent with no completion recorded'::text;
  exception when check_violation then null;
  end;

  update public.completions set completion = public.practice_today() - 3 where auth_id = v_flat;
  -- Job Placement also needs its USOR forms before it goes (0002). They are
  -- not what is being tried here, so they are put on file.
  insert into public.forms (template_id, client_id, auth_id, status, data)
  select t.id, v_client, v_flat, 'Completed', '{}'::jsonb
    from public.form_templates t
   where t.required_for_billing and 'Job Placement' = any (t.services);
  update public.invoices set status = 'Sent' where id = v_inv;
  if (select status from public.invoices where id = v_inv) <> 'Sent' then
    failures := failures || 'FAILED: a flat-fee invoice with its completion recorded could not be sent'::text;
  else
    raise notice 'ok  a flat-fee invoice goes only once its completion is recorded';
  end if;

  if exists (select 1 from public.client_next_actions(v_client) where title like 'Authorization V0000881%') then
    failures := failures || 'FAILED: an authorization invoiced in full is still flagged as ending with money on it'::text;
  end if;

  if has_function_privilege('anon', 'public.client_next_actions(uuid)', 'execute') then
    failures := failures || 'FAILED: somebody not signed in can read what is next for a client'::text;
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
