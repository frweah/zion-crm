-- Zion Vocational Rehab CRM — money before the paperwork, and a close undone
--
-- Parts 3a and 3b of the owner's list of 3 November 2026.
--
-- 3a. A payment may be recorded against an authorization that is still only
-- Authorized. The status machine has allowed Authorized straight to Paid
-- since 14 October - "money that already came in is a fact, and a record that
-- refuses to hold a fact is the bug" - but record_payment did not, so the
-- person holding the remittance had to move the status by hand first. The day
-- the money came is written as the submission date, because the ledger and
-- the chasing rules count from the day a claim went out and that is the best
-- evidence there is of it. It does not pass through Submitted on the way:
-- submitting runs the gate on service dates and USOR forms, and putting that
-- in front of money already received is the thing the October ruling exists
-- to prevent.
--
-- 3b. A closed authorization can be reopened, with a reason, and the
-- correction log says who and why. It was Admin's alone and is now Billing's
-- too, because the person who closes one in error is nearly always the person
-- billing it.
--
-- Both of those write to the correction log, which needed a field it did not
-- have: status. Added as a field that needs no reason, which in that log's
-- rules means an ordinary step through the flow is not recorded and a change
-- somebody gave a reason for is. So the log stays the four rows somebody
-- opened it to find rather than every date the flow stamped - and a reopen,
-- and a payment that arrived before the paperwork, are both in it.
--
-- All three replaced from the definitions the database had rather than from
-- the migrations that last defined them.

begin;

-- The log's own list of the fields it will hold, which had no Status in it.
-- The labels are the ones the trigger writes, so the two lists have to agree
-- or the log refuses the row - and refuses the move it came with.
alter table public.authorization_corrections drop constraint if exists authorization_corrections_field_check;
alter table public.authorization_corrections add constraint authorization_corrections_field_check
  check (field = any (array[
    'Service', 'Client', 'Number', 'Document', 'Funding source', 'Authorized hours',
    'Rate type', 'Rate', 'Amount paid', 'Starts', 'Ends', 'Received', 'Bill by',
    'Paid on', 'Warrant', 'Recipient', 'Forms required', 'Closed reason', 'Note',
    'Status']));

CREATE OR REPLACE FUNCTION public.authorization_correction_log()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  -- field, the name a person reads, whether a change to it needs a reason
  k_fields constant text[][] := array[
    ['number',         'Number',          'yes'],
    ['service_type',   'Service',         'no' ],
    ['funding_source', 'Funding source',  'no' ],
    ['total_hours',    'Authorized hours','yes'],
    ['rate_type',      'Rate type',       'yes'],
    ['rate',           'Rate',            'yes'],
    -- 'no' since 0292: paid_amount is derived from the payment rows and is not
    -- a field anybody edits any more. It is still logged - a total changing is
    -- worth seeing - but demanding a reason for it would mean demanding one
    -- from the trigger that recomputes it, which has nothing to say beyond
    -- "the payments changed". The reason now belongs on the payment: see
    -- remove_payment, which writes one.
    ['paid_amount',    'Amount paid',     'no' ],
    ['start_date',     'Starts',          'no' ],
    ['end_date',       'Ends',            'no' ],
    ['received_on',    'Received',        'no' ],
    ['bill_by',        'Bill by',         'no' ],
    -- Likewise: no payments, no paid date, decided by the same trigger.
    ['paid_on',        'Paid on',         'no' ],
    ['warrant',        'Warrant',         'no' ],
    ['recipient',      'Recipient',       'no' ],
    ['requires_forms', 'Forms required',  'no' ],
    ['closed_reason',  'Closed reason',   'no' ],
    -- Status, added with the reopen (0315). 'no' means an ordinary step
    -- through the flow is not logged - only a change somebody gave a reason
    -- for, which is what a reopen and a payment on an unsubmitted
    -- authorization both do.
    ['status',         'Status',          'no' ],
    ['note',           'Note',            'no' ]
  ];
  v_old    jsonb := to_jsonb(old);
  v_new    jsonb := to_jsonb(new);
  v_reason text := coalesce(btrim(nullif(current_setting('zion.correction_reason', true), '')), '');
  v_staff  uuid := public.current_staff_id();
  v_name   text;
  v_col    text;
  v_label  text;
  v_needs  boolean;
  v_was    text;
  v_now    text;
  v_rows   jsonb := '[]'::jsonb;
  n        integer;
