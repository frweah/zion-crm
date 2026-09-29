-- Zion Vocational Rehab CRM — the review gate, the month that makes itself,
-- and the follow-up nobody has to remember (Billing Lifecycle Brief §3, §6,
-- §6a)
--
-- The gate is Margaret's checklist (her §11/§23) asked of the database rather
-- than of a person at eleven at night. Every line says what it looked at, so
-- a line that fails tells you where to go; the send action asks for the whole
-- list and refuses while any line fails.
--
-- One line from her §3 is deliberately not here: "invoice prepared". The
-- owner's decision of 29 Sept is that the packet is the signed authorization
-- and the completed form, and that USOR's own system assigns the invoice
-- number, which is recorded from the warrant. There is no invoice document to
-- prepare, so a gate line asking for one would be a line nobody could ever
-- pass honestly.
--
-- The month that makes itself is Job Coaching only. A month with no hours is
-- not skipped: it is flagged, because "no hours" is far more often a month
-- somebody forgot to log than a month nothing happened in.

/**
 * Margaret's checklist for one item: one row per line, in the order she
 * reads them, each saying whether it passes and what it looked at.
 */
create or replace function public.billing_item_gate(p_item uuid)
returns table (line text, passed boolean, detail text)
language plpgsql stable security definer set search_path = public as $$
declare
  it public.billing_items;
  rule public.billing_service_rules;
  cl record;
  au public.authorizations;
  v_recipient text;
  v_missing text[];
  f text;
begin
  select * into it from public.billing_items where id = p_item;
  if not found then return; end if;
  select * into rule from public.billing_service_rules where service = it.service;
  select c.id, c.name, c.counselor_id, bo.billing_office_id, co.name as counselor
    into cl from public.clients c
    left join public.counselors co on co.id = c.counselor_id
    left join public.client_billing_office bo on bo.client_id = c.id
   where c.id = it.client_id;
  if it.auth_id is not null then select * into au from public.authorizations where id = it.auth_id; end if;

  line := 'Client and counselor';
  passed := cl.id is not null and cl.counselor_id is not null;
  detail := coalesce(cl.name, 'no client') || ' · ' || coalesce(cl.counselor, 'no counselor on the record');
  return next;

  line := 'Service and period';
  passed := it.service is not null and (rule.recurrence <> 'Monthly' or it.period is not null);
  detail := it.service || case when it.period is null then '' else ', ' || to_char(it.period, 'FMMonth YYYY') end;
  return next;

  line := 'Service finished';
  if rule.ready_rule = 'weeks after first work day' then
    passed := it.first_work_day is not null
      and it.first_work_day + (coalesce(rule.ready_weeks, 4) * 7) <= public.practice_today();
    detail := case
      when it.first_work_day is null then 'no first day of work recorded'
      else 'first day ' || to_char(it.first_work_day, 'FMDD Mon') || ', billable from '
           || to_char(it.first_work_day + (coalesce(rule.ready_weeks, 4) * 7), 'FMDD Mon') end;
  else
    passed := it.status <> 'Service in progress' and it.service_end is not null;
    detail := case when it.service_end is null then 'no end date recorded'
                   else 'ended ' || to_char(it.service_end, 'FMDD Mon') end;
  end if;
  return next;

  line := 'Authorization attached and for this service';
  passed := au.id is not null and au.service_type = it.service;
  detail := coalesce(au.number, 'none attached');
  return next;

  line := 'Authorization dates recorded';
  passed := au.start_date is not null and au.end_date is not null;
  detail := case when au.start_date is null then 'missing'
                 else to_char(au.start_date, 'FMDD Mon') || ' to ' || to_char(au.end_date, 'FMDD Mon YYYY') end;
  return next;

  -- Her §4: the work happened when it happened. An item whose service dates
  -- are exactly the authorization's is the classic copied-across mistake, so
  -- it is shown rather than passed quietly.
  line := 'Service dates recorded, and their own';
  passed := it.service_start is not null
    and not (au.id is not null and it.service_start = au.start_date and it.service_end = au.end_date);
  detail := case
    when it.service_start is null then 'missing'
    when au.id is not null and it.service_start = au.start_date and it.service_end = au.end_date
      then 'these are the authorization''s dates - record when the work actually happened'
    else to_char(it.service_start, 'FMDD Mon') || coalesce(' to ' || to_char(it.service_end, 'FMDD Mon'), '') end;
  return next;

  line := 'Signed authorization';
  passed := it.signed_auth_path is not null;
  detail := coalesce('stamped and stored', 'not yet signed');
  if it.signed_auth_path is null then detail := 'not yet signed'; end if;
  return next;

  line := 'Amount or hours';
  if coalesce(it.billing_type, rule.billing_type) = 'Hourly' then
    passed := coalesce(it.hours, 0) > 0 and coalesce(it.rate, 0) > 0;
    detail := coalesce(it.hours, 0) || ' h × ' || trim(to_char(coalesce(it.rate, 0), 'FM$999,990.00'));
  else
    passed := coalesce(it.amount, 0) > 0;
    detail := trim(to_char(coalesce(it.amount, 0), 'FM$999,990.00'));
  end if;
  return next;

  line := 'USOR forms complete';
  v_missing := '{}';
  foreach f in array coalesce(rule.usor_forms, '{}') loop
    if not exists (
      select 1 from public.forms fo join public.form_templates t on t.id = fo.template_id
       where fo.client_id = it.client_id
         and (fo.auth_id is null or fo.auth_id = it.auth_id)
         and t.usor = 'DWS-USOR ' || f
         and fo.completed_at is not null
         -- A form's month is text, "2026-09", which is how the form itself
         -- names it; the item's period is a date. They are compared as the
         -- month either of them means.
         and (it.period is null or fo.month is null or fo.month = to_char(it.period, 'YYYY-MM'))
    ) then
      v_missing := v_missing || f;
    end if;
  end loop;
  passed := array_length(v_missing, 1) is null;
  detail := case when array_length(v_missing, 1) is null
                 then 'USOR ' || array_to_string(coalesce(rule.usor_forms, '{}'), ' and ') || ' complete'
                 else 'USOR ' || array_to_string(v_missing, ' and ') || ' not complete' end;
  return next;

  line := 'Billing recipient';
  select bo.billing_email into v_recipient from public.billing_offices bo where bo.id = cl.billing_office_id;
  passed := coalesce(v_recipient, it.recipient) is not null and coalesce(v_recipient, it.recipient) like '%@%';
  detail := coalesce(v_recipient, it.recipient, 'no billing office on the client');
  return next;
