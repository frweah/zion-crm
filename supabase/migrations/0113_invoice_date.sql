-- Zion Vocational Rehab CRM — the date that belongs on an invoice
--
-- Every invoice the CRM raised was dated the day it was raised: the Draft that
-- appears when a form completes the billing gate (0110) used practice_today(),
-- and a hand-made invoice with its date left blank took the column default,
-- which is today as well.
--
-- The CRP billing pathway (owner, 20 Sept 2026) says otherwise, and says it
-- per stage:
--
--   Work Strategy Assessment  the first day of WSA activities
--   Job Development           the first meeting with the client to look for work
--   Job Placement             the client's first day of work
--   Job Coaching              the first coaching day of the month
--   High Quality Indicators   the stability date
--
-- Each of those is a date the CRM already holds, or can work out from what it
-- holds: a service log entry, a placement's start date, its stability date.
-- So the invoice is dated by the rule instead of by the calendar.
--
-- Two things this deliberately does not do:
--
--   It does not guess where the pathway is silent. Life Skills, Job Readiness
--   and the other services billed on USOR 148 have no invoice date in either
--   document, so they take the first service day of the period being billed
--   and say, in plain words, that this is the CRM's rule and not USOR's.
--
--   It does not invent a date it has no evidence for. Where the log or the
--   placement is empty, the invoice falls back to today and says why - a
--   visible "no coaching logged, so today" is something Billing can correct,
--   and a confident wrong date is not.

/**
 * The date an invoice against this authorization should carry, and why.
 *
 * `basis` is written to be shown to the person raising the invoice, so they
 * can see which rule was applied and correct it when the rule does not fit.
 */
create or replace function public.invoice_date_for(p_auth uuid)
returns table (on_date date, basis text)
language plpgsql stable security definer set search_path = public as $$
declare
  v_service text;
  v_client  uuid;
  v_date    date;
  v_last    text;
begin
  select a.service_type, a.client_id into v_service, v_client
    from public.authorizations a where a.id = p_auth;
  if v_service is null then
    return query select public.practice_today(), 'No such authorization, so today'::text;
    return;
  end if;

  -- ── Job Coaching: the first coaching day of the month being billed ──
  -- Coaching is billed monthly and each invoice is dated in the month it
  -- bills, so the month being billed now is the first one after the latest
  -- invoice's month that has billable hours in it.
  if v_service = 'Job Coaching' then
    select to_char(max(i.date), 'YYYY-MM') into v_last
      from public.invoices i where i.auth_id = p_auth and i.status <> 'Void';
    select min(se.date) into v_date
      from public.service_entries se
     where se.auth_id = p_auth and not se.non_billable
       and (v_last is null or to_char(se.date, 'YYYY-MM') > v_last);
    if v_date is not null then
      return query select v_date, 'The first coaching day of the month (CRP billing pathway)'::text;
    else
      return query select public.practice_today(), 'No billable coaching logged for a month not yet invoiced, so today'::text;
    end if;
    return;
  end if;

  -- ── Job Placement: the client's first day of work ──────────────
  if v_service like 'Job Placement%' then
    select max(pl.start_date) into v_date
      from public.placements pl where pl.client_id = v_client and pl.start_date is not null;
    if v_date is not null then
      return query select v_date, 'The client''s first day of work (CRP billing pathway)'::text;
    else
      return query select public.practice_today(), 'No placement start date on the record, so today'::text;
    end if;
    return;
  end if;

  -- ── High Quality Indicators: the stability date ───────────────
  if v_service like '%HQ Indicator%' and v_service not like 'Job Development%' then
    select max(pl.stability_on) into v_date
      from public.placements pl where pl.client_id = v_client and pl.stability_on is not null;
    if v_date is not null then
      return query select v_date, 'The stability date (CRP billing pathway)'::text;
    else
      return query select public.practice_today(), 'No stability date on the placement, so today'::text;
    end if;
    return;
  end if;

  -- ── Job Development and WSA: the first day of the work ────────
  -- Both are one fee for a stretch of work, dated from when it began: the
  -- first meeting to look for work, and the first day of WSA activities.
  if v_service like 'Job Development%' or v_service like 'WSA%' then
    select min(se.date) into v_date
      from public.service_entries se where se.auth_id = p_auth and not se.non_billable;
    if v_date is not null then
      return query select v_date,
        (case when v_service like 'WSA%'
              then 'The first day of WSA activities (CRP billing pathway)'
              else 'The first meeting to look for work (CRP billing pathway)' end)::text;
    else
      return query select public.practice_today(),
        (case when v_service like 'WSA%'
              then 'No WSA activity logged yet, so today'
              else 'No job development activity logged yet, so today' end)::text;
    end if;
    return;
  end if;

  -- ── Everything else: the pathway does not say ─────────────────
  -- USOR 148 services and anything else. The first billable day of the period
  -- not yet invoiced, labelled as the CRM's own rule.
  select to_char(max(i.date), 'YYYY-MM') into v_last
    from public.invoices i where i.auth_id = p_auth and i.status <> 'Void';
  select min(se.date) into v_date
    from public.service_entries se
   where se.auth_id = p_auth and not se.non_billable
     and (v_last is null or to_char(se.date, 'YYYY-MM') > v_last);
  if v_date is not null then
    return query select v_date, 'The first service day not yet invoiced (the CRM''s rule - the pathway does not give one for this service)'::text;
  else
    return query select public.practice_today(), 'No billable service logged, so today'::text;
  end if;
end;
$$;

-- ── the Draft raised by the billing gate uses it ───────────────
create or replace function public.draft_invoice_for_authorization(p_auth uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_unbilled numeric;
  v_service  text;
  v_on       date;
  v_id       uuid;
begin
  if not public.is_active_staff() then
    raise exception 'Only staff raise an invoice.' using errcode = 'insufficient_privilege';
  end if;
  if not public.billing_gate_met(p_auth) then
    return null;
  end if;

  -- What the hours come to, less anything already invoiced. The view zeroes
  -- this for an authorization that is not Open, which is what we want.
  select e.unbilled, a.service_type into v_unbilled, v_service
    from public.authorization_economics e
    join public.authorizations a on a.id = e.auth_id
   where e.auth_id = p_auth;

  if coalesce(v_unbilled, 0) <= 0 then
    return null;
  end if;
  if exists (select 1 from public.invoices where auth_id = p_auth and status = 'Draft') then
    return null;
  end if;

  -- Dated by the pathway's rule for the service, not by the calendar (0113).
  select d.on_date into v_on from public.invoice_date_for(p_auth) d;

  -- No number: Billing puts theirs on when they send it. The amount guard
  -- (0002) still applies, and the forms guard checks again on the way out.
  insert into public.invoices (auth_id, amount, status, date, service_type)
  values (p_auth, round(v_unbilled, 2), 'Draft', coalesce(v_on, public.practice_today()), coalesce(v_service, ''))
  returning id into v_id;
  return v_id;
end;
$$;

revoke execute on function public.invoice_date_for(uuid) from public, anon;
grant execute on function public.invoice_date_for(uuid) to authenticated;
revoke execute on function public.draft_invoice_for_authorization(uuid) from public, anon;
grant execute on function public.draft_invoice_for_authorization(uuid) to authenticated, service_role;