begin
  for n in 1 .. array_length(k_fields, 1) loop
    v_col   := k_fields[n][1];
    v_label := k_fields[n][2];
    v_needs := k_fields[n][3] = 'yes';

    if (v_old -> v_col) is distinct from (v_new -> v_col) then
      v_was := coalesce(v_old ->> v_col, '');
      v_now := coalesce(v_new ->> v_col, '');

      /**
       * A reason for a correction, not for a first entry.
       *
       * Filling in a number that was blank, or an amount paid that was null,
       * is recording what the paperwork says - there is nothing to explain.
       * Changing a number that was already there is a correction, and
       * somebody will ask which of the two was right.
       *
       * This distinction is load-bearing: warrant reconciliation writes
       * paid_amount where there was none, and requiring a reason for that
       * would have stopped every payment the warrant reader records.
       */
      if v_needs and v_was <> '' and v_reason = '' then
        raise exception 'Changing % from % to % needs a reason',
          lower(v_label), v_was, coalesce(nullif(v_now, ''), 'nothing')
          using hint = 'Somebody will ask which of the two was right.',
                errcode = 'check_violation';
      end if;

      /**
       * And it is logged when it is a correction.
       *
       * Which is: a change to one of the fields somebody will be asked
       * about, where there was already a value - or any change somebody
       * gave a reason for, because a reason means they meant it to be read.
       *
       * Everything else is left to the record itself. A correction log that
       * also holds every date the flow stamped buries the four rows somebody
       * opened it to find, and - since the table requires a reason and those
       * writes have none - could not hold them anyway.
       */
      if (v_needs and v_was <> '') or v_reason <> '' then
        v_rows := v_rows || jsonb_build_object('field', v_label, 'was', v_was, 'new', v_now);
      end if;
    end if;
  end loop;

  if v_rows = '[]'::jsonb then
    return null;
  end if;

  select name into v_name from public.staff where id = v_staff;

  insert into public.authorization_corrections
    (auth_id, auth_number, field, was_value, new_value, reason, staff_id, staff_name)
  select new.id, old.number, r ->> 'field', r ->> 'was', r ->> 'new',
         v_reason, v_staff, coalesce(v_name, 'the system')
    from jsonb_array_elements(v_rows) as r;

  return null;
end;
$function$;

CREATE OR REPLACE FUNCTION public.authorization_transition()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
      /**
       * Paid without a submission of ours (owner, 14 Oct 2026).
       *
       * Money arrived for something the practice never formally submitted
       * through this system - the backlog, and every item billed before the
       * CRM existed. Refusing this is what made a queue of settled work
       * unclearable, and stepping it through Submitted to get around the
       * refusal would have meant lying about a packet going out.
       */
      when old.status in ('Due', 'Authorized') and new.status = 'Paid' then true
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

    /**
     * Reopening a closed authorization is Billing's as well as Admin's
     * (owner, 3 November 2026, part 3b).
     *
     * It was Admin's alone, and the person who closes an authorization in
     * error is almost always the person billing it. billing_hands() is the
     * same test record_payment and the corrections use, so "who may touch the
     * money" has one answer rather than three.
     */
    if old.status = 'Closed' and not public.billing_hands() then
      raise exception 'Reopening a closed authorization is Billing''s, or an Admin''s.'
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
     *
     * None of this guards a payment being recorded. A packet that is going
     * out has to be right; money that already came in is a fact, and a
     * record that refuses to hold a fact is the bug.
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
       * The test is real and it is on the checklist either way; the block
       * waits for the forms to live in the system. Both sides read
       * authorization_missing_forms().
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
$function$;

