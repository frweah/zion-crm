-- A total is the sum of its payments, and a second warrant is not a duplicate
--
-- Four authorizations disagreed with their own payment rows, and the two
-- causes are in this file.
--
-- **`paid_amount` was a stored column.** Anything that could write to
-- `authorizations` could set it, and nothing checked it against the `payments`
-- rows it is supposed to total. So a figure typed over the top was the only
-- repair available when a payment went in twice or landed on the wrong
-- authorization, and four of them had been typed: $900 with no payment rows
-- behind it at all, $585 where the payments came to $1,170, and so on. It is
-- derived now - the sum, always, maintained by the payments themselves - so
-- this class of mismatch cannot recur.
--
-- **The auto-match refused a second warrant.** An authorization already Paid
-- could only be claimed by a line from the same warrant for the same amount,
-- so a genuine second payment on a *different* warrant was refused with
-- "this line does not match that payment", and somebody had to enter it by
-- hand - which is how nine payments were hand-entered on 3 November, and how
-- hand entry came to put money on the wrong authorization.
--
-- Two payments from two warrants is an ordinary thing. What is not ordinary is
-- the same line recorded twice, and that is now the only thing refused: a
-- payment for this authorization, from this warrant, for this amount, that
-- another line has already claimed.
--
-- Warrant numbers are compared with the F stripped. The practice's own stubs
-- say "F15617525" and a number read off a remittance by hand says "15617525",
-- and those are the same warrant - which is the other half of why Margaret's
-- entry on 20 October did not match F15658189's line.

create or replace function public.same_warrant(a text, b text)
returns boolean
language sql immutable as $$
  -- The letter is a prefix on the printed stub, not part of the number.
  select nullif(upper(regexp_replace(coalesce(a, ''), '[^0-9]', '', 'g')), '')
       = nullif(upper(regexp_replace(coalesce(b, ''), '[^0-9]', '', 'g')), '')
$$;

comment on function public.same_warrant is
  'Two warrant numbers naming the same warrant, with the F prefix and any punctuation ignored.';

-- ─────────────────────────────────────────────────────────────
-- The total is the sum

create or replace function public.authorization_paid_total(p_auth uuid)
returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce(sum(amount), 0) from public.payments where auth_id = p_auth
$$;

revoke all on function public.authorization_paid_total(uuid) from anon, authenticated;

-- Checked at the end of the transaction, not overruled mid-flight.
--
-- The first attempt forced paid_amount on every write to `authorizations`, and
-- nine verify scripts said why that is wrong: recording a payment updates the
-- authorization *then* inserts the payment row, so a BEFORE trigger reading
-- the payments sees none yet, zeroes the total, nulls the paid date and the
-- "a Paid authorization has a paid date" constraint refuses the lot. It also
-- moved when the ledger postings fire, which are driven off the amount
-- changing.
--
-- Deferred instead. Within a transaction the two may disagree for as long as
-- the work takes; by the time it commits they must agree, or nothing commits.
-- That is a stronger guarantee than overruling - it cannot be worked around by
-- writing in a different order - and it leaves every existing flow alone.
create or replace function public.paid_amount_is_the_sum()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_id    uuid := coalesce(new.id, old.id);
  v_total numeric;
  v_said  numeric;
begin
  select coalesce(sum(amount), 0) into v_total from public.payments where auth_id = v_id;
  select coalesce(paid_amount, 0) into v_said from public.authorizations where id = v_id;

  -- The authorization may be gone: a deleted client takes its authorizations,
  -- and there is nothing left to be consistent about.
  if not found then
    return null;
  end if;

  if v_said <> v_total then
    raise exception 'The amount paid on % says % and its payments come to %.',
      coalesce((select nullif(number, '') from public.authorizations where id = v_id), v_id::text),
      to_char(v_said, 'FM9999999.00'), to_char(v_total, 'FM9999999.00')
      using hint = 'The total is the sum of the payment rows. Record or remove a payment rather than typing the figure.',
            errcode = 'check_violation';
  end if;
  return null;
end $$;

drop trigger if exists authorizations_paid_amount on public.authorizations;
create constraint trigger authorizations_paid_amount
  after insert or update of paid_amount on public.authorizations
  deferrable initially deferred
  for each row execute function public.paid_amount_is_the_sum();

