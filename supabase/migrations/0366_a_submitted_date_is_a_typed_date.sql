-- Zion Vocational Rehab CRM — a submitted date is a typed date
--
-- The board lets Submitted on be typed into (owner, 17 November 2026), and an
-- inline edit goes through the same function the record screen uses rather
-- than a new write path. `edit_authorization` did not accept `submitted_on`:
-- it was written by the submit flow and by `record_payment`, so a typed date
-- had nowhere to go.
--
-- Three things change, and the third was nearly missed.
--
--   * The field joins `edit_authorization`'s editable dates.
--   * The gate the board shows on the cell is stated here as well, because a
--     rule that lives only on the screen is true until somebody calls the
--     function another way.
--   * The correction log learns the field. I had assumed it already knew it -
--     `authorization_corrections` carries 'Paid on' and 'Received', so
--     'Submitted on' looked like a safe bet. It is not in the constraint and
--     it is not in the trigger's list, so without this the ruling's "with its
--     correction-log entry" would have been quietly false: the date would
--     have moved and nothing would have been written down.
--
-- The definitions are restated from what the database held
-- (scripts/dump-function.mjs), not from the migrations that created them.

begin;

-- The log may hold the field before anything writes it.
alter table public.authorization_corrections
  drop constraint if exists authorization_corrections_field_check;
alter table public.authorization_corrections
  add constraint authorization_corrections_field_check check (
    field = any (array[
      'Service', 'Client', 'Number', 'Document', 'Funding source',
      'Authorized hours', 'Rate type', 'Rate', 'Amount paid', 'Starts', 'Ends',
      'Received', 'Bill by', 'Paid on', 'Submitted on', 'Warrant', 'Recipient',
      'Forms required', 'Closed reason', 'Note', 'Status', 'Service delivered'
    ])
  );

-- ── authorization_correction_log ──

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
    -- The day the packet went to USOR (17 Nov 2026). Typed on the board now,
    -- so a change to it is somebody's act and belongs in the log. 'no': the
    -- submit flow sets it without anybody writing a sentence, and demanding
    -- one from a trigger means demanding it from the flow.
    ['submitted_on',   'Submitted on',    'no' ],
    ['warrant',        'Warrant',         'no' ],
    ['recipient',      'Recipient',       'no' ],
    ['requires_forms', 'Forms required',  'no' ],
    ['closed_reason',  'Closed reason',   'no' ],
    -- Status, added with the reopen (0315). 'no' means an ordinary step
    -- through the flow is not logged - only a change somebody gave a reason
    -- for, which is what a reopen and a payment on an unsubmitted
    -- authorization both do.
    ['status',         'Status',          'no' ],
    -- The day the work was done (0325). A first entry is somebody writing
    -- down what they did; a change to a day already there is a different
    -- claim about when a service was delivered, and the bill follows from
    -- it, so somebody will ask which of the two was right.
    ['delivered_on',   'Service delivered', 'yes'],
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

-- ── edit_authorization ──

CREATE OR REPLACE FUNCTION public.edit_authorization(p_auth uuid, p_fields jsonb, p_reason text DEFAULT NULL::text)
 RETURNS TABLE(field text, was_value text, new_value text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  k_text   constant text[] := array['number', 'funding_source', 'rate_type', 'recipient',
                                    'requires_forms', 'note', 'warrant', 'closed_reason'];
  k_num    constant text[] := array['total_hours', 'rate', 'paid_amount'];
  -- `submitted_on` joined the list on 17 November 2026, so the board can
  -- take the day the packet went out as a typed date. It is gated below: a
  -- submission date on an authorization with no invoice number is a claim
  -- nobody can act on.
  k_date   constant text[] := array['start_date', 'end_date', 'received_on', 'bill_by', 'paid_on',
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

commit;
