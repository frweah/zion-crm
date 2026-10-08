-- Zion Vocational Rehab CRM — the submission checklist, ticked by the system,
-- and a correction to the gate shipped in 0156
-- (Billing Simplification Brief §§4, 12.3)
--
-- ── The correction first, because it is live ──
--
-- 0156 put a hard block on the submit: every USOR form the service requires
-- has to exist in `forms` with a status other than Draft. I carried it from
-- `check_invoice_forms` on the grounds that an existing rule should not be
-- lost when the invoice goes.
--
-- Two things were wrong with that.
--
-- The rule had never once run. Its trigger fires only when an invoice's
-- status becomes 'Sent', and no invoice has ever been Sent: all 139 in the
-- database are paid history imported from the workbook. So it sat on the
-- invoice table for months without ever being evaluated - and 138 of those
-- 139 invoices are for services that require forms, every one of them with no
-- completed form row, which is to say the rule would have refused the entire
-- history of the practice the first time it was asked. Carrying it onto the
-- submit path made that first time today.
--
-- And it does not match how the practice works. There are four rows in
-- `forms`, none of them completed, against three hundred and five attachments
-- filed as 'Signed USOR form'. The forms are done on paper, signed, scanned
-- and attached. Measured against the live worklist, the block refused
-- twenty-two of twenty-two rows: every authorization waiting to be billed,
-- including all of Margaret's close. The day-one count in the build log said
-- four could not be submitted. The true number under what I shipped was all
-- of them.
--
-- So the forms test stays, computed and shown on the checklist, and whether
-- it refuses a submission is an Admin setting that starts off. That is the
-- same shape as the ninety-day grace: the rule is real, the data to enforce
-- it is not here yet, and a wall built on inherited gaps stops the close over
-- something nobody at the practice did. §13.10 generates the forms from the
-- record, and the day they exist in the system the switch goes on - by
-- somebody choosing it, not by me assuming it.
--
-- ── Then the checklist (§12.3) ──
--
-- "Every item the database can verify is ticked by the system. Only
-- human-judgment items stay manual." The old ten-item checklist was already
-- entirely machine-checkable, so nothing is left to tick by hand.
--
-- One of its ten lines could never pass: 'Signed authorization' read
-- `billing_items.signed_auth_path`, and that column is null on all 153 rows.
-- Nothing ever wrote it. The signed authorization is an attachment filed
-- under 'Authorization' - 104 of them carry the authorization they belong to
-- - so the line reads that instead and passes for 8 of the 22 live rows
-- rather than none of them.
--
-- The gate reports and the trigger refuses, and they share every test below
-- so they cannot drift apart. `blocking` marks the lines that actually stop a
-- submission, so a screen can tell "not tidy yet" from "cannot".

-- ── The switch ──

alter table public.org_settings
  add column if not exists require_forms_to_submit boolean not null default false;

comment on column public.org_settings.require_forms_to_submit is
  'Whether a missing USOR form refuses a submission (§12.3). Off until the forms live in the system rather than on paper - see §13.10. Admin''s to turn on.';

-- org_settings is granted column by column, so a new column is unreadable
-- until it is named here. verify_columns enforces that; this is the fifth
-- time it has been the thing that catches it.
grant select (require_forms_to_submit) on public.org_settings to authenticated;

-- ── One forms test, shared ──

/**
 * The USOR forms this authorization still owes, or null when it owes none.
 *
 * A form counts when it is in `forms` and past Draft, or when a signed scan
 * is attached to this authorization. The paper route is how the practice
 * actually works today; the first is what §13.10 will produce.
 *
 * A coaching month asks for its own monthly forms. Anything else asks on the
 * authorization itself.
 */
create or replace function public.authorization_missing_forms(p_auth uuid)
returns text language sql stable security definer set search_path = public as $$
  select string_agg(t.usor, ' + ' order by t.sort_order)
    from public.authorizations a
    join public.form_templates t
      on t.required_for_billing and a.service_type = any (t.services)
   where a.id = p_auth
     and not exists (
       select 1 from public.forms f
        where f.auth_id = a.id and f.template_id = t.id and f.status <> 'Draft')
     and not exists (
       select 1 from public.attachments x
        where x.auth_id = a.id and x.category = 'Signed USOR form');
$$;

comment on function public.authorization_missing_forms is
  'The USOR forms an authorization still owes (§12.3). One test, read by both the checklist and the submit trigger, so the screen cannot promise what the database refuses.';

revoke all on function public.authorization_missing_forms(uuid) from anon, authenticated;
grant execute on function public.authorization_missing_forms(uuid) to authenticated;

-- ── The trigger, with the forms block put behind the setting ──
-- Re-emitted whole rather than spliced: this is 0156's function and the only
-- change is the forms section, which now asks the setting and the shared
-- test.