CREATE OR REPLACE FUNCTION public.record_payment(p_auth uuid, p_received date DEFAULT NULL::date, p_amount numeric DEFAULT NULL::numeric, p_warrant text DEFAULT NULL::text, p_voucher text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_auth    public.authorizations%rowtype;
  v_amount  numeric;
  v_when    date := coalesce(p_received, public.practice_today());
  v_warrant text := coalesce(btrim(p_warrant), '');
  v_staff   uuid := public.current_staff_id();
  v_name    text;
  v_pay     uuid;
begin
  if not public.billing_hands() then
    raise exception 'Recording a payment is Billing''s, or an Admin''s.'
      using errcode = 'insufficient_privilege';
  end if;

  select * into v_auth from public.authorizations where id = p_auth for update;
  if not found then
    raise exception 'That authorization does not exist.' using errcode = 'no_data_found';
  end if;

  /**
   * Submitted, Due, or Authorized (owner, 3 November 2026, part 3a).
   *
   * Money arrives for work nobody got round to marking as sent. Refusing it
   * meant the person with the remittance in their hand had to move the status
   * by hand first and then record the payment, which is two acts to record
   * one fact - and the status machine has allowed Authorized straight to Paid
   * since 14 October for exactly this reason.
   *
   * What it does not do is step through Submitted on the way. Submitting runs
   * the submission gate - service dates inside the authorized period, the
   * USOR forms where the practice has asked for that - and putting that gate
   * in front of money that has already arrived is the bug the 14 October
   * ruling exists to prevent. Instead the day the money came is written as
   * the submission date, with the reason in the correction log, so the ledger
   * and the chasing rules have a date to count from and the record says where
   * it came from.
   */
  if v_auth.status not in ('Submitted', 'Due', 'Authorized') then
    raise exception 'That authorization is %, and a payment is recorded against one that is Authorized, Due or Submitted.',
      lower(v_auth.status)
      using hint = 'Reopen it if it was closed, and the record says who did.',
            errcode = 'check_violation';
  end if;

  -- A coaching parent is never paid; its months are.
  if exists (select 1 from public.authorizations c where c.parent_id = p_auth) then
    raise exception 'That is the coaching authorization itself. Its months are what get paid.'
      using errcode = 'check_violation';
  end if;

  if v_when > public.practice_today() then
    raise exception 'A payment cannot have arrived on %, which has not happened yet.', v_when
      using errcode = 'invalid_parameter_value';
  end if;

  v_amount := coalesce(nullif(p_amount, 0), public.authorization_amount(p_auth));
  if coalesce(v_amount, 0) <= 0 then
    raise exception '% comes to nothing, so there is no amount to record.',
      coalesce(nullif(v_auth.number, ''), v_auth.service_type)
      using hint = 'Type the amount received, or put the rate and hours on the record first.',
            errcode = 'invalid_parameter_value';
  end if;

  select name into v_name from public.staff where id = v_staff;

  insert into public.payments
    (auth_id, amount, warrant_no, warrant_date, voucher, source, recorded_by, recorded_by_name)
  values
    (p_auth, v_amount, v_warrant, v_when, coalesce(btrim(p_voucher), ''), 'By hand',
     v_staff, coalesce(v_name, ''))
  returning id into v_pay;

  /**
   * And the one authorization moves. Nothing else: not the client, not its
   * other authorizations, not the coaching parent. The where clause is the
   * whole guarantee and it is one id.
   *
   * The warrant is only written when one was given - an empty warrant number
   * overwriting one already on the record would lose it.
   */
  -- Submitted on payment, where nobody had marked it sent. Written before
  -- the move to Paid so the log reads in the order it happened, and with the
  -- reason set because the status is one of the logged fields now.
  if v_auth.status = 'Authorized' and v_auth.submitted_on is null then
    perform set_config('zion.correction_reason',
      'Submitted on payment: the money arrived before anybody marked the packet sent.', true);
    update public.authorizations
       set submitted_on = v_when,
           submitted_by = coalesce(submitted_by, v_staff)
     where id = p_auth;
    perform set_config('zion.correction_reason', '', true);
  end if;

  perform set_config('zion.correction_reason',
    case when v_auth.status = 'Authorized'
         then 'Submitted on payment: the money arrived before anybody marked the packet sent.'
         else '' end, true);
  update public.authorizations
     set status      = 'Paid',
         paid_on     = v_when,
         paid_amount = v_amount,
         warrant     = case when v_warrant <> '' then v_warrant else warrant end
   where id = p_auth;
  perform set_config('zion.correction_reason', '', true);

  return v_pay;
end;
$function$;

-- ── and the close undone ────────────────────────
--
-- Back to Authorized, which is where it would have been had nobody closed it,
-- and the closed reason comes off because it is no longer true. Not to Due or
-- Submitted: those say something about a packet, and reopening says only that
-- this is live again.
create or replace function public.reopen_authorization(p_auth uuid, p_reason text)
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_auth public.authorizations%rowtype;
begin
  if not public.billing_hands() then
    raise exception 'Reopening a closed authorization is Billing''s, or an Admin''s.'
      using errcode = 'insufficient_privilege';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'Say why it is being reopened.' using errcode = 'check_violation';
  end if;

  select * into v_auth from public.authorizations where id = p_auth for update;
  if not found then
    raise exception 'That authorization does not exist.' using errcode = 'no_data_found';
  end if;
  if v_auth.status <> 'Closed' then
    raise exception 'That authorization is %, and it is a closed one that gets reopened.',
      lower(v_auth.status) using errcode = 'check_violation';
  end if;

  -- The reason the log reads, set for this statement only.
  perform set_config('zion.correction_reason', btrim(p_reason), true);
  update public.authorizations
     set status = 'Authorized', closed_reason = ''
   where id = p_auth;
  perform set_config('zion.correction_reason', '', true);

  return 'Reopened';
end $$;

comment on function public.reopen_authorization is
  'Puts a closed authorization back to Authorized, with a reason, which the '
  'correction log records against the status and the closed reason.';

revoke all on function public.reopen_authorization(uuid, text) from public, anon, authenticated;
grant execute on function public.reopen_authorization(uuid, text) to authenticated;

commit;
