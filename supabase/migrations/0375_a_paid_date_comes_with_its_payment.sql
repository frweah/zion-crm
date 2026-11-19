-- Zion Vocational Rehab CRM — 0375: a paid date comes with its payment
--
-- Owner, 19 November 2026, on the Billing fault: "One rule everywhere: typing
-- a paid date records a payment. The Edit form's Paid on box behaves exactly
-- like the board's Paid-on cell, or it comes off the Edit form; pick whichever
-- leaves one path, and say which. Filling a blank paid_on is a logged change
-- like any other."
--
-- It comes off the form. Which is to say it comes off `edit_authorization`,
-- because a rule that lives on a screen holds until somebody uses the other
-- screen.
--
-- The reasoning, since the ruling asked which and why. There is already one
-- door for each act money can take:
--
--   it arrived            → record_payment, which writes the payment row,
--                           moves the status, sets the amount and settles the
--                           invoice. add_authorization calls it for a
--                           historic payment typed in with a new record, and
--                           the board's Paid-on cell calls it too.
--   it landed in the
--   wrong month           → correct_payment_date, which is refused unless the
--                           record is Paid and a reason is given.
--   it was never ours     → remove_payment, which writes its own correction
--                           row and puts the status back.
--
-- Against that, `paid_on` and `paid_amount` on the Edit form were a second
-- way to write the same two columns, and the amount half of it could never
-- have worked: `authorizations_paid_amount` has refused any typed figure that
-- is not the sum of the payment rows since 0292, so that box could only ever
-- fail. The date half had no such guard, and on 15 November it wrote a paid
-- date onto V1045641 with no money behind it - the record said "Paid on
-- 2026-11-11" and the board said "no payment after 14 days", on the same row.
--
-- The other way round - making Save record a payment - would have left one
-- button that sometimes writes money and sometimes does not, depending on
-- which of twenty boxes somebody touched. That is two acts behind one button,
-- which is the opposite of one path.
--
-- And the logging. A paid date can now only appear because a payment arrived,
-- so `record_payment` names the payment in the correction log: the status move
-- and the day are written down with who and when, the way a corrected number
-- is. The table needs a reason for a row at all
-- (authorization_corrections_reason_check), which is why this is a sentence
-- and not a flag.

-- ── the two fields come off the Edit form ─────────────────────────────────
--
-- `create or replace`: the signature does not change, so 0190's grants stand
-- and no second overload appears.
create or replace function public.edit_authorization(
  p_auth   uuid,
  p_fields jsonb,
  p_reason text default null
)
returns table (field text, was_value text, new_value text)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  k_text   constant text[] := array['number', 'funding_source', 'rate_type', 'recipient',
                                    'requires_forms', 'note', 'warrant', 'closed_reason'];
  -- `paid_amount` was here until 0375. It is the sum of the payment rows and
  -- the table has refused any other figure since 0292, so the box offering it
  -- could only ever fail.
  k_num    constant text[] := array['total_hours', 'rate'];
  -- `submitted_on` joined the list on 17 November 2026, so the board can
  -- take the day the packet went out as a typed date. It is gated below: a
  -- submission date on an authorization with no invoice number is a claim
  -- nobody can act on.
  --
  -- `paid_on` left it on 19 November 2026. A paid date is what a payment
  -- leaves behind, not a field.
  k_date   constant text[] := array['start_date', 'end_date', 'received_on', 'bill_by',
                                    'service_start', 'service_end', 'submitted_on'];
  v_auth   public.authorizations%rowtype;
  v_before jsonb;
  v_after  jsonb;
  v_key    text;
  v_sets   text[] := '{}';
  v_svc    text;
  v_client uuid;
