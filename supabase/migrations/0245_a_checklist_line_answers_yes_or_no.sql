-- Zion Vocational Rehab CRM — 0245 a checklist line answers yes or no
--
-- The submission checklist's line "Service dates are the work's own" answered
-- null for V1037898, and `verify_submission_gate` caught it the way it was
-- written to: it asks that no line, on any authorization the practice
-- actually has, comes back null, because a null reads as a tick.
--
-- The cause is three-valued logic, in a line that looks like it cannot have
-- any. The test was "the service dates are not simply a copy of the
-- authorization's":
--
--     not (service_start = start_date and service_end = end_date)
--
-- V1037898 has a start date, a service start the same, a service end in
-- October, and **no end date at all**. So `service_end = end_date` is null
-- rather than false, `true and null` is null, and `not null` is null. The
-- line answered nothing, and nothing looks like a pass.
--
-- `is distinct from` is the comparison that was meant: a date and a missing
-- date are different, which is the honest answer and also the useful one -
-- the work's end date is recorded and the authorization has none, so the
-- dates are the work's own and the line passes.
--
-- Built from the live definition, which is the rest of this file unchanged.

CREATE OR REPLACE FUNCTION public.authorization_gate(p_auth uuid)
 RETURNS TABLE(line text, passed boolean, detail text, blocking boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  -- `is distinct from`, not `=`: an authorization with no end date made
  -- `a.service_end = a.end_date` null, which made the whole expression null,
  -- which made the line answer neither yes nor no. A checklist line that
  -- answers null reads as passing, which is the one thing a checklist must
  -- never do (0245).
  passed := a.service_start is null
    or a.service_start is distinct from a.start_date
    or a.service_end is distinct from a.end_date;
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
$function$;