drop trigger if exists payments_agree_with_the_total on public.payments;
create constraint trigger payments_agree_with_the_total
  after insert or update or delete on public.payments
  deferrable initially deferred
  for each row execute function public.paid_amount_is_the_sum();

-- And the total follows its payments without anybody writing it.
create or replace function public.payments_set_the_total()
returns trigger
language plpgsql security definer set search_path = public as $$
declare v_auth uuid;
begin
  foreach v_auth in array array_remove(array[
    case when tg_op <> 'DELETE' then new.auth_id end,
    case when tg_op <> 'INSERT' then old.auth_id end], null)
  loop
    update public.authorizations a
       set paid_amount = (select coalesce(sum(p.amount), 0)
                            from public.payments p where p.auth_id = v_auth)
     where a.id = v_auth
       and coalesce(a.paid_amount, 0) <> (select coalesce(sum(p.amount), 0)
                                            from public.payments p where p.auth_id = v_auth);
  end loop;
  return null;
end $$;

drop trigger if exists payments_total on public.payments;
create trigger payments_total
  after insert or update or delete on public.payments
  for each row execute function public.payments_set_the_total();

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
CREATE OR REPLACE FUNCTION public.reconcile_warrant_line(p_line uuid, p_by_hand boolean DEFAULT false, p_auth uuid DEFAULT NULL::uuid, p_amount numeric DEFAULT NULL::numeric)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
declare
  v_role    text := public.filing_caller_role();
  v_staff   uuid := public.current_staff_id();
  v_name    text;
  v_line    public.warrant_lines%rowtype;
  v_page    public.warrant_pages%rowtype;
  v_auth    public.authorizations%rowtype;
  v_amount  numeric;
  v_owed    numeric;
  v_sum     numeric;
  v_pay     uuid;
  v_months  int;
  v_target  uuid;
  v_problem text;
  v_status  text;
