-- Zion Vocational Rehab CRM — 0255 moving a payment between months
--
-- A payment's date decides which month's income it is. Correcting one -
-- because the warrant stub says the 29th and somebody typed the 2nd - moves
-- money from one month to another in Admin → Money, and in a report the
-- practice may already have sent somebody (owner, 26 Oct 2026).
--
-- So it is a correction like any other, and it asks for a reason. The
-- correction log already listed `paid_on` among the fields it records, but
-- marked `no` against "needs a reason" - alongside the start date and the
-- note, which move nothing. `paid_amount` was already `yes`; the date it
-- landed on is worth exactly as much.
--
-- `correct_payment_date` is the one way to do it. It could be an ordinary
-- update - the trigger would log it either way - but then the reason would be
-- something each caller remembered to set, and the screen that forgot would
-- get a refusal from a trigger rather than a field to fill in.
--
-- The trigger below is the live definition with one word changed.

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
    ['paid_amount',    'Amount paid',     'yes'],
    ['start_date',     'Starts',          'no' ],
    ['end_date',       'Ends',            'no' ],
    ['received_on',    'Received',        'no' ],
    ['bill_by',        'Bill by',         'no' ],
    ['paid_on',        'Paid on',         'yes'],
    ['warrant',        'Warrant',         'no' ],
    ['recipient',      'Recipient',       'no' ],
    ['requires_forms', 'Forms required',  'no' ],
    ['closed_reason',  'Closed reason',   'no' ],
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

/**
 * Put a payment on the day it actually arrived.
 *
 * Only on something already paid: a date on an authorization that has not
 * been paid is not a correction, it is a payment, and that is
 * `record_payment`'s job.
 */
create or replace function public.correct_payment_date(
  p_auth   uuid,
  p_on     date,
  p_reason text
)
returns date
language plpgsql security definer set search_path = public as $$
declare
  v_auth public.authorizations%rowtype;
begin
  if not public.billing_hands() then
    raise exception 'Correcting a payment is Billing''s, or an Admin''s.'
      using errcode = 'insufficient_privilege';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'Say why the payment date is changing.' using errcode = 'check_violation';
  end if;
  if p_on is null then
    raise exception 'Give the day the payment was received.' using errcode = 'check_violation';
  end if;
  if p_on > public.practice_today() then
    raise exception 'A payment cannot have been received in the future.' using errcode = 'check_violation';
  end if;

  select * into v_auth from public.authorizations where id = p_auth for update;
  if not found then
    raise exception 'That authorization does not exist.' using errcode = 'no_data_found';
  end if;
  if v_auth.status <> 'Paid' then
    raise exception 'That authorization is %, and a payment date is corrected on one that is paid.',
      lower(v_auth.status) using errcode = 'check_violation';
  end if;
  if v_auth.paid_on is not distinct from p_on then
    raise exception 'It is already dated %.', to_char(p_on, 'FMMon FMDD, YYYY')
      using errcode = 'check_violation';
  end if;

  -- The reason the log reads. Set for this statement only, so it cannot leak
  -- into anything else this transaction goes on to do.
  perform set_config('zion.correction_reason', btrim(p_reason), true);
  update public.authorizations set paid_on = p_on where id = p_auth;
  perform set_config('zion.correction_reason', '', true);

  return p_on;
end;
$$;

comment on function public.correct_payment_date is
  'Moves a payment to the day it arrived, with a reason, which moves its income to that month (0255).';

revoke all on function public.correct_payment_date(uuid, date, text) from anon, authenticated;
grant execute on function public.correct_payment_date(uuid, date, text) to authenticated;
