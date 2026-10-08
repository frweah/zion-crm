-- Zion Vocational Rehab CRM — one definition of "this authorization's hours"
-- (Billing Simplification Brief §§5, 11)
--
-- Moving coaching hours onto the month (0171) was right, and it broke the same
-- thing in three places, each of which asked "what hours are on this
-- authorization?" by looking only at the row it was handed:
--
--   the economics view's committed and hours_left (fixed in 0172),
--   the submission checklist's hours line (already counted the family),
--   and service_date_for(), which could no longer find a coaching parent's
--   first billable day and dated everything today.
--
-- Three readers of one fact, each with its own version of it, is what §11 is
-- about - and the third was found by a test rather than by looking, which is
-- the usual way. So the fact gets one definition and the readers use it.
--
-- The economics view keeps its inline sum: it is a spliced definition built
-- from a chain of CTEs, and threading a set-returning function through it buys
-- correctness that is already there at the cost of a rewrite nobody asked for.
-- It is noted here so the next person knows there are two, and why.

/**
 * Every billable hour that belongs to an authorization: its own, and its
 * months'.
 *
 * A coaching authorization holds the hours and its months hold the work (§5),
 * so a question about the authorization's hours is a question about the family.
 * Handed a month, this answers for that month alone - a month is a bill in its
 * own right and its figures are its own.
 */
create or replace function public.authorization_entries(p_auth uuid)
returns setof public.service_entries
language sql stable security definer set search_path = public as $$
  select e.*
    from public.service_entries e
   where e.auth_id = p_auth
      or (exists (select 1 from public.authorizations p
                   where p.id = p_auth and p.parent_id is null)
          and e.auth_id in (select id from public.authorizations where parent_id = p_auth));
$$;

comment on function public.authorization_entries is
  'The billable and non-billable hours belonging to an authorization, counting the months under it (§§5, 11). One definition, so readers cannot each have their own.';

revoke all on function public.authorization_entries(uuid) from anon, authenticated;
grant execute on function public.authorization_entries(uuid) to authenticated;

-- ── the dating rule, reading the family ──

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
  -- The month being billed now is the first one after the latest month already
  -- billed that has billable hours in it. The hours are on the months (0171),
  -- so they are counted across the family.
  if v_service = 'Job Coaching' then
    select to_char(max(coalesce(m.period, m.submitted_on)), 'YYYY-MM') into v_last
      from public.authorizations m
     where (m.id = p_auth or m.parent_id = coalesce(
              (select parent_id from public.authorizations where id = p_auth), p_auth))
       and m.status in ('Submitted', 'Paid');
    select min(se.date) into v_date
      from public.authorization_entries(p_auth) se
     where not se.non_billable
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
      from public.authorization_entries(p_auth) se where not se.non_billable;
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
    from public.authorization_entries(p_auth) se
   where not se.non_billable
     and (v_last is null or to_char(se.date, 'YYYY-MM') > v_last);
  if v_date is not null then
    return query select v_date, 'The first service day not yet billed (the CRM''s rule - the pathway does not give one for this service)'::text;
  else
    return query select public.practice_today(), 'No billable service logged, so today'::text;
  end if;
end;
$$;

revoke all on function public.service_date_for(uuid) from anon, authenticated;
grant execute on function public.service_date_for(uuid) to authenticated;

-- ── and the checklist, reading the same thing ──
-- Its hours line already summed across the family, by hand. Now it asks.

create or replace function public.authorization_gate(p_auth uuid)
returns table (line text, passed boolean, detail text, blocking boolean)
language plpgsql stable security definer set search_path = public as $$
declare
  a        public.authorizations;
  parent   public.authorizations;
  rule     public.billing_service_rules;
  cl       record;
  v_amount numeric;
  v_hours  numeric;
  v_auth_h numeric;
  v_missing text;
  v_recip  text;
  v_blocked date;
  v_done   date;
  v_forms_block boolean := coalesce((select require_forms_to_submit from public.org_settings where id), false);