begin
  if coalesce(p_by_hand, false) then
    if (v_role is null or v_role not in ('Admin', 'Billing')) and not public.staff_has_area('billing', 'edit') then
      raise exception 'Only Admin and Billing record a warrant line by hand.' using errcode = 'insufficient_privilege';
    end if;
  elsif (v_role is null or v_role not in ('service_role', 'Admin', 'Billing')) and not public.staff_has_area('billing', 'edit') then
    raise exception 'Only Admin, Billing and the agent reconcile warrants.' using errcode = 'insufficient_privilege';
  end if;

  select * into v_line from public.warrant_lines where id = p_line for update;
  if not found then
    raise exception 'That warrant line does not exist.' using errcode = 'no_data_found';
  end if;
  if v_line.status <> 'Needs review' then
    return v_line.status;
  end if;

  select * into v_page from public.warrant_pages where id = v_line.page_id;
  select name into v_name from public.staff where id = v_staff;
  v_amount := coalesce(p_amount, v_line.amount);

  -- ── what the page must prove ─────────────────────────────
  if coalesce(p_by_hand, false) then
    if p_auth is null then
      raise exception 'Choose the authorization this line pays.' using errcode = 'check_violation';
    end if;
    if v_amount is null or v_amount <= 0 then
      raise exception 'Give the amount paid.' using errcode = 'check_violation';
    end if;
    if v_page.warrant_no = '' or v_page.warrant_date is null then
      raise exception 'The page has no warrant number or date read off it.' using errcode = 'check_violation';
    end if;
    select * into v_auth from public.authorizations where id = p_auth;
    if not found then
      raise exception 'That authorization does not exist.' using errcode = 'no_data_found';
    end if;
  else
    select sum(l.amount) into v_sum from public.warrant_lines l where l.page_id = v_page.id;

    if v_page.warrant_no = '' then
      v_problem := 'No warrant number was read on the page.';
    elsif v_page.warrant_date is null then
      v_problem := 'No warrant date was read on the page.';
    elsif v_page.total is null then
      v_problem := 'No page total was read, so the lines cannot be checked against it.';
    elsif v_sum is distinct from v_page.total then
      v_problem := format('The lines add up to %s and the page total is %s.', coalesce(v_sum::text, 'nothing'), v_page.total);
    elsif public.normalize_auth_number(v_line.invoice_ref) = '' then
      v_problem := 'No V-number was read before the slash.';
    elsif public.normalize_auth_number(v_line.described_ref) = '' then
      v_problem := 'The description on this line could not be read; check it against the page image.';
    -- The stub prints the suffix only before the slash: "V0000101A /
    -- 123456-D Name-V0000101-V0000101-450.00". The description's copy must be
    -- the same V-number - with the suffix, or without it - and never another.
    elsif public.normalize_auth_number(v_line.described_ref) not in (
            public.normalize_auth_number(v_line.invoice_ref),
            regexp_replace(public.normalize_auth_number(v_line.invoice_ref), '([0-9])[A-Z]$', '\1')) then
      v_problem := format('The two copies of the V-number disagree: %s and %s.', v_line.invoice_ref, v_line.described_ref);
    elsif v_amount is null or v_amount <= 0 then
      v_problem := 'No amount was read on the line.';
    end if;

    if v_problem is null then
      -- Suffix and all: V0000101 is the base authorization, V0000101A another.
      select * into v_auth from public.authorizations
       where public.normalize_auth_number(number) = public.normalize_auth_number(v_line.invoice_ref);
      if not found then
        v_problem := format('%s is not an authorization on file.', v_line.invoice_ref);
      end if;
    end if;

    /**
     * A coaching authorization is not a bill; its months are (§5).
     *
     * The stub prints one V-number, and that number is the parent's - so a
     * coaching line has to resolve to the month it paid. The month is the one
     * that was submitted and comes to what the line pays. Exactly one, or it is
     * a mismatch for somebody to look at: twelve months at the same rate can
     * easily come to the same figure, and guessing which one a warrant paid is
     * how a month ends up marked paid twice while another waits for ever.
     */
    if v_problem is null
       and exists (select 1 from public.authorizations ch where ch.parent_id = v_auth.id) then
      select count(*) into v_months
        from public.authorizations ch
       where ch.parent_id = v_auth.id
         and ch.status = 'Submitted'
         and public.authorization_amount(ch.id) = v_amount;
      select ch.id into v_target
        from public.authorizations ch
       where ch.parent_id = v_auth.id
         and ch.status = 'Submitted'
         and public.authorization_amount(ch.id) = v_amount
       order by ch.period limit 1;

      if v_months = 1 then
        select * into v_auth from public.authorizations where id = v_target;
      elsif v_months = 0 then
        -- Already paid is not a mismatch: the branches below work out whether
        -- this is the same payment seen twice.
        select count(*) into v_months
          from public.authorizations ch
         where ch.parent_id = v_auth.id
           and ch.status = 'Paid'
           and ch.paid_amount = v_amount
           and ch.warrant = v_page.warrant_no;
        select ch.id into v_target
          from public.authorizations ch
         where ch.parent_id = v_auth.id
           and ch.status = 'Paid'
           and ch.paid_amount = v_amount
           and ch.warrant = v_page.warrant_no
         order by ch.period limit 1;
        if v_months >= 1 then
          select * into v_auth from public.authorizations where id = v_target;
        else
          v_problem := format('%s has no month submitted for %s.',
                              coalesce(nullif(v_auth.number, ''), v_auth.service_type), v_amount);
        end if;
      else
        v_problem := format('%s has %s months submitted for %s, so which one this paid is not clear.',
                            coalesce(nullif(v_auth.number, ''), v_auth.service_type), v_months, v_amount);
      end if;
    end if;

    /**
     * §13.9: only an exact match pays without a click.
     *
     * The authorization has to have been submitted - a payment for work the
     * practice never billed is the thing somebody needs to look at, not
     * something to record quietly - and the amount has to be what the
     * authorization comes to. Anything else waits with the reason on it.
     *
     * An authorization already Paid is not a mismatch: it is this line seen
     * twice, or a second warrant against the same work, and the branches below
     * decide which.
     */
    if v_problem is null and v_auth.status not in ('Submitted', 'Paid') then
      v_problem := format('%s has not been submitted (it is %s), so there is nothing waiting to be paid.',
                          coalesce(nullif(v_auth.number, ''), v_auth.service_type), lower(v_auth.status));
    end if;
    if v_problem is null and v_auth.status = 'Submitted' then
      v_owed := public.authorization_amount(v_auth.id);
      if v_owed is distinct from v_amount then
        v_problem := format('The line pays %s and %s comes to %s.',
                            v_amount, coalesce(nullif(v_auth.number, ''), v_auth.service_type),
                            coalesce(v_owed::text, 'nothing'));
      end if;
    end if;

    /**
     * The only thing refused is the same line twice (0292).
     *
     * This used to refuse any line against an authorization already Paid
     * unless the payment came from the same warrant - so a genuine second
     * payment on a *different* warrant was turned away with "this line does
     * not match that payment", and somebody entered it by hand instead. That
     * is how nine payments were hand-entered on 3 November, and how hand
     * entry came to put money on the wrong authorization.
     *
     * Two payments from two warrants is an ordinary thing. The same line
     * recorded twice is not, and that is what this looks for: a payment for
     * this authorization, from this warrant, for this amount, that another
     * line has already claimed. A payment nothing has claimed is left for the
     * matching below, which is what that is for.
     */
    if v_problem is null and exists (
         select 1 from public.payments p
           join public.warrant_lines ol on ol.id = p.warrant_line_id
          where p.auth_id = v_auth.id
            and p.amount = v_amount
            and public.same_warrant(p.warrant_no, v_page.warrant_no)
            and ol.id <> v_line.id
            -- On **this page**. A line on another page with the same warrant
            -- number is the same stub scanned twice, which the matching below
            -- recognises and claims; refusing it here would turn every
            -- re-scan into a problem. Two identical lines on one page are two
            -- lines, and the second one is the duplicate.
            and ol.page_id = v_line.page_id) then
      v_problem := format('Another line on this page has already recorded %s against %s.',
                          v_amount,
                          coalesce(nullif(v_auth.number, ''), v_auth.service_type));
    end if;

    /**
     * And a line for money the authorization cannot account for still waits.
     *
     * This is the half of the old rule that was worth keeping. A second
     * warrant paying an authorization again pays it *what it comes to* - that
     * is F15658189 line 3, $585 against a $585 authorization, and it goes
     * through. A line for some other figure against an authorization already
     * settled is money nobody can place, and recording it would put it on the
     * books against work that was paid for.
     */
    if v_problem is null and v_auth.status = 'Paid'
       and public.authorization_amount(v_auth.id) > 0
       and v_amount <> public.authorization_amount(v_auth.id)
       and not exists (
         select 1 from public.payments p
          where p.auth_id = v_auth.id
            and p.amount = v_amount
            and p.warrant_line_id is null) then
      v_problem := format('%s was paid, and this line is for %s where the authorization comes to %s.',
                          coalesce(nullif(v_auth.number, ''), v_auth.service_type),
                          to_char(v_amount, 'FM9999999.00'),
                          to_char(public.authorization_amount(v_auth.id), 'FM9999999.00'));
    end if;

    if v_problem is not null then
      update public.warrant_lines set problem = v_problem, auth_id = v_auth.id where id = v_line.id;
      update public.warrant_pages set status = 'Needs review' where id = v_page.id;
      return 'Needs review';
    end if;
  end if;

  -- ── pay it ───────────────────────────────────────────────
  begin
    perform set_config('zion.reconciling', 'on', true);

    /**
     * Already recorded: same authorization, same amount, no line claiming it
     * yet, and either the same warrant number or none at all.
     *
     * The workbook rows carry their warrant number, so those match on it.
     * A payment recorded by hand from the working list (0190) may have no
     * number, because the person clearing a months-old item had the date and
     * the amount from the remittance and not the stub. When the stub is
     * scanned later it names the same authorization for the same money, and
     * that is this payment finding its number - not a second payment.
     *
     * An exact warrant match is preferred over a blank one, so a page that
     * holds both does not take the wrong row.
     */
    select p.id into v_pay
      from public.payments p
     where p.amount = v_amount
       and p.warrant_line_id is null
       and p.auth_id = v_auth.id
       and (p.warrant_no = v_page.warrant_no
            or (p.warrant_no = '' and p.source = 'By hand'))
     order by (p.warrant_no = v_page.warrant_no) desc, p.created_at
     limit 1;

    -- Or recorded from another copy of the same warrant: the backfill PDF and
    -- a later scan of the same stub. A payment already tied to a line on a
    -- different page with this warrant number is this line, seen twice. (Two
    -- identical lines on one page are two payments, and stay so.)
    if v_pay is null then
      select p.id into v_pay
        from public.payments p
        join public.warrant_lines ol on ol.id = p.warrant_line_id
        join public.warrant_pages op on op.id = ol.page_id
       where p.warrant_no = v_page.warrant_no
         and p.amount = v_amount
         and p.auth_id = v_auth.id
         and op.id <> v_page.id
         and op.warrant_no = v_page.warrant_no
         and not exists (select 1 from public.warrant_lines same
                          where same.page_id = v_page.id and same.payment_id = p.id)
       order by p.created_at
       limit 1;

      if v_pay is not null then
        v_status := case when p_by_hand then 'Resolved by hand' else 'Already recorded' end;
        update public.warrant_lines
           set status = v_status, auth_id = v_auth.id, payment_id = v_pay, amount = v_amount,
               problem = format('Already recorded from another copy of warrant %s.', v_page.warrant_no),
               decided_by = case when p_by_hand then v_staff end,
               decided_by_name = case when p_by_hand then coalesce(v_name, '') else '' end,
               decided_at = case when p_by_hand then now() end
         where id = v_line.id;
        perform set_config('zion.reconciling', '', true);
        update public.warrant_pages pg
           set status = case when exists (select 1 from public.warrant_lines l
                                           where l.page_id = pg.id and l.status = 'Needs review')
                             then 'Needs review' else 'Reconciled' end
         where pg.id = v_page.id and pg.status <> 'Not a warrant';
        return v_status;
      end if;
    end if;

    if v_pay is not null then
      update public.payments
         set warrant_line_id = v_line.id,
             voucher = case when voucher = '' then v_line.voucher else voucher end,
             warrant_date = coalesce(warrant_date, v_page.warrant_date),
             -- The number this payment was recorded without.
             warrant_no = case when warrant_no = '' then v_page.warrant_no else warrant_no end
       where id = v_pay;

      -- And the authorization carries it too, because that is where anybody
      -- looking for "which warrant paid this" looks first.
      update public.authorizations
         set warrant = v_page.warrant_no
       where id = v_auth.id and coalesce(warrant, '') = '';
      v_status := case when p_by_hand then 'Resolved by hand' else 'Already recorded' end;
      update public.warrant_lines
         set status = v_status, auth_id = v_auth.id, payment_id = v_pay, amount = v_amount,
             problem = '',
             decided_by = case when p_by_hand then v_staff end,
             decided_by_name = case when p_by_hand then coalesce(v_name, '') else '' end,
             decided_at = case when p_by_hand then now() end
       where id = v_line.id;
    else
      -- Nothing is created. The payment is recorded against the authorization,
      -- and the authorization carries the warrant that paid it.
      insert into public.payments
        (auth_id, amount, warrant_no, warrant_date, voucher, source, warrant_line_id,
         recorded_by, recorded_by_name)
      values
        (v_auth.id, v_amount, v_page.warrant_no, v_page.warrant_date, v_line.voucher,
         case when p_by_hand then 'By hand' else 'Warrant' end, v_line.id,
         v_staff, coalesce(v_name, case when p_by_hand then '' else 'Warrant reconciliation' end))
      returning id into v_pay;

      -- Submitted becomes Paid. An authorization already Paid stays as it is:
      -- its first warrant is the one that paid it, and a second payment
      -- against it is recorded above without rewriting that history.
      if v_auth.status = 'Submitted' then
        -- `paid_amount` is not set here any more (0292). It is the sum of the
        -- payment rows, and the payment this step just wrote has already put
        -- it there. Writing the line's own amount over the top was how an
        -- authorization paid by two warrants came to read as paid by one.
        update public.authorizations
           set status = 'Paid',
               paid_on = v_page.warrant_date,
               warrant = v_page.warrant_no
         where id = v_auth.id;
      end if;

      v_status := case when p_by_hand then 'Resolved by hand' else 'Reconciled' end;
      update public.warrant_lines
         set status = v_status, auth_id = v_auth.id, payment_id = v_pay,
             amount = v_amount, problem = '',
             decided_by = case when p_by_hand then v_staff end,
             decided_by_name = case when p_by_hand then coalesce(v_name, '') else '' end,
             decided_at = case when p_by_hand then now() end
       where id = v_line.id;
    end if;

    perform set_config('zion.reconciling', '', true);
  exception when others then
    -- For example a payment the authorization's own rules refuse. Nothing
    -- above is kept; the line waits with the reason.
    if coalesce(p_by_hand, false) then
      raise;
    end if;
    update public.warrant_lines set problem = sqlerrm, auth_id = v_auth.id where id = v_line.id;
    v_status := 'Needs review';
  end;

  update public.warrant_pages pg
     set status = case when exists (select 1 from public.warrant_lines l
                                     where l.page_id = pg.id and l.status = 'Needs review')
                       then 'Needs review' else 'Reconciled' end
   where pg.id = v_page.id and pg.status <> 'Not a warrant';

  return v_status;
