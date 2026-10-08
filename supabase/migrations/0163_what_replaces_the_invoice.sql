-- Zion Vocational Rehab CRM — what replaces the invoice
-- (Billing Simplification Brief §§10, 11, 13.17), part one of two
--
-- "Remove the invoice record entirely - table, screens, actions, quick-add
-- entry, client-record section, exports. There is no 'New invoice' anywhere."
-- And §13.17: removed from the codebase, not left dormant.
--
-- The money is already on the authorization. §7 folded it there and proved it:
-- 139 paid invoices, 142,947.50, matched to the penny. What goes here is the
-- second copy - the record that could disagree with the first, which is the
-- whole reason this brief exists.
--
-- Nothing is lost, and nothing has to be re-derived, because every link the
-- invoice carried is already carried by the authorization:
--
--   payments.auth_id is NOT NULL on all 139 rows, so no payment needs the
--   invoice to say what it paid for.
--
--   warrant_lines.auth_id is how a matched line is already recorded; §13.9
--   takes that further.
--
--   billing_items goes with it (frozen since 0158, read by nothing since §9),
--   and its events and its two views with it.
--
-- Two things that read the invoice are rewritten rather than dropped:
--
--   invoice_date_for() is the CRP billing pathway's dating rule - the first
--   coaching day of the month, the first day of work, the stability date. That
--   rule is about when work happened, not about invoices, and it is worth
--   keeping. It is service_date_for() now, and the "month not yet invoiced"
--   part reads the months already submitted or paid instead.
--
--   What the invoice was asked for - money billed and money received, over
--   time, by service - becomes a view over the authorizations, billed_work.
--   Twelve callers wanted that shape; one view means twelve callers cannot each
--   invent their own version of it (§11).
--
-- And one is dropped as a duplicate: billing_gate_met() asked exactly the
-- question authorization_missing_forms() answers, in slightly different words.
-- Two functions that answer the same question are two functions that will one
-- day answer it differently.

-- ── What the invoice was asked for, from the record that has it ──

create or replace view public.billed_work as
  select a.id                                as auth_id,
         a.client_id,
         a.service_type,
         a.number,
         a.period,
         a.status,
         -- When it was billed.
         --
         -- The day the packet went, for anything billed through the CRM. The
         -- 139 rows carried over from the workbook have no submission date, so
         -- they fall back to the day they were paid - which is exactly what
         -- the invoice held: its date equalled paid_on on all 139 of them, to
         -- the day. There was never a real billing date for that history, and
         -- this is the same fact rather than a worse one.
         --
         -- It is also why §7 refused to backfill submitted_on from paid_on: a
         -- payment lag computed from these rows reads zero days, and writing
         -- that into the record would have made the forecast believe it.
         coalesce(a.submitted_on, a.paid_on) as billed_on,
         public.authorization_amount(a.id)   as amount,
         a.paid_on,
         a.paid_amount,
         a.warrant,
         -- The old invoice statuses, for the reports that counted them:
         -- Sent meant submitted and not yet paid.
         (a.status = 'Submitted')            as outstanding,
         (a.status = 'Paid')                 as paid
    from public.authorizations a
   where a.status in ('Submitted', 'Paid')
     -- A coaching parent is not a bill; its months are.
     and not exists (select 1 from public.authorizations c where c.parent_id = a.id);

alter view public.billed_work set (security_invoker = true);
grant select on public.billed_work to authenticated;

comment on view public.billed_work is
  'Work that has been billed: what went to USOR, what it came to, and what came back (§§10, 11). This is what the invoice table was read for, from the authorization that now holds it.';

-- ── The pathway's dating rule, which was never about invoices ──

create or replace function public.service_date_for(p_auth uuid)
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
  -- Coaching is billed monthly, so the month being billed now is the first one
  -- after the latest month already billed that has billable hours in it. What
  -- counts as "already billed" is a month of this authorization that has been
  -- submitted or paid - which is where the invoice used to come in.
  if v_service = 'Job Coaching' then
    select to_char(max(coalesce(m.period, m.submitted_on)), 'YYYY-MM') into v_last
      from public.authorizations m
     where (m.id = p_auth or m.parent_id = coalesce(
              (select parent_id from public.authorizations where id = p_auth), p_auth))
       and m.status in ('Submitted', 'Paid');
    select min(se.date) into v_date
      from public.service_entries se
     where se.auth_id = p_auth and not se.non_billable
       and (v_last is null or to_char(se.date, 'YYYY-MM') > v_last);
    if v_date is not null then
      return query select v_date, 'The first coaching day of the month (CRP billing pathway)'::text;
    else
      return query select public.practice_today(), 'No billable coaching logged for a month not yet billed, so today'::text;
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
  select to_char(max(coalesce(m.period, m.submitted_on)), 'YYYY-MM') into v_last
    from public.authorizations m
   where m.id = p_auth and m.status in ('Submitted', 'Paid');
  select min(se.date) into v_date
    from public.service_entries se
   where se.auth_id = p_auth and not se.non_billable
     and (v_last is null or to_char(se.date, 'YYYY-MM') > v_last);
  if v_date is not null then
    return query select v_date, 'The first service day not yet billed (the CRM''s rule - the pathway does not give one for this service)'::text;
  else
    return query select public.practice_today(), 'No billable service logged, so today'::text;
  end if;
end;
$$;

comment on function public.service_date_for is
  'When a piece of work is dated for billing, by the CRP billing pathway (§10). Was invoice_date_for; the rule was always about when the work happened.';

revoke all on function public.service_date_for(uuid) from anon, authenticated;
grant execute on function public.service_date_for(uuid) to authenticated;


-- Nothing is dropped here. The invoice table, the billing item, and the
-- functions that read them go in 0164, after the screens that read them have
-- shipped - so there is no deploy in which production asks for something that
-- is not there. invoice_date_for() and billing_gate_met() stay alongside their
-- replacements for exactly that one deploy.