begin
  select * into a from public.authorizations where id = p_auth;
  if not found then return; end if;
  if a.parent_id is not null then
    select * into parent from public.authorizations where id = a.parent_id;
  end if;
  select * into rule from public.billing_service_rules where service = a.service_type;
  select c.id, c.name, c.counselor_id, bo.billing_office_id, co.name as counselor
    into cl
    from public.clients c
    left join public.counselors co on co.id = c.counselor_id
    left join public.client_billing_office bo on bo.client_id = c.id
   where c.id = a.client_id;

  line := 'Client, counselor and billing office';
  passed := cl.id is not null and cl.counselor_id is not null and cl.billing_office_id is not null;
  detail := coalesce(cl.name, 'no client') || ' · ' || coalesce(cl.counselor, 'no counselor on the record')
            || case when cl.billing_office_id is null then ' · no billing office' else '' end;
  blocking := false;
  return next;

  line := 'Service and period';
  passed := a.service_type is not null
            and (coalesce(rule.recurrence, 'One-time') <> 'Monthly' or a.period is not null);
  detail := a.service_type
            || case when a.period is null then '' else ', ' || to_char(a.period, 'FMMonth YYYY') end;
  blocking := false;
  return next;

  line := 'Service finished';
  if a.rate_type = 'Flat Fee' then
    select max(co.completion) into v_done
      from public.completions co where co.auth_id = a.id and co.completion is not null;
    passed := v_done is not null;
    detail := case
      when v_done is not null then 'completed ' || to_char(v_done, 'FMDD Mon YYYY')
      when coalesce(rule.ready_rule, '') = 'weeks after first work day' and a.first_work_day is not null
        then 'no completion recorded - first day of work ' || to_char(a.first_work_day, 'FMDD Mon')
             || ', billable from '
             || to_char(a.first_work_day + (coalesce(rule.ready_weeks, 4) * 7), 'FMDD Mon')
      else 'no completion recorded for this flat fee' end;
  elsif coalesce(rule.ready_rule, '') = 'weeks after first work day' then
    passed := a.first_work_day is not null
      and a.first_work_day + (coalesce(rule.ready_weeks, 4) * 7) <= public.practice_today();
    detail := case
      when a.first_work_day is null then 'no first day of work recorded'
      else 'first day ' || to_char(a.first_work_day, 'FMDD Mon') || ', billable from '
           || to_char(a.first_work_day + (coalesce(rule.ready_weeks, 4) * 7), 'FMDD Mon') end;
  elsif a.period is not null then
    passed := (a.period + interval '1 month')::date <= public.practice_today();
    detail := case when (a.period + interval '1 month')::date <= public.practice_today()
                   then to_char(a.period, 'FMMonth') || ' has finished'
                   else to_char(a.period, 'FMMonth') || ' is still running' end;
  else
    passed := a.service_end is not null;
    detail := case when a.service_end is null then 'no end date recorded'
                   else 'ended ' || to_char(a.service_end, 'FMDD Mon') end;
  end if;
  blocking := false;
  return next;

  line := 'Signed authorization attached';
  passed := exists (
    select 1 from public.attachments t
     where t.auth_id = p_auth and t.category = 'Authorization');
  detail := case when passed then 'on file' else 'not attached' end;
  blocking := false;
  return next;

  line := 'Authorization dates recorded';
  passed := a.start_date is not null and a.end_date is not null;
  detail := case
    when a.start_date is null and a.end_date is null then 'neither recorded'
    when a.end_date is null then 'starts ' || to_char(a.start_date, 'FMDD Mon YYYY') || ', no end date'
    when a.start_date is null then 'ends ' || to_char(a.end_date, 'FMDD Mon YYYY') || ', no start date'
    else to_char(a.start_date, 'FMDD Mon') || ' to ' || to_char(a.end_date, 'FMDD Mon YYYY') end;
  blocking := false;
  return next;

  line := 'Work inside the authorized period';
  passed := (a.start_date is null or a.service_start is null or a.service_start >= a.start_date)
        and (a.end_date is null or a.service_end is null or a.service_end <= a.end_date)
        and (a.period is null or a.end_date is null
             or a.period <= date_trunc('month', a.end_date)::date);
  detail := case
    when a.service_start is null and a.service_end is null and a.period is null
      then 'no service dates recorded yet'
    when passed then 'inside the authorization'
    when a.start_date is not null and a.service_start is not null and a.service_start < a.start_date
      then 'the work started ' || to_char(a.service_start, 'FMDD Mon')
           || ' and the authorization starts ' || to_char(a.start_date, 'FMDD Mon')
    when a.end_date is not null and a.service_end is not null and a.service_end > a.end_date
      then 'the work ran to ' || to_char(a.service_end, 'FMDD Mon')
           || ' and the authorization ends ' || to_char(a.end_date, 'FMDD Mon')
    else to_char(a.period, 'FMMonth') || ' is after the authorization ends' end;
  blocking := true;
  return next;

  line := 'Service dates are the work''s own';
  passed := a.service_start is null
    or not (a.service_start = a.start_date and a.service_end = a.end_date);
  detail := case
    when a.service_start is null then 'no service dates recorded yet'
    when passed then to_char(a.service_start, 'FMDD Mon')
                     || coalesce(' to ' || to_char(a.service_end, 'FMDD Mon'), '')
    else 'these are the authorization''s own dates - record when the work happened' end;
  blocking := false;
  return next;

  -- The hours of the whole authorization, from the one place that knows what
  -- that means.
  v_auth_h := coalesce(parent.total_hours, a.total_hours);
  select coalesce(sum(e.hours), 0) into v_hours
    from public.authorization_entries(coalesce(a.parent_id, a.id)) e
   where not e.non_billable;
  line := 'Hours within what was authorized';
  passed := v_auth_h is null or v_hours <= v_auth_h;
  detail := case when v_auth_h is null then 'a flat fee, so no hours to check'
                 else trim(to_char(v_hours, 'FM999990.00')) || ' of '
                      || trim(to_char(v_auth_h, 'FM999990.00')) || ' authorized' end;
  blocking := true;
  return next;

  v_missing := public.authorization_missing_forms(p_auth);
  line := 'USOR forms complete and signed';
  passed := v_missing is null;
  detail := coalesce('still outstanding: ' || v_missing, 'all on file')
            || case when v_missing is not null and not v_forms_block
                    then ' (does not stop a submission)' else '' end;
  blocking := v_forms_block;
  return next;

  v_blocked := public.authorization_blocked_from(a.stale_date);
  line := 'Still submittable';
  passed := v_blocked is null or v_blocked >= public.practice_today();
  detail := case
    when a.stale_date is null then 'no end date, so nothing to run out'
    when a.stale_date >= public.practice_today() then 'ends ' || to_char(a.stale_date, 'FMDD Mon YYYY')
    when passed then 'ended ' || to_char(a.stale_date, 'FMDD Mon')
                     || ', submittable until ' || to_char(v_blocked, 'FMDD Mon YYYY')
    else 'ended ' || to_char(a.stale_date, 'FMDD Mon YYYY') || ' and past the grace' end;
  blocking := true;
  return next;

  -- What this record comes to: a month's own hours, not the family's.
  v_amount := public.authorization_amount(p_auth);
  line := 'Amount';
  passed := coalesce(v_amount, 0) > 0;
  detail := case when coalesce(v_amount, 0) = 0
                 then case when a.rate_type = 'Hourly' then 'no billable hours logged yet'
                           else 'no rate on the authorization' end
                 else trim(to_char(v_amount, 'FM999999990.00'))
                      || case when a.rate_type = 'Hourly'
                              then ' (' || trim(to_char(
                                     coalesce((select sum(e.hours) from public.service_entries e
                                                where e.auth_id = p_auth and not e.non_billable), 0),
                                     'FM999990.00')) || ' hours at '
                                   || trim(to_char(coalesce(a.rate, 0), 'FM999990.00')) || ')'
                              else ' flat fee' end end;
  blocking := false;
  return next;

  select o.billing_email into v_recip
    from public.billing_offices o where o.id = cl.billing_office_id;
  line := 'Billing recipient';
  passed := coalesce(coalesce(v_recip, nullif(a.recipient, '')) like '%@%', false);
  detail := coalesce(v_recip, nullif(a.recipient, ''), 'no billing office on the client');
  blocking := false;
  return next;
end;
$$;

revoke all on function public.authorization_gate(uuid) from anon, authenticated;
grant execute on function public.authorization_gate(uuid) to authenticated;