create or replace function public.authorization_transition()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_staff   uuid := public.current_staff_id();
  v_name    text;
  v_legal   boolean;
  v_missing text;
begin
  if tg_op = 'UPDATE' and new.status is distinct from old.status then
    -- Forward, or Closed, or the two ways reality goes backwards.
    v_legal := case
      when new.status = 'Closed' then true
      when old.status = 'Authorized' and new.status = 'Due' then true
      when old.status = 'Due' and new.status = 'Submitted' then true
      when old.status = 'Submitted' and new.status = 'Paid' then true
      -- Returned for correction: the submission did not stand.
      when old.status = 'Submitted' and new.status = 'Due' then true
      -- A payment undone, which the ledger reverses off this very move.
      when old.status = 'Paid' and new.status = 'Submitted' then true
      -- Reopened from Closed, which is Admin's doing and recorded below.
      when old.status = 'Closed' then true
      -- Due back to Authorized: somebody marked it due too early.
      when old.status = 'Due' and new.status = 'Authorized' then true
      else false
    end;

    if not v_legal then
      raise exception 'An authorization does not go from % to %', old.status, new.status
        using hint = 'Authorized, Due, Submitted, Paid, and Closed from any of them.',
              errcode = 'check_violation';
    end if;

    -- Reopening a closed authorization is Admin's.
    if old.status = 'Closed' and public.current_staff_role() is distinct from 'Admin' then
      raise exception 'Only an Admin reopens a closed authorization'
        using errcode = 'check_violation';
    end if;

    /**
     * What stops a submission, and what only warns (§4, owner 7 Oct).
     *
     * Hard: the work has to have happened inside the authorization's own
     * period. That is the rule USOR actually enforces, and billing work
     * done outside the authorized dates is the mistake that gets a whole
     * submission returned.
     *
     * Hard: more than the grace past the end date. Ninety days by default,
     * and the owner's to change.
     *
     * Warning only: past the end date but inside the grace, and a missing
     * end date. Both go on the record and the worklist; neither stands in
     * front of the person billing. A wall built on inherited data stops the
     * close over something nobody at the practice did.
     */
    if new.status = 'Submitted' then
      if new.start_date is not null and new.service_start is not null
         and new.service_start < new.start_date then
        raise exception 'The work started % and the authorization starts %',
          new.service_start, new.start_date
          using hint = 'Service dates have to sit inside the authorized period.',
                errcode = 'check_violation';
      end if;
      if new.end_date is not null and new.service_end is not null
         and new.service_end > new.end_date then
        raise exception 'The work ran to % and the authorization ends %',
          new.service_end, new.end_date
          using hint = 'Service dates have to sit inside the authorized period.',
                errcode = 'check_violation';
      end if;
      -- A coaching month is its own service period.
      if new.period is not null and new.end_date is not null
         and new.period > date_trunc('month', new.end_date)::date then
        raise exception 'That month is after the authorization ends on %', new.end_date
          using errcode = 'check_violation';
      end if;

      /**
       * The USOR forms, refused only if the practice has asked for that.
       *
       * See this migration's header. The test is real and it is on the
       * checklist either way; the block waits for the forms to live in the
       * system. Both sides read authorization_missing_forms().
       */
      if (select require_forms_to_submit from public.org_settings where id) then
        v_missing := public.authorization_missing_forms(new.id);
        if v_missing is not null then
          raise exception 'Not ready to send: % still outstanding for %',
            v_missing, coalesce(nullif(new.number, ''), new.service_type)
            using hint = 'Finish and sign the USOR forms, then submit.',
                  errcode = 'check_violation';
        end if;
      end if;

      if public.authorization_blocked_from(new.stale_date) is not null
         and public.authorization_blocked_from(new.stale_date) < public.practice_today() then
        raise exception 'That authorization ended % and is more than % days past it',
          new.stale_date,
          (select stale_grace_days from public.org_settings where id)
          using hint = 'Enter the new authorization, or move the end date and say why.',
                errcode = 'check_violation';
      end if;
    end if;

    -- The stamps the flow is defined by, so no screen has to remember them.
    if new.status = 'Submitted' and new.submitted_on is null then
      new.submitted_on := public.practice_today();
    end if;
    if new.status = 'Submitted' then
      new.submitted_by := coalesce(new.submitted_by, v_staff);
      -- §6: fourteen days, then it is chased.
      new.followup_due := coalesce(new.followup_due, public.practice_today() + 14);
    end if;
    if new.status = 'Paid' then
      new.paid_on := coalesce(new.paid_on, public.practice_today());
      new.followup_due := null;
    end if;
    if new.status = 'Closed' then
      new.closed_at := coalesce(new.closed_at, now());
      new.closed_by := coalesce(new.closed_by, v_staff);
      new.followup_due := null;
    end if;

    select name into v_name from public.staff where id = v_staff;
    insert into public.authorization_events (auth_id, staff_id, staff_name, was, became, note)
    values (new.id, v_staff, v_name, old.status, new.status,
            case when new.status = 'Closed' then new.closed_reason
                 when new.status = 'Paid' then nullif(new.warrant, '')
                 else nullif(new.correction_note, '') end);
  end if;

  /**
   * Changing the stale date is a decision, and decisions are written down.
   *
   * §2: "yes, with logged reason". The reason is required at the moment the
   * date moves, not asked for afterwards, because afterwards nobody
   * remembers and the field stays empty forever.
   */
  if tg_op = 'UPDATE' and new.stale_date is distinct from old.stale_date then
    if coalesce(btrim(new.stale_reason), '') = '' then
      raise exception 'Moving the stale date needs a reason'
        using hint = 'Somebody will ask why this was billed after it expired.',
              errcode = 'check_violation';
    end if;
    new.stale_changed_by := coalesce(v_staff, new.stale_changed_by);
    new.stale_changed_at := now();
    select name into v_name from public.staff where id = v_staff;
    insert into public.authorization_events (auth_id, staff_id, staff_name, was, became, note)
    values (new.id, v_staff, v_name, 'stale ' || coalesce(old.stale_date::text, 'none'),
            'stale ' || coalesce(new.stale_date::text, 'none'), new.stale_reason);
  end if;

  return new;