begin
  if not public.billing_hands() then
    raise exception 'Editing an authorization is Billing''s, or an Admin''s.'
      using errcode = 'insufficient_privilege';
  end if;

  /*
   * The money is not typed here (owner, 19 November 2026).
   *
   * Refused rather than ignored, and refused with the next move in it: a
   * caller still sending these is a screen that has not been changed, and
   * silence would leave somebody believing they had recorded a payment.
   *
   * With the preconditions rather than beside the write, so nothing has
   * happened when it raises.
   */
  if p_fields ? 'paid_on' then
    raise exception 'A paid date goes on by recording the payment - use Record a payment, or Date paid to move one already there.'
      using errcode = 'check_violation';
  end if;
  if p_fields ? 'paid_amount' then
    raise exception 'The amount paid is the sum of the payments - record or remove a payment rather than typing the figure.'
      using errcode = 'check_violation';
  end if;

  /*
   * A submission date needs an invoice number to be about.
   *
   * The board lets somebody type into Submitted on, and the rule there is the
   * rule here rather than only on the screen: the number comes off the stub
   * through `raise_invoice`, and until it does there is nothing submitted to
   * USOR for the date to describe. Said as a sentence with the next move in
   * it, because the person typing is looking at a cell that just refused.
   */
  if p_fields ? 'submitted_on'
     and nullif(btrim(coalesce(p_fields ->> 'submitted_on', '')), '') is not null
     and not exists (select 1 from public.invoices i
                      where i.auth_id = p_auth and i.number is not null) then
    raise exception 'Raise the invoice first - a submission date needs the number that went with it.'
      using errcode = 'check_violation';
  end if;

  /*
   * And the other way: a Submitted authorization keeps its date.
   *
   * `authorizations_submitted_has_a_date` already refuses this, in the words
   * the constraint was given - "new row for relation ... violates check
   * constraint". A person who has just emptied a cell on the board should be
   * told what to do instead, so the refusal is made here where there is a
   * sentence to give it.
   */
  if p_fields ? 'submitted_on'
     and nullif(btrim(coalesce(p_fields ->> 'submitted_on', '')), '') is null
     and (select a.status from public.authorizations a where a.id = p_auth) = 'Submitted' then
    raise exception 'That is Submitted, so it keeps the day it went - move the status back first.'
      using errcode = 'check_violation';
  end if;

  -- The warrant stays in the logged fields above, because a warrant change is
  -- worth a log row. Setting one is Admin's.
  if p_fields ? 'warrant' and not public.warrant_hands() then
    raise exception 'A warrant number goes on in Admin -> Warrants, not here.'
      using errcode = 'insufficient_privilege';
  end if;

  select * into v_auth from public.authorizations where id = p_auth for update;
  if not found then
    raise exception 'That authorization does not exist.' using errcode = 'no_data_found';
  end if;
  v_before := to_jsonb(v_auth);

  -- The reason goes in first, so the correction log sees it whichever field
  -- below turns out to have moved.
  perform set_config('zion.correction_reason', coalesce(btrim(p_reason), ''), true);

  -- The service and the client are the other function's, because they move
  -- the papers. Done first, and the same reason covers them.
  v_svc    := nullif(btrim(coalesce(p_fields ->> 'service_type', '')), '');
  v_client := nullif(p_fields ->> 'client_id', '')::uuid;
  if (v_svc is not null and v_svc <> v_auth.service_type)
     or (v_client is not null and v_client <> v_auth.client_id) then
    perform public.correct_authorization(p_auth, coalesce(btrim(p_reason), ''), v_svc, v_client);
    -- Re-read: the row moved, and what follows must build on that.
    perform set_config('zion.correction_reason', coalesce(btrim(p_reason), ''), true);
    select * into v_auth from public.authorizations where id = p_auth for update;
  end if;

  foreach v_key in array k_text loop
    if p_fields ? v_key then
      v_sets := v_sets || format('%I = %L', v_key, coalesce(p_fields ->> v_key, ''));
    end if;
  end loop;

  foreach v_key in array k_num loop
    if p_fields ? v_key then
      -- An empty string is "no figure", which is null for the nullable ones
      -- and refused by the table for rate. Said here rather than by a
      -- constraint violation nobody can read.
      if nullif(btrim(coalesce(p_fields ->> v_key, '')), '') is null then
        if v_key = 'rate' then
          raise exception 'A rate of nothing is a rate of zero. Type 0 if that is what it is.'
            using errcode = 'invalid_parameter_value';
        end if;
        v_sets := v_sets || format('%I = null', v_key);
      else
        if (p_fields ->> v_key) !~ '^-?\d+(\.\d+)?$' then
          raise exception '% is not a number.', p_fields ->> v_key
            using errcode = 'invalid_parameter_value';
        end if;
        v_sets := v_sets || format('%I = %L::numeric', v_key, p_fields ->> v_key);
      end if;
    end if;
  end loop;

  foreach v_key in array k_date loop
    if p_fields ? v_key then
      if nullif(btrim(coalesce(p_fields ->> v_key, '')), '') is null then
        if v_key = 'received_on' then
          raise exception 'Every authorization has a day it came in.'
            using errcode = 'invalid_parameter_value';
        end if;
        v_sets := v_sets || format('%I = null', v_key);
      else
        if (p_fields ->> v_key) !~ '^\d{4}-\d{2}-\d{2}$' then
          raise exception '"%" is not a date.', p_fields ->> v_key
            using errcode = 'invalid_parameter_value';
        end if;
        v_sets := v_sets || format('%I = %L::date', v_key, p_fields ->> v_key);
      end if;
    end if;
  end loop;

  if array_length(v_sets, 1) is not null then
    execute format('update public.authorizations set %s, updated_at = now() where id = %L',
                   array_to_string(v_sets, ', '), p_auth);
  end if;

  perform set_config('zion.correction_reason', '', true);

  select to_jsonb(a) into v_after from public.authorizations a where a.id = p_auth;

  -- What actually moved, read back off the row rather than echoed from the
  -- form: a field the database rounded, defaulted or stamped is reported as
  -- the database left it.
  return query
    select k,
           coalesce(v_before ->> k, ''),
           coalesce(v_after  ->> k, '')
      from jsonb_object_keys(v_after) as k
     where (v_before -> k) is distinct from (v_after -> k)
       and k not in ('updated_at')
     order by k;
