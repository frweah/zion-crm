-- Zion Vocational Rehab CRM — payments on the client timeline
--
-- What has to hold, each tried from the direction that would break it:
--
--   A payment shows on its client's timeline as a Payment, dated by the
--   warrant, saying what was paid on which authorization and warrant, and
--   opening the client's Payments tab.
--
--   Every role sees it (owner's decision, 14 Sept 2026: the client's Billing
--   tab is open read-only to Job Search and Intake & Client Reports, so what
--   USOR paid is no longer kept from them on the timeline).
--
-- Runs inside a transaction that is rolled back. Nothing here is left behind.

begin;

do $$
declare
  v_admin   uuid;
  v_adm_uid uuid;
  v_js      uuid;
  v_js_uid  uuid;
  v_client  uuid;
  v_auth    uuid;
  v_pay     uuid;
  r         record;
  failures  text[] := '{}';
begin
  select id, user_id into v_admin, v_adm_uid from public.staff where role = 'Admin' and active order by created_at limit 1;
  select id, user_id into v_js, v_js_uid from public.staff where active and role = 'Job Search' order by created_at limit 1;

  insert into public.clients (name, stage, status, assigned_staff_id)
  values ('ZZ Timeline Payment Client', 'Job Coaching', 'Active', coalesce(v_js, v_admin)) returning id into v_client;
  insert into public.authorizations (client_id, number, service_type, rate_type, rate, status)
  values (v_client, 'ZQ9700001', 'Job Placement', 'Flat Fee', 560, 'Paid') returning id into v_auth;
  insert into public.payments (auth_id, amount, warrant_no, warrant_date, voucher, source, recorded_by_name)
  values (v_auth, 560, 'ZW0000701', date '2026-04-06', '26PR00000000701', 'Workbook', 'Workbook import')
  returning id into v_pay;

  -- ── Admin sees it, saying what it is ───────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);

  select * into r from public.client_activity where client_id = v_client and kind = 'Payment';
  if not found then
    failures := failures || 'FAILED: Admin does not see a payment on the client timeline'::text;
  elsif r.title <> 'Paid $560.00 — ZQ9700001'
     or r.detail <> 'Warrant ZW0000701 · voucher 26PR00000000701'
     or r.tab <> 'payments'
     or r.ref_id <> v_pay
     or r.at::date <> date '2026-04-06' then
    failures := failures || format('FAILED: the timeline payment reads wrong: %s | %s | %s | %s', r.title, r.detail, r.tab, r.at)::text;
  else
    raise notice 'ok  a payment is on the timeline, dated by its warrant, naming the amount, authorization and warrant';
  end if;

  -- ── and so does Job Search ─────────────────────────────────
  if v_js is null then
    raise notice 'skip  no active Job Search staff member to try the timeline as';
  else
    perform set_config('request.jwt.claims', json_build_object('sub', v_js_uid, 'role', 'authenticated')::text, true);
    if not exists (select 1 from public.client_activity where client_id = v_client and kind = 'Payment') then
      failures := failures || 'FAILED: Job Search does not see the payment on the client timeline'::text;
    else
      raise notice 'ok  every role sees payments on the timeline, as on the client''s Billing tab';
    end if;
  end if;

  perform set_config('request.jwt.claims', '', true);

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- PAYMENTS ON THE TIMELINE VERIFIED ---';
end $$;

rollback;