end;
$$;

-- ── The checklist ──

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
  line := 'Service finished';
  if coalesce(rule.ready_rule, '') = 'weeks after first work day' then
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
  -- It is an attachment filed under 'Authorization'. The old checklist read a
  -- column nothing ever wrote, so this line was red for everybody.
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

  -- 6. The work inside those dates. This one refuses (§4, owner 7 Oct), and
  -- it is the same three tests the trigger raises on, in the same order.
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

  -- 6b. Her §4 rule, kept from the old checklist: service dates identical to
  -- the authorization's are the classic copied-across mistake. Shown, never
  -- a block - sometimes the work really did run the whole period.
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

  -- 7. Hours within what was authorized. The parent holds them (§5), and the
  -- hours are summed across the parent and every month under it.
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

  -- 8. The USOR forms the service requires. Blocking only if the practice
  -- has turned that on - see this migration's header.
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

  -- 11. Where it is going. The office's address, or the one on the record.
  select o.billing_email into v_recip
    from public.billing_offices o where o.id = cl.billing_office_id;
  line := 'Billing recipient';
  -- coalesced to false deliberately: with no address anywhere, `like` returns
  -- null, and a null here reads as neither ticked nor crossed on the screen
  -- while slipping past `not passed` in the two helpers below as though it had
  -- passed. Two of the twenty-two live rows do exactly that.
  passed := coalesce(coalesce(v_recip, nullif(a.recipient, '')) like '%@%', false);
  detail := coalesce(v_recip, nullif(a.recipient, ''), 'no billing office on the client');
  blocking := false;
  return next;
end;
$$;

comment on function public.authorization_gate is
  'The submission checklist, every line of it ticked by the database (§12.3). `blocking` marks the lines that actually refuse a submission, so a screen can tell "not tidy yet" from "cannot".';

revoke all on function public.authorization_gate(uuid) from anon, authenticated;
grant execute on function public.authorization_gate(uuid) to authenticated;

/** Green: everything the checklist can check, checked. */
create or replace function public.authorization_gate_met(p_auth uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select not exists (
    select 1 from public.authorization_gate(p_auth) g where not coalesce(g.passed, false));
$$;

/** Nothing on the checklist would refuse it, even if something is untidy. */
create or replace function public.authorization_can_submit(p_auth uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select not exists (
    select 1 from public.authorization_gate(p_auth) g
     where g.blocking and not coalesce(g.passed, false));
$$;

comment on function public.authorization_gate_met is
  'Every line of the checklist passes (§12.3).';
comment on function public.authorization_can_submit is
  'Nothing on the checklist would refuse this submission. Narrower than the whole checklist being green: a missing signed authorization is untidy, work outside the authorized period is refused.';

revoke all on function public.authorization_gate_met(uuid) from anon, authenticated;
revoke all on function public.authorization_can_submit(uuid) from anon, authenticated;
grant execute on function public.authorization_gate_met(uuid) to authenticated;
grant execute on function public.authorization_can_submit(uuid) to authenticated;

-- The old checklist read the billing item. §10 deletes the table; the
-- function goes now, because a second checklist that disagrees with this one
-- is exactly what §11 is about.
drop function if exists public.billing_item_gate(uuid);

-- check_invoice_forms and its trigger stay where they are. They guard a table
-- §10 deletes outright, and they go with it; dropping the guard first would
-- leave the invoice briefly less protected than it is today for no gain.