end;
$function$;

comment on function public.edit_authorization(uuid, jsonb, text) is
  'Every field on an authorization that is a field. The money is not: a paid '
  'date and an amount paid are refused here and go through record_payment, '
  'correct_payment_date and remove_payment (0375).';

-- ── and the payment writes the date down ──────────────────────────────────
--
-- Same signature again, so 0373's grants stand.
create or replace function public.record_payment(
  p_auth     uuid,
  p_received date default null,
  p_amount   numeric default null,
  p_warrant  text default null,
  p_voucher  text default null
)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
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

  /*
   * The amount and the day are Billing's; the warrant number is not.
   *
   * Billing goes on recording a payment - what arrived, when - and the warrant
   * goes on afterwards from the stub, which is what the warrant reader has
   * always done. A payment with no warrant yet is a shape the practice already
   * holds (0311), so nothing new is needed underneath this.
   */
  if (coalesce(btrim(p_warrant), '') <> '' or coalesce(btrim(p_voucher), '') <> '')
     and not public.warrant_hands() then
    raise exception 'A warrant number goes on in Admin -> Warrants, not here.'
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

  /**
   * The paid date is a logged change like any other (owner, 19 November
   * 2026).
   *
   * Until 0375 this reason was set only when the status had been Authorized,
   * so an ordinary payment moved the status and wrote the paid date with
   * nothing in the correction log: the trigger logs a field that needs no
   * reason only when a reason was given. The payment row said who and how
   * much and the event log said the status moved, but the record's own
   * "what changed and why" was silent on the one thing it is opened for.
   *
   * Now the sentence is the payment, so the log reads as the money history:
   * what arrived and on what day here, and what was taken back and why from
   * remove_payment, which has written its own row since 0364.
   *
   * It is two rows, not three - Status and Paid on. `paid_amount` is already
   * the sum by the time this update runs, because inserting the payment above
   * fired `payments_set_the_total`, so the figure here does not change and
   * the trigger logs only what moved.
   */
  perform set_config('zion.correction_reason',
    format('%s received %s.', to_char(v_amount, 'FM9999999.00'),
           to_char(v_when, 'FMDD FMMonth YYYY')), true);
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

comment on function public.record_payment(uuid, date, numeric, text, text) is
  'Money that arrived, against one authorization: the payment row, the status, '
  'the amount, the day, and a correction-log entry naming the payment (0375). '
  'The one door a paid date comes through.';
