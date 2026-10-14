-- Zion Vocational Rehab CRM — the correction log takes every field, and every
-- row in it has a reason
--
-- 0190 opened every field on an authorization to Billing and had the database
-- write what changed. It was wrong about the table it was writing to, in two
-- ways the verification suite caught and a screen never would have:
--
--   authorization_corrections.field is a closed list - Service, Client,
--   Number, Document - because when 0177 built it those were the only things
--   that could be corrected. A correction to a rate or a paid amount violated
--   the check and raised. Only the number was exercised by the new tests, so
--   that passed; verify_client_deletion.sql is what found the rest, by
--   clearing an amount paid as part of its own setup.
--
--   authorization_corrections.reason must not be blank, and the trigger was
--   willing to write a row with no reason for a field that does not require
--   one. Which is the deeper mistake, and fixing it properly is better than
--   widening the constraint: this table is the *correction* log. A correction
--   has a reason. A change with no reason is not a correction, and does not
--   belong here.
--
-- So the rule is now exactly this, and the constraint and the trigger agree
-- on it: a change is logged when it is a correction to one of the fields
-- somebody will be asked about, or when a reason was given for it. Either way
-- there is a reason to record, which is why the non-blank constraint can stay
-- as it is.
--
-- Everything else - a first entry, a date stamped by the flow, a warrant
-- number filled in by the reader - goes on the record without a log line,
-- because the record is where it is read and authorization_events already
-- holds the moves.

-- ── the log admits the fields that can now be corrected ─────
alter table public.authorization_corrections
  drop constraint if exists authorization_corrections_field_check;
alter table public.authorization_corrections
  add constraint authorization_corrections_field_check check (field in (
    -- 0177's four. 'Document' is written by the papers screen, not by the
    -- trigger below, and stays.
    'Service', 'Client', 'Number', 'Document',
    -- and the rest of the record, now that Billing may change it
    'Funding source', 'Authorized hours', 'Rate type', 'Rate', 'Amount paid',
    'Starts', 'Ends', 'Received', 'Bill by', 'Paid on', 'Warrant',
    'Recipient', 'Forms required', 'Closed reason', 'Note'));

-- ── and a row in it always says why ─────────────────────────
create or replace function public.authorization_correction_log()
returns trigger language plpgsql security definer set search_path = public as $$
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
    ['paid_on',        'Paid on',         'no' ],
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
$$;

comment on function public.authorization_correction_log is
  'Writes corrections to an authorization into authorization_corrections, and refuses a change to the number, the hours, the rate type, the rate or the amount paid that has no reason - unless the value was empty, which is a first entry and not a correction. Only rows that have a reason are written, because that is what the log is.';

-- ─────────────────────────────────────────────────────────────
-- And the log lets go when the record it describes is gone
--
-- 0190 made the correction log append-only, which is right, and broke
-- deleting a client, which is the same mistake 0179 corrected in the
-- directory log: an append-only rule standing in front of the one deletion
-- that is sanctioned.
--
-- authorization_corrections.auth_id cascades. Deleting a client takes its
-- authorizations, and that takes their corrections - a DELETE the guard
-- refused, so delete_client could not finish. Nobody working in the app can
-- arrange for an authorization to have already vanished; only the cascade
-- sees that, exactly as client_is_gone() is only ever seen by the referential
-- action that empties a pointer (0178).
-- ─────────────────────────────────────────────────────────────
create or replace function public.authorization_is_gone(p_auth uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select p_auth is not null
     and not exists (select 1 from public.authorizations where id = p_auth)
$$;

comment on function public.authorization_is_gone is
  'True when no authorization has this id. Lets an append-only guard tell a cascade apart from somebody editing the log.';

revoke all on function public.authorization_is_gone(uuid) from anon, authenticated;

create or replace function public.authorization_corrections_append_only()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- The authorization this describes has already gone, so this row is being
  -- carried off by the cascade behind it rather than edited by anybody.
  if tg_op = 'DELETE' and public.authorization_is_gone(old.auth_id) then
    return old;
  end if;
  raise exception 'The correction log is a record; it is added to, never changed or removed.'
    using errcode = 'insufficient_privilege';
end;
$$;

comment on function public.authorization_corrections_append_only is
  'Keeps the correction log append-only, except for a row whose authorization has already been deleted - which only the cascade behind a client deletion can arrange.';