end;
$$;
revoke execute on function public.billing_item_gate(uuid) from public, anon;
grant execute on function public.billing_item_gate(uuid) to authenticated;

/** Whether every line of the gate passes - what the send action asks. */
create or replace function public.billing_item_ready(p_item uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select not exists (select 1 from public.billing_item_gate(p_item) where not passed);
$$;
revoke execute on function public.billing_item_ready(uuid) from public, anon;
grant execute on function public.billing_item_ready(uuid) to authenticated;

-- ── the month that makes itself (Job Coaching only) ────────

/**
 * Opens this month's item for every open Job Coaching authorization, and
 * closes off the month before.
 *
 * Runs on the 1st. Opening is all it does: nothing is invoiced, and nothing
 * leaves the building, because a month that has just started has nothing to
 * say yet.
 *
 * A month that ended with no hours logged is marked as a question, not as a
 * fact - zero_hours_flagged - and stays Service period complete until
 * somebody says which it was.
 */
create or replace function public.open_coaching_items_for(p_month date)
returns integer language plpgsql security definer set search_path = public as $$
declare
  v_month date := date_trunc('month', p_month)::date;
  v_prev date := (v_month - interval '1 month')::date;
  v_made integer := 0;
  r record;
begin
  -- The month that just ended: complete, and flagged if it has no hours.
  update public.billing_items i
     set status = 'Service period complete',
         hours = coalesce(u.hours, 0),
         zero_hours_flagged = coalesce(u.hours, 0) = 0,
         service_end = least(v_month - 1, coalesce(i.service_end, v_month - 1))
    from (
      select i2.id,
             (select sum(se.hours) from public.service_entries se
               where se.auth_id = i2.auth_id
                 and not se.non_billable
                 and se.date >= i2.period
                 and se.date < (i2.period + interval '1 month')::date) as hours
        from public.billing_items i2
       where i2.period = v_prev and i2.status = 'Service in progress'
    ) u
   where i.id = u.id;

  for r in
    select a.id as auth_id, a.client_id, a.rate, c.billing_staff_id
      from public.authorizations a
      join public.clients c on c.id = a.client_id
     where a.service_type = 'Job Coaching'
       and a.status = 'Open'
       and a.start_date <= (v_month + interval '1 month' - interval '1 day')::date
       and (a.end_date is null or a.end_date >= v_month)
       and c.merged_into is null
  loop
    insert into public.billing_items (client_id, auth_id, service, period, status, billing_type, rate, assigned_staff_id, service_start)
    values (r.client_id, r.auth_id, 'Job Coaching', v_month, 'Service in progress', 'Hourly', r.rate, r.billing_staff_id, null)
    on conflict (client_id, service, period) do nothing;
    if found then v_made := v_made + 1; end if;
  end loop;

  return v_made;
end;
$$;
revoke execute on function public.open_coaching_items_for(date) from public, anon, authenticated;
grant execute on function public.open_coaching_items_for(date) to service_role;

-- ── the follow-up nobody has to remember ───────────────────

/**
 * An item submitted 14 days ago with no answer gets a task for whoever bills
 * it, and another every 14 days until it is paid or a correction is asked
 * for (her §6a, owner 29 Sept).
 */
create or replace function public.billing_followups_on(p_today date)
returns integer language plpgsql security definer set search_path = public as $$
declare r record; v_made integer := 0;
begin
  for r in
    select i.id, i.client_id, i.service, i.period, i.assigned_staff_id, c.name as client_name,
           i.submitted_at::date as sent_on
      from public.billing_items i
      join public.clients c on c.id = i.client_id
     where i.status in ('Submitted', 'Pending')
       and i.submitted_at is not null
       and coalesce(i.followup_due, i.submitted_at::date + 14) <= p_today
  loop
    insert into public.tasks (client_id, assigned_staff_id, title, due, status, system_generated, source_kind, source_match_id)
    values (r.client_id,
            r.assigned_staff_id,
            'No answer yet on ' || r.service || coalesce(' for ' || to_char(r.period, 'FMMonth'), '')
              || ' - sent ' || to_char(r.sent_on, 'FMDD Mon') || '. Chase it.',
            p_today,
            'Open', true, 'billing_item', r.id)
    on conflict do nothing;
    update public.billing_items set followup_due = p_today + 14 where id = r.id;
    v_made := v_made + 1;
  end loop;
  return v_made;
end;
$$;
revoke execute on function public.billing_followups_on(date) from public, anon, authenticated;
grant execute on function public.billing_followups_on(date) to service_role;

-- ── the list Margaret reads ────────────────────────────────
create or replace view public.billing_item_rows
with (security_invoker = true) as
  select i.id,
         i.client_id,
         c.name as client_name,
         c.client_no,
         i.service,
         i.period,
         i.status,
         a.number as auth_number,
         a.status as auth_status,
         a.end_date as auth_end,
         i.service_start,
         i.service_end,
         i.first_work_day,
         coalesce(i.billing_type, r.billing_type) as billing_type,
         r.usor_forms,
         r.recurrence,
         i.hours,
         i.rate,
         coalesce(i.amount, i.hours * i.rate) as value,
         i.assigned_staff_id,
         s.name as assigned_staff,
         i.recipient,
         i.submitted_at,
         i.paid_on,
         i.paid_amount,
         i.followup_due,
         i.zero_hours_flagged,
         i.correction_note,
         i.closed_reason,
         i.signed_auth_path is not null as signed
    from public.billing_items i
    join public.clients c on c.id = i.client_id
    left join public.authorizations a on a.id = i.auth_id
    left join public.staff s on s.id = i.assigned_staff_id
    left join public.billing_service_rules r on r.service = i.service;

grant select on public.billing_item_rows to authenticated;

comment on view public.billing_item_rows is
  'Her columns, in her order (0124): client, service, period, authorization, service and billing status, form, value, who has it, recipient, dates.';
