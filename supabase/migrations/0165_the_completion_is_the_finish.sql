-- Zion Vocational Rehab CRM — a flat fee is finished when its completion says so
-- (Billing Simplification Brief §§10, 11, 12.3)
--
-- The invoice carried three guards, and all three fired only when an invoice's
-- status became 'Sent'. No invoice in this database has ever been Sent: all 139
-- are paid history imported from the workbook. So all three had never once
-- run - the forms guard, the amount guard, and this one:
--
--   "Invoice cannot be sent: it is a flat fee and no completion date is
--    recorded."
--
-- That is a real rule. A flat fee is earned on completion, and billing one
-- with no recorded completion is billing work nobody has recorded as finished.
-- But it has never been enforced, and on the live data it would refuse 7 of
-- the 15 flat fees currently being worked. Making a dormant rule into a wall
-- in front of half of Margaret's flat-fee work is the same mistake the forms
-- gate was, and the reason is the same: §4's "a wall built on inherited data
-- stops the close over something nobody at the practice did".
--
-- So it goes where it belongs - onto the checklist, where it is computed and
-- shown and the person billing can see it - and not onto the submit as a
-- refusal. The checklist's 'Service finished' line already asked this question
-- for flat fees and asked it of the wrong column: it read service_end, while
-- the fact lives in completions.completion, which is what the whole practice
-- records and what the old guard read. §11: one fact, one place, and this line
-- now reads the place.
--
-- If the owner wants it to refuse, that is one word - blocking := true - and
-- it will refuse honestly, because the line will be telling the truth first.

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

  -- 1. Who it is for. Read from the client, never re-entered (§13.12).
  line := 'Client, counselor and billing office';
  passed := cl.id is not null and cl.counselor_id is not null and cl.billing_office_id is not null;
  detail := coalesce(cl.name, 'no client') || ' · ' || coalesce(cl.counselor, 'no counselor on the record')
            || case when cl.billing_office_id is null then ' · no billing office' else '' end;
  blocking := false;
  return next;

  -- 2. What it is for.
  line := 'Service and period';
  passed := a.service_type is not null
            and (coalesce(rule.recurrence, 'One-time') <> 'Monthly' or a.period is not null);
  detail := a.service_type
            || case when a.period is null then '' else ', ' || to_char(a.period, 'FMMonth YYYY') end;
  blocking := false;
  return next;

  -- 3. Whether the work is finished, by the service's own rule.
  --
  -- A flat fee is finished when its completion is recorded and verified -
  -- that is the practice's own record of it, and what the invoice's guard
  -- read. Hourly work in a month is finished when the month is over.
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

  -- 4. The signed authorization, which is half the packet (§8).
  line := 'Signed authorization attached';
  passed := exists (
    select 1 from public.attachments t
     where t.auth_id = p_auth and t.category = 'Authorization');
  detail := case when passed then 'on file' else 'not attached' end;
  blocking := false;
  return next;

  -- 5. The dates USOR allowed.
  line := 'Authorization dates recorded';
  passed := a.start_date is not null and a.end_date is not null;
  detail := case
    when a.start_date is null and a.end_date is null then 'neither recorded'
    when a.end_date is null then 'starts ' || to_char(a.start_date, 'FMDD Mon YYYY') || ', no end date'
    when a.start_date is null then 'ends ' || to_char(a.end_date, 'FMDD Mon YYYY') || ', no start date'
    else to_char(a.start_date, 'FMDD Mon') || ' to ' || to_char(a.end_date, 'FMDD Mon YYYY') end;
  blocking := false;
  return next;

  -- 6. The work inside those dates. This one refuses (§4, owner 7 Oct).
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

  -- 6b. §4, kept from the old checklist: service dates identical to the
  -- authorization's are the classic copied-across mistake.
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

  -- 7. Hours within what was authorized. The parent holds them (§5).
  v_auth_h := coalesce(parent.total_hours, a.total_hours);
  select coalesce(sum(e.hours), 0) into v_hours
    from public.service_entries e
   where not e.non_billable
     and (e.auth_id = coalesce(a.parent_id, a.id)
          or e.auth_id in (select ch.id from public.authorizations ch
                            where ch.parent_id = coalesce(a.parent_id, a.id)));
  line := 'Hours within what was authorized';
  passed := v_auth_h is null or v_hours <= v_auth_h;
  detail := case when v_auth_h is null then 'a flat fee, so no hours to check'
                 else trim(to_char(v_hours, 'FM999990.00')) || ' of '
                      || trim(to_char(v_auth_h, 'FM999990.00')) || ' authorized' end;
  blocking := true;
  return next;

  -- 8. The USOR forms the service requires. Blocking only if the practice has
  -- turned that on - see 0160's header.
  v_missing := public.authorization_missing_forms(p_auth);
  line := 'USOR forms complete and signed';
  passed := v_missing is null;
  detail := coalesce('still outstanding: ' || v_missing, 'all on file')
            || case when v_missing is not null and not v_forms_block
                    then ' (does not stop a submission)' else '' end;
  blocking := v_forms_block;
  return next;

  -- 9. Still submittable. Past the end date warns; past the grace refuses.
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

  -- 10. What it comes to, worked out rather than typed.
  v_amount := public.authorization_amount(p_auth);
  line := 'Amount';
  passed := coalesce(v_amount, 0) > 0;
  detail := case when coalesce(v_amount, 0) = 0
                 then case when a.rate_type = 'Hourly' then 'no billable hours logged yet'
                           else 'no rate on the authorization' end
                 else trim(to_char(v_amount, 'FM999999990.00'))
                      || case when a.rate_type = 'Hourly'
                              then ' (' || trim(to_char(v_hours, 'FM999990.00')) || ' hours at '
                                   || trim(to_char(coalesce(a.rate, 0), 'FM999990.00')) || ')'
                              else ' flat fee' end end;
  blocking := false;
  return next;

  -- 11. Where it is going.
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