end;
$function$;
CREATE OR REPLACE FUNCTION public.authorization_attention_for(p_auths uuid[], p_today date DEFAULT NULL::date)
 RETURNS TABLE(auth_id uuid, attention text, urgency integer, blocked boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select * from (
    with me as (select coalesce(p_today, public.practice_today()) as today),
      settings as (
        select stale_grace_days, stale_soon_days from public.org_settings where id
      ),
      r as (
        select a.id,
               a.status, a.bill_by, a.stale_date, a.submitted_on, a.followup_due,
               coalesce(p.total_hours, a.total_hours) as authorized,
               u.used,
               public.authorization_blocked_from(a.stale_date) is not null
                 and public.authorization_blocked_from(a.stale_date) < (select today from me)
                 and a.status not in ('Submitted', 'Paid') as is_blocked,
               a.stale_date is not null and a.stale_date < (select today from me)
                 and (public.authorization_blocked_from(a.stale_date) is null
                      or public.authorization_blocked_from(a.stale_date) >= (select today from me))
                 and a.status not in ('Submitted', 'Paid') as is_expired,
               a.stale_date is null and a.status not in ('Submitted', 'Paid') as no_end_date,
               a.bill_by is not null and a.bill_by < (select today from me)
                 and a.status in ('Authorized', 'Due') as is_overdue,
               a.status = 'Submitted'
                 and ((a.followup_due is not null and a.followup_due <= (select today from me))
                      or (a.submitted_on is not null
                          and (select today from me) - a.submitted_on >= 14)) as needs_chasing,
               a.stale_date is not null and a.status not in ('Submitted', 'Paid')
                 and a.stale_date >= (select today from me)
                 and a.stale_date <= (select today from me) + (select stale_soon_days from settings)
                 as stale_soon
          from public.authorizations a
          left join public.authorizations p on p.id = a.parent_id
          left join public.authorization_hours_used(p_auths) u on u.auth_id = a.id
         where a.id = any(p_auths)
      ),
      h as (
        select r.*,
               -- Paid more than the authorization allows (0292). Two genuine
               -- payments from two warrants against a $585 authorization is
               -- not a mistake the practice can fix on its own: it is a
               -- question for USOR, and until somebody asks it the figure sits
               -- on the books unexplained. Flagged rather than corrected -
               -- nothing here knows which of the two is wrong.
               public.authorization_paid_total(r.id) >
                 public.authorization_amount(r.id) + 0.005
                 and public.authorization_amount(r.id) > 0 as paid_over,
               r.authorized is not null and r.authorized - r.used <= 0
                 and r.status not in ('Paid', 'Closed') as out_of_hours,
               r.authorized is not null and r.authorized - r.used > 0
                 and r.authorized - r.used <= r.authorized * 0.1
                 and r.status not in ('Paid', 'Closed') as hours_low
          from r
      )
      select h.id,
             case
               when h.paid_over then 'Paid more than authorized - '
                 || to_char(public.authorization_paid_total(h.id), 'FM999999.00')
                 || ' against ' || to_char(public.authorization_amount(h.id), 'FM999999.00')
                 || '. Raise it with USOR.'
               when h.is_blocked then 'Cannot be submitted - ended ' || h.stale_date
                                      || ', more than ' || (select stale_grace_days from settings)
                                      || ' days ago'
               when h.out_of_hours then 'No hours left - request more before any further service'
               when h.needs_chasing then 'Submitted ' || h.submitted_on || ', no payment after 14 days'
               when h.is_overdue then 'Overdue - meant to be billed by ' || h.bill_by
               when h.hours_low then 'Under a tenth of the hours left ('
                                      || public.fmt_hours(h.authorized - h.used) || ' of '
                                      || public.fmt_hours(h.authorized) || ')'
               when h.is_expired then 'Past its end date (' || h.stale_date || ') - can still be submitted until '
                                      || public.authorization_blocked_from(h.stale_date)
               when h.stale_soon then 'Ends ' || h.stale_date
               when h.no_end_date then 'No end date on the authorization'
               when h.status = 'Due' then 'Due to be billed'
               else ''
             end,
             case
               when h.paid_over then 0
               when h.is_blocked then 0
               when h.out_of_hours then 1
               when h.needs_chasing then 2
               when h.is_overdue then 3
               when h.hours_low then 4
               when h.is_expired then 5
               when h.stale_soon then 6
               when h.no_end_date then 7
               when h.status = 'Due' then 8
               else 9
             end,
             -- The same `is_blocked` the first branch above is chosen by, said
             -- plainly so a screen never has to read the sentence to know.
             coalesce(h.is_blocked, false)
        from h
  ) as rows_for_staff
   where public.reader_may_answer();
$function$;

-- ─────────────────────────────────────────────────────────────
-- V991262A: the $900 goes back where it came from, which is nowhere
--
-- The warrant settles it. F15617525's second line reads, in the scanner's own
-- words:
--
--     600 <voucher> V1028164 /<ref> <surname>-V1028164-V1028164-2250.00 2,250.00
--
-- (the client's surname stands where <surname> is; it is not written here, and
-- no client's name belongs in this repository)
--
-- So that line is V1028164's, for $2,250 - and V1028164 already holds exactly
-- one payment of $2,250. Its money is accounted for. The $900 somebody keyed
-- onto V991262A on 26 October matches nothing on this warrant: not the line's
-- amount, not the authorization it names, and not the client - the two
-- authorizations belong to two different people.
--
-- So the $900 is taken off V991262A and **not** put on V1028164, which would
-- pay it twice. The line goes back to needing review, where a line nobody can
-- account for belongs.

do $$
declare
  v_pay uuid; v_auth uuid; v_line uuid; v_uid uuid;
begin
  select user_id into v_uid from public.staff where lower(email) = 'frweah@gmail.com';
  select id into v_auth from public.authorizations where number = 'V991262A';

  select p.id into v_pay from public.payments p
   where p.auth_id = v_auth and p.amount = 900
     and public.same_warrant(p.warrant_no, 'F15617525');

  if v_pay is null then
    raise notice 'note  V991262A has no $900 payment from F15617525 on it; nothing to take off';
  else
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims',
                       json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
    perform public.remove_payment(v_pay,
      'F15617525 reads this line as V1028164 for $2,250, and V1028164 already holds that payment. The $900 matches no line on the warrant and belongs to no authorization yet.');
    perform set_config('role', 'postgres', true);
    raise notice 'ok  the $900 is off V991262A, and F15617525 line 2 is back to needing review';
  end if;

  if (select coalesce(paid_amount, 0) from public.authorizations where id = v_auth) <> 1350 then
    raise exception 'V991262A now reads %, and its one workbook payment is 1350',
      (select paid_amount from public.authorizations where id = v_auth);
  end if;
  raise notice 'ok  V991262A reads $1,350, which is its workbook payment and nothing else';
end $$;

-- ─────────────────────────────────────────────────────────────
-- V1041336: $900 with nothing behind it
--
-- No payment rows, and no line on any warrant in the folder names it. The
-- figure was set on the authorization directly. Derived, it is zero - so the
-- authorization is not paid, and saying it is Closed would close a thing that
-- was never settled. It goes back to Due, with the reason on the correction
-- log, and onto Margaret's list to find the warrant.

do $$
declare
  v_auth uuid; v_was numeric; v_margaret uuid; v_name text; v_client uuid; v_number text;
begin
  select id, paid_amount, client_id, number into v_auth, v_was, v_client, v_number
    from public.authorizations where number = 'V1041336';
  if v_auth is null then
    raise notice 'note  V1041336 is not on file';
    return;
  end if;

  if exists (select 1 from public.payments where auth_id = v_auth) then
    raise notice 'note  V1041336 has payments on it now; left alone';
    return;
  end if;

  select intake_staff_id into v_margaret from public.org_settings limit 1;
  select name into v_name from public.staff where id = v_margaret;

  -- Through the correction log the practice already has, rather than inserted
  -- by hand: the log records whichever fields changed, and a reason given
  -- this way is the reason it records.
  perform set_config('zion.correction_reason',
    'paid_amount had no payment behind it: no payment rows, and no line on any warrant in the folder names this authorization. Reopened to Due so it is not closed as settled.',
    true);

  -- The status first, then the amount: the derivation trigger nulls paid_on
  -- when the total is zero, and a Paid row with no paid date is refused by
  -- constraint - which is the constraint doing its job.
  update public.authorizations
     set status = 'Due',
         note = trim(coalesce(note, '') || E'\n' ||
                     'Reopened 4 November 2026: the $900 recorded as paid had no payment behind it.')
   where id = v_auth;

  perform set_config('zion.correction_reason', '', true);

  if (select coalesce(paid_amount, 0) from public.authorizations where id = v_auth) <> 0 then
    raise exception 'V1041336 still reads % paid', (select paid_amount from public.authorizations where id = v_auth);
  end if;

  perform public.notify_person(
    v_margaret, 'authorization_missing',
    format('%s was recorded as paid $%s with no payment behind it. It is back to Due - find the warrant, or ask USOR.',
           v_number, to_char(coalesce(v_was, 0), 'FM9999999.00')),
    v_auth::text, '/billing/authorizations/' || v_auth::text, v_client,
    format('Find the warrant for %s, or ask USOR', v_number),
    public.practice_today(), 'bad', v_auth);

  raise notice 'ok  V1041336 is back to Due at $0, logged, and on %''s list', coalesce(v_name, 'intake');
end $$;

-- ─────────────────────────────────────────────────────────────
-- And every other total brought to its payments

do $$
declare r record; v_n integer := 0;
begin
  for r in select a.id, a.number, a.paid_amount, a.status,
                  public.authorization_paid_total(a.id) as total
             from public.authorizations a
            where coalesce(a.paid_amount, 0) <> public.authorization_paid_total(a.id)
  loop
    raise notice '  % : % becomes %', coalesce(nullif(r.number, ''), r.id::text), r.paid_amount, r.total;
    update public.authorizations set id = id where id = r.id;
    v_n := v_n + 1;
  end loop;

  if exists (
    select 1 from public.authorizations a
     where coalesce(a.paid_amount, 0) <> public.authorization_paid_total(a.id)
  ) then
    raise exception 'an authorization still disagrees with its payments';
  end if;
  raise notice 'ok  % total(s) brought to the sum of their payments; every one now agrees', v_n;
end $$;

-- ─────────────────────────────────────────────────────────────
-- Paid above what was authorized, raised with somebody
--
-- The attention label above shows wherever attention is read - the
-- authorization's own page, and any list that asks for it. It does **not**
-- reach the Billing worklist, and that is deliberate: the worklist is
-- "not Paid or Closed", which is the definition Money was just made to agree
-- with (0290), and quietly widening it to include paid authorizations would
-- put the two screens back out of step on the same day they were brought into
-- line.
--
-- So the work goes where the practice puts work: Margaret's list, with the
-- figures in the sentence, the same way V1041336 does. Raising it with USOR is
-- a conversation, not a billing step.

do $$
declare r record; v_margaret uuid; v_n integer := 0;
begin
  select intake_staff_id into v_margaret from public.org_settings limit 1;
  if v_margaret is null then
    raise notice 'note  nobody is set as intake staff, so there is nobody to tell';
    return;
  end if;

  for r in select a.id, a.client_id, coalesce(nullif(a.number, ''), a.service_type) as label,
                  public.authorization_paid_total(a.id) as paid,
                  public.authorization_amount(a.id) as allowed
             from public.authorizations a
            where public.authorization_amount(a.id) > 0
              and public.authorization_paid_total(a.id) > public.authorization_amount(a.id) + 0.005
  loop
    v_n := v_n + 1;
    perform public.notify_person(
      v_margaret, 'authorization_missing',
      format('%s has been paid $%s against $%s authorized. Two payments on two warrants, both on the record. Raise it with USOR.',
             r.label, to_char(r.paid, 'FM999999.00'), to_char(r.allowed, 'FM999999.00')),
      r.id::text || ':paid-over', '/billing/authorizations/' || r.id::text, r.client_id,
      format('Ask USOR about %s: paid $%s against $%s authorized',
             r.label, to_char(r.paid, 'FM999999.00'), to_char(r.allowed, 'FM999999.00')),
      public.practice_today(), 'bad', r.id);
    raise notice '  % : paid % against % authorized', r.label, r.paid, r.allowed;
  end loop;

  raise notice 'ok  % authorization(s) paid above what was authorized, each on the intake list', v_n;
end $$;
