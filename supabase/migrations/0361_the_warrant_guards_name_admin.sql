-- Zion Vocational Rehab CRM — the warrant guards name Admin
--
-- 0360 closed the columns. This closes the functions, which a column grant
-- never touched: every one of them is SECURITY DEFINER, so each was reading
-- and writing warrant data as its owner, past RLS, for whoever could call it.
--
-- Each definition here was dumped from the live database with
-- `scripts/dump-function.mjs` and had its guard replaced - not retyped from
-- the migration that last created it, because the database drifts and an
-- out-of-order re-run of a create-or-replace reverts the newer version.
--
-- ── what changes ─────────────────────────────────────────────
--
-- `add_warrant_line`, `correct_warrant_line`, `dismiss_warrant_line`,
-- `reconcile_warrant_line`, `reconcile_warrant_page`: Admin, and the reader
-- running as the service role where it already was. The billing edit grant
-- stops opening them, which is the whole ruling.
--
-- `warrants_not_accounted_for` had no role guard at all - `reader_may_answer()`
-- is "somebody is signed in". A definer function reading warrant_lines with no
-- guard is the gate standing open beside the locked door: every signed-in
-- person could ask which warrants do not add up, and get the numbers.
--
-- `record_payment`, `add_authorization`, `edit_authorization`: the amount and
-- the day stay Billing's, the warrant number does not. The owner's ruling
-- (14 November 2026): Billing goes on recording a payment with no warrant
-- field, and the warrant goes on from the stub in Admin -> Warrants, which is
-- what the warrant reader already does. Nothing new is needed underneath - a
-- payment waiting for its warrant is a shape the practice has held since 0311.
--
-- `records_request_bundle`: the bundle stops carrying the invoice's warrant and
-- voucher. One bundle, the same whoever generates it, and the client's own
-- record of being paid is complete with the day and the amount.
--
-- `post_authorization`, `post_billing_item`: the ledger stops writing the
-- warrant number into the journal memo. Nothing closed on `payments` would
-- have mattered while Books printed the number in a narration Billing reads.
-- No existing journal carries one - both triggers only ever fired where the
-- warrant was still blank - so this keeps a count at nil rather than mending
-- one.
--
-- `bank_suggestions`: the bank reconciliation hint said "Warrants paid and not
-- yet banked come to ...". The figure is an outcome Billing may see; the word
-- is not. It reads "Payments received and not yet banked" now.

begin;

-- ── add_warrant_line ──

CREATE OR REPLACE FUNCTION public.add_warrant_line(p_page uuid, p_voucher text, p_invoice_ref text, p_client_code text, p_client_name text, p_service_date date, p_amount numeric)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_page  public.warrant_pages%rowtype;
  v_staff uuid := public.current_staff_id();
  v_name  text;
  v_no    integer;
  v_line  uuid;
begin
  if not public.warrant_hands() then
    raise exception 'A warrant is read on Admin -> Warrants.'
      using errcode = 'insufficient_privilege';
  end if;

  select * into v_page from public.warrant_pages where id = p_page for update;
  if not found then
    raise exception 'That warrant page does not exist.' using errcode = 'no_data_found';
  end if;
  if v_page.status = 'Not a warrant' then
    raise exception 'That page is not a warrant stub.' using errcode = 'check_violation';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'Give the amount on the line, as the stub prints it.' using errcode = 'check_violation';
  end if;
  if coalesce(btrim(p_invoice_ref), '') = '' then
    raise exception 'Give the V-number on the line.' using errcode = 'check_violation';
  end if;

  -- A line already on the page for this authorization and this amount is the
  -- one being looked at, not a new one. Caught here rather than left to the
  -- duplicate rule further on, so the person gets a sentence about the page
  -- in front of them instead of one about payments.
  if exists (select 1 from public.warrant_lines l
              where l.page_id = p_page
                and public.normalize_auth_number(l.invoice_ref) = public.normalize_auth_number(p_invoice_ref)
                and l.amount = p_amount) then
    raise exception 'That line is already on this page.' using errcode = 'unique_violation';
  end if;

  select coalesce(max(l.line_no), 0) + 1 into v_no
    from public.warrant_lines l where l.page_id = p_page;
  select name into v_name from public.staff where id = v_staff;

  insert into public.warrant_lines
    (page_id, line_no, raw, dept, voucher, invoice_ref, described_ref,
     client_code, client_name, service_date, described_amount, amount,
     status, problem, decided_by, decided_by_name, decided_at)
  values
    (p_page, v_no,
     -- Said plainly in the column a person reads first. The OCR's own reading
     -- of the page is in warrant_pages.ocr_text and is not overwritten; this
     -- line has no reading of its own because the reader never found it.
     format('Added from the page image by %s', coalesce(v_name, 'a member of staff')),
     '', upper(btrim(coalesce(p_voucher, ''))),
     public.normalize_auth_number(p_invoice_ref),
     public.normalize_auth_number(p_invoice_ref),
     btrim(coalesce(p_client_code, '')), btrim(coalesce(p_client_name, '')),
     p_service_date, p_amount, p_amount,
     'Needs review', 'Added from the page image — not yet matched.',
     v_staff, coalesce(v_name, ''), now())
  returning id into v_line;

  update public.warrant_pages pg
     set lines_total = (select sum(l.amount) from public.warrant_lines l where l.page_id = pg.id),
         status = 'Needs review'
   where pg.id = p_page;

  return v_line;
end;
$function$;

-- ── correct_warrant_line ──

CREATE OR REPLACE FUNCTION public.correct_warrant_line(p_line uuid, p_voucher text, p_invoice_ref text, p_client_code text, p_client_name text, p_service_date date, p_amount numeric)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_line  public.warrant_lines%rowtype;
  v_staff uuid := public.current_staff_id();
  v_name  text;
begin
  if not public.warrant_hands() then
    raise exception 'A warrant is read on Admin -> Warrants.'
      using errcode = 'insufficient_privilege';
  end if;

  select * into v_line from public.warrant_lines where id = p_line for update;
  if not found then
    raise exception 'That warrant line does not exist.' using errcode = 'no_data_found';
  end if;

  -- A line that has already paid something is history. Changing the figures
  -- under a payment would leave the payment saying one thing and the line it
  -- came from saying another, and the payment is the record.
  if v_line.status <> 'Needs review' then
    raise exception 'That line is %, so its figures are part of a payment now.', lower(v_line.status)
      using errcode = 'check_violation', hint = 'Set it aside and add the line again if the reading was wrong.';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'Give the amount on the line, as the stub prints it.' using errcode = 'check_violation';
  end if;
  if coalesce(btrim(p_invoice_ref), '') = '' then
    raise exception 'Give the V-number on the line.' using errcode = 'check_violation';
  end if;

  select name into v_name from public.staff where id = v_staff;

  update public.warrant_lines
     set voucher = upper(btrim(coalesce(p_voucher, ''))),
         invoice_ref = public.normalize_auth_number(p_invoice_ref),
         described_ref = public.normalize_auth_number(p_invoice_ref),
         client_code = btrim(coalesce(p_client_code, '')),
         client_name = btrim(coalesce(p_client_name, '')),
         service_date = p_service_date,
         described_amount = p_amount,
         amount = p_amount,
         problem = format('Read from the page image by %s.', coalesce(v_name, 'a member of staff')),
         decided_by = v_staff,
         decided_by_name = coalesce(v_name, ''),
         decided_at = now()
   where id = p_line;

  update public.warrant_pages pg
     set lines_total = (select sum(l.amount) from public.warrant_lines l where l.page_id = pg.id)
   where pg.id = v_line.page_id;
end;
$function$;

-- ── dismiss_warrant_line ──

CREATE OR REPLACE FUNCTION public.dismiss_warrant_line(p_line uuid, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_line public.warrant_lines%rowtype;
begin
  if not public.warrant_hands() then
    raise exception 'A warrant is read on Admin -> Warrants.' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'Say why it is being set aside.' using errcode = 'check_violation';
  end if;
  select * into v_line from public.warrant_lines where id = p_line for update;
  if not found then
    raise exception 'That warrant line does not exist.' using errcode = 'no_data_found';
  end if;
  if v_line.status <> 'Needs review' then
    raise exception 'Only a line waiting for review can be set aside.' using errcode = 'check_violation';
  end if;

  update public.warrant_lines
     set status = 'Dismissed', problem = btrim(p_reason), decided_by = public.current_staff_id(),
         decided_by_name = coalesce((select name from public.staff where id = public.current_staff_id()), ''),
         decided_at = now()
   where id = p_line;

  update public.warrant_pages pg
     set status = case when exists (select 1 from public.warrant_lines l
                                     where l.page_id = pg.id and l.status = 'Needs review')
                       then 'Needs review' else 'Reconciled' end
   where pg.id = v_line.page_id and pg.status <> 'Not a warrant';
end;
$function$;

-- ── reconcile_warrant_line ──

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
  v_had     date;
begin
  if coalesce(p_by_hand, false) then
    if coalesce(v_role, '') <> 'Admin' then
      raise exception 'A warrant is read on Admin -> Warrants.' using errcode = 'insufficient_privilege';
    end if;
  elsif coalesce(v_role, '') not in ('service_role', 'Admin') then
    raise exception 'A warrant is reconciled by Admin, or by the reader.' using errcode = 'insufficient_privilege';
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
      -- The day the payment said it arrived, before the stub said otherwise.
      select p.warrant_date into v_had from public.payments p where p.id = v_pay;

      update public.payments
         set warrant_line_id = v_line.id,
             voucher = case when voucher = '' then v_line.voucher else voucher end,
             /**
              * The warrant says which day (0313).
              *
              * This kept the date already on the row, and the row is often
              * the day somebody sat down to enter a batch from the
              * remittance. Phase 2 corrected five payments by hand for
              * exactly that - three of them dated 26 October because that is
              * when the batch was typed - and the owner's rule is that where
              * the CRM disagrees with the warrant on the date, the warrant
              * wins, with a correction-log entry. So the stub's date is
              * written, and the entry is written below.
              */
             warrant_date = coalesce(v_page.warrant_date, warrant_date),
             -- The number this payment was recorded without.
             warrant_no = case when warrant_no = '' then v_page.warrant_no else warrant_no end
       where id = v_pay;

      /**
       * And the authorization's summary of it, which is what Money reads.
       *
       * paid_on is one of the fields the correction log asks for a reason
       * about when it already had a value, so the reason is set for this
       * statement and cleared after it. Without it the update raises, the
       * block below catches, and the line would wait for review saying
       * "Changing paid on from X to Y needs a reason" - which is how a rule
       * about writing things down turns into a line nobody can clear.
       */
      if v_had is distinct from v_page.warrant_date and v_page.warrant_date is not null then
        perform set_config('zion.correction_reason',
          format('Warrant %s is dated %s and the payment was recorded as %s.',
                 v_page.warrant_no,
                 to_char(v_page.warrant_date, 'FMMon FMDD, YYYY'),
                 coalesce(to_char(v_had, 'FMMon FMDD, YYYY'), 'no date at all')), true);
        update public.authorizations
           set paid_on = v_page.warrant_date
         where id = v_auth.id and paid_on is distinct from v_page.warrant_date;
        perform set_config('zion.correction_reason', '', true);
      end if;

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

-- ── reconcile_warrant_page ──

CREATE OR REPLACE FUNCTION public.reconcile_warrant_page(p_page uuid)
 RETURNS TABLE(reconciled integer, already_recorded integer, needs_review integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
declare
  v_role text := public.filing_caller_role();
  v_line record;
begin
  if coalesce(v_role, '') not in ('service_role', 'Admin') then
    raise exception 'A warrant is reconciled by Admin, or by the reader.' using errcode = 'insufficient_privilege';
  end if;

  update public.warrant_pages pg
     set lines_total = (select sum(l.amount) from public.warrant_lines l where l.page_id = pg.id)
   where pg.id = p_page;

  for v_line in select l.id from public.warrant_lines l
                 where l.page_id = p_page and l.status = 'Needs review' order by l.line_no loop
    perform public.reconcile_warrant_line(v_line.id);
  end loop;

  update public.warrant_pages pg
     set status = case
                    when pg.status = 'Not a warrant' then pg.status
                    when not exists (select 1 from public.warrant_lines l where l.page_id = pg.id) then 'Needs review'
                    when exists (select 1 from public.warrant_lines l where l.page_id = pg.id and l.status = 'Needs review')
                      then 'Needs review'
                    else 'Reconciled' end
   where pg.id = p_page;

  return query
    select count(*) filter (where l.status = 'Reconciled')::int,
           count(*) filter (where l.status = 'Already recorded')::int,
           count(*) filter (where l.status = 'Needs review')::int
      from public.warrant_lines l where l.page_id = p_page;
end;
$function$;

-- ── warrants_not_accounted_for ──

CREATE OR REPLACE FUNCTION public.warrants_not_accounted_for()
 RETURNS TABLE(warrant_no text, warrant_date date, total numeric, recorded numeric, gap numeric, pages integer, lines integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select * from (
    with stub as (
      -- One warrant, however many times its stub was scanned. The total is
      -- the same figure on every copy; max() picks it without caring which
      -- copy was read best.
      select p.warrant_no,
             max(p.total) as total,
             min(p.warrant_date) as warrant_date,
             count(distinct p.id)::int as pages,
             (select count(*) from public.warrant_lines l
               join public.warrant_pages q on q.id = l.page_id
              where q.warrant_no = p.warrant_no)::int as lines
        from public.warrant_pages p
       where p.warrant_no <> '' and p.total is not null and p.status <> 'Not a warrant'
       group by p.warrant_no
    ),
    money as (
      select y.warrant_no, sum(y.amount) as recorded
        from public.payments y where y.warrant_no <> '' group by y.warrant_no
    )
    select stub.warrant_no, stub.warrant_date, stub.total,
           coalesce(money.recorded, 0), stub.total - coalesce(money.recorded, 0),
           stub.pages, stub.lines
      from stub left join money on money.warrant_no = stub.warrant_no
     -- A cent, because a stub prints cents and a rate does not always divide.
     where abs(stub.total - coalesce(money.recorded, 0)) > 0.005
     order by stub.warrant_date desc, stub.warrant_no
  ) as rows_for_staff
   where public.warrant_hands();
$function$;

-- ── record_payment ──

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

-- ── add_authorization ──

CREATE OR REPLACE FUNCTION public.add_authorization(p_client uuid, p_number text, p_service_type text, p_rate_type text, p_rate numeric, p_total_hours numeric DEFAULT NULL::numeric, p_start date DEFAULT NULL::date, p_end date DEFAULT NULL::date, p_requires_forms text DEFAULT ''::text, p_funding_source text DEFAULT 'Utah VR'::text, p_note text DEFAULT NULL::text, p_received_on date DEFAULT NULL::date, p_paid_on date DEFAULT NULL::date, p_paid_amount numeric DEFAULT NULL::numeric, p_warrant text DEFAULT ''::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_id uuid;
begin
  if not (public.current_staff_role() in ('Admin', 'Billing')
          or public.staff_has_area('billing', 'edit')
          -- The intake, which runs as the service role with nobody signed in
          -- (0182). What it creates is unconfirmed; a person still confirms it.
          or coalesce(public.filing_caller_role(), '') = 'service_role') then
    raise exception 'Only Admin and Billing add authorizations.'
      using errcode = 'insufficient_privilege';
  end if;
  -- Said here as well as in `record_payment`, which this calls with the
  -- warrant: a form that offered the field would otherwise write the client
  -- and the authorization before refusing the warrant at the end.
  if coalesce(btrim(p_warrant), '') <> '' and not public.warrant_hands() then
    raise exception 'A warrant number goes on in Admin -> Warrants, not here.'
      using errcode = 'insufficient_privilege';
  end if;
  if p_client is null then
    raise exception 'Choose a client.' using errcode = 'check_violation';
  end if;

  -- Said before anything is written, because "it is already paid" and "it has
  -- no payment date" together is somebody half way through the form.
  if p_paid_on is not null and p_paid_on > public.practice_today() then
    raise exception 'A payment cannot have been received in the future.'
      using errcode = 'check_violation';
  end if;

  insert into public.authorizations
    (client_id, number, service_type, funding_source, rate_type, rate, total_hours,
     start_date, end_date, requires_forms, note, received_on)
  values
    (p_client, coalesce(p_number, ''), p_service_type,
     coalesce(nullif(p_funding_source, ''), 'Utah VR'),
     p_rate_type, p_rate,
     case when p_rate_type = 'Hourly' then p_total_hours end,
     p_start, p_end, coalesce(p_requires_forms, ''), btrim(coalesce(p_note, '')),
     p_received_on)
  returning id into v_id;

  -- ── already paid ──────────────────────────────────────────
  if p_paid_on is not null then
    -- Due first: `record_payment` records against something that is Submitted
    -- or Due, which is the rule for a payment arriving at any other time and
    -- there is no reason for this to be the exception.
    update public.authorizations set status = 'Due' where id = v_id;

    perform public.record_payment(v_id, p_paid_on, p_paid_amount, p_warrant, null);
  end if;

  return v_id;
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
  k_date   constant text[] := array['start_date', 'end_date', 'received_on', 'bill_by', 'paid_on',
                                    'service_start', 'service_end'];
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

-- ── records_request_bundle ──

CREATE OR REPLACE FUNCTION public.records_request_bundle(p_client uuid, p_purpose text DEFAULT 'Records request'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_bundle jsonb;
begin
  v_bundle := public.records_request_bundle_before_reports(p_client, p_purpose);

  return v_bundle
    || jsonb_build_object(
      /*
       * The other spellings of their own name (0303).
       *
       * A client's name as somebody else writes it is the client's data. The
       * practice holds these so a warrant or an invoice under one spelling
       * finds the record, and a records request that left them out would be
       * answered with less than the practice holds. Where each spelling was
       * seen is included, because that is the part that explains why it is
       * on file at all.
       */
      'other_spellings', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'spelling', a.name,
                 'seen_on', a.source,
                 'why', nullif(a.note, ''),
                 'added_by', nullif(a.added_by_name, ''),
                 'added_at', a.at
               ) order by a.name), '[]'::jsonb)
          from public.client_aliases a where a.client_id = p_client
      ),
      /*
       * The invoices sent about them (0306).
       *
       * A client's invoices are a record of what the practice billed the
       * state for work done with them, and theirs to see. The services on
       * each one come with it: a figure with no lines behind it is a number
       * somebody has to take on trust.
       */
      /*
       * What was noticed about them and not yet filed (0317).
       *
       * An item in somebody's "To file" inbox is not on the client's record -
       * that is the whole design, and it is why an unconfirmed appointment
       * cannot reach a report. It is still something the practice holds with
       * this client's name against it, and a records request is answered with
       * what the practice holds rather than with what it has decided to act
       * on. A discarded one is in here too: the row stays so the sweep does
       * not offer it again, and a row that stays is a row that is disclosed.
       */
      'noticed_not_filed', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'what', nullif(f.title, ''),
                 'where_from', f.source,
                 'when', f.happened_at,
                 'why_this_client', nullif(f.guess_why, ''),
                 'state', f.state,
                 'outcome', nullif(f.outcome, ''),
                 'about', f.category,
                 'what_was_written', nullif(f.note, ''),
                 'decided_by', nullif(f.decided_by_name, ''),
                 'decided_at', f.decided_at
               ) order by f.happened_at desc nulls last), '[]'::jsonb)
          from public.to_file f where f.client_id = p_client
      ),
      /*
       * The numbers the practice holds for them, and the people around them
       * (0330).
       *
       * A client's other phone numbers are the client's data, and so is the
       * fact that the practice holds their daughter-in-law's number, her
       * name, how she is related, and whether she gets the weekly update. A
       * records request is answered with what the practice holds about this
       * person, and a contact's details are held because of them.
       *
       * A contact who has come off the record is in here too. The row stays
       * so the texts they sent keep their name, and a row that stays is a row
       * that is disclosed.
       */
      'other_numbers', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'number', p.phone,
                 'what_it_is', p.label,
                 'note', nullif(p.note, ''),
                 'added_by', (select nullif(s.name, '') from public.staff s where s.id = p.added_by),
                 'added_at', p.created_at
               ) order by p.created_at), '[]'::jsonb)
          from public.client_phones p where p.client_id = p_client
      ),
      /*
       * The weekly updates drafted about them (0338).
       *
       * A text the practice wrote about this client and sent to their phone
       * is plainly theirs. So is one it drafted and decided not to send, and
       * the reason it gave - a record of what the practice was going to say
       * is as much about them as what it said.
       *
       * The facts the draft was assembled from come with it. They are the
       * answer to "where did that sentence come from", which is the question
       * somebody asks about a text months later.
       */
      /*
       * The recordings of meetings with them (0344).
       *
       * A recording of a client talking about their own life is theirs, and
       * so is a machine's transcript of it. So is one nobody confirmed: the
       * practice holds the audio and the transcript either way, and a
       * records request is answered with what the practice holds rather than
       * with what it decided to act on.
       *
       * The transcript goes in as it was read, speaker turns and all, and
       * the draft summary with it - including a draft that was never
       * confirmed, which is a thing the practice wrote about them and did
       * not use. What it became, where it was confirmed, is named by the
       * contact log entry and the note, both of which are disclosed in their
       * own sections above.
       */
      'recordings', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'recorded_on', (select a.document_date from public.attachments a
                                  where a.id = g.attachment_id),
                 'file', (select a.filename from public.attachments a where a.id = g.attachment_id),
                 'minutes', g.minutes,
                 'state', g.state,
                 'recorded_by', (select nullif(s.name, '') from public.staff s where s.id = g.staff_id),
                 'what_was_said', g.transcript,
                 'as_it_was_read', g.turns,
                 'what_was_drafted_or_confirmed', g.summary,
                 'confirmed_by', (select nullif(s.name, '') from public.staff s where s.id = g.confirmed_by),
                 'confirmed_at', g.confirmed_at,
                 'why_not_used', nullif(g.reason, ''),
                 'added_at', g.created_at
               ) order by g.created_at desc), '[]'::jsonb)
          from public.recordings g where g.client_id = p_client
      ),
      'weekly_updates', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'week_from', w.week_start,
                 'week_to', w.week_start + 6,
                 'to', case when w.contact_id is null then 'the client'
                            else (select t.name || ' (' || t.relationship || ')'
                                    from public.client_contacts t where t.id = w.contact_id) end,
                 'number', w.phone,
                 'what_it_said', w.body,
                 'what_it_was_made_from', w.facts,
                 'state', w.state,
                 'why_not_sent', nullif(w.reason, ''),
                 'drafted_at', w.drafted_at,
                 'changed_by', (select nullif(s.name, '') from public.staff s where s.id = w.edited_by),
                 'decided_by', (select nullif(s.name, '') from public.staff s where s.id = w.decided_by),
                 'sent_at', w.sent_at
               ) order by w.week_start desc), '[]'::jsonb)
          from public.weekly_updates w where w.client_id = p_client
      ),
      'contacts', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'name', t.name,
                 'relationship', t.relationship,
                 'number', t.phone,
                 'what_the_number_is', t.phone_label,
                 'email', nullif(t.email, ''),
                 'gets_the_weekly_update', t.receives_updates,
                 'may_speak_for_the_client', t.may_speak_for,
                 'on_the_record', t.active,
                 'note', nullif(t.note, ''),
                 'added_by', (select nullif(s.name, '') from public.staff s where s.id = t.added_by),
                 'added_at', t.created_at
               ) order by t.created_at), '[]'::jsonb)
          from public.client_contacts t where t.client_id = p_client
      ),
      'invoices', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'invoice', i.number,
                 'sent_on', i.submitted_on,
                 'sent_to', nullif(i.sent_to, ''),
                 'office', (select b.name from public.billing_offices b where b.id = i.office_id),
                 'sent_by', (select nullif(s.name, '') from public.staff s where s.id = i.submitted_by),
                 'authorization', (select nullif(a.number, '') from public.authorizations a where a.id = i.auth_id),
                 'claim', i.claim,
                 'amount', i.amount,
                 'status', i.status,
                 'paid_on', i.paid_on,
                 'amount_paid', i.amount_paid,
                 'note', nullif(i.note, ''),
                 'services', (
                   select coalesce(jsonb_agg(jsonb_build_object(
                            'on', l.on_date, 'what', nullif(l.description, ''),
                            'hours', l.hours, 'rate', l.rate, 'amount', l.amount
                          ) order by l.on_date), '[]'::jsonb)
                     from public.invoice_lines l where l.invoice_id = i.id)
               ) order by i.number), '[]'::jsonb)
          from public.invoices i where i.client_id = p_client
      ),
      'weekly_reports', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'week_from', w.week_start,
                 'week_to', w.week_start + 6,
                 'status', w.status,
                 'kept_by', (select nullif(s.name, '') from public.staff s where s.id = w.owner_id),
                 'confirmed_by', (select nullif(s.name, '') from public.staff s where s.id = w.confirmed_by),
                 'confirmed_at', w.confirmed_at,
                 'what_staff_wrote', nullif(w.note, ''),
                 'what_the_record_showed', w.content
               ) order by w.week_start), '[]'::jsonb)
          from public.client_weekly_reports w where w.client_id = p_client
      ),
      'reports', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'report', m.template,
                 'period', m.period,
                 'status', m.status,
                 'due_on', m.due_on,
                 'kept_by', (select nullif(s.name, '') from public.staff s where s.id = m.owner_id),
                 'signed_by', (select nullif(s.name, '') from public.staff s where s.id = m.signed_by),
                 'signed_at', m.signed_at,
                 'sent_at', m.sent_at,
                 'sent_to', nullif(m.sent_to, ''),
                 'reopened_because', nullif(m.reopen_reason, ''),
                 'what_staff_wrote', nullif(m.note, ''),
                 'what_the_record_showed', m.content,
                 'document', (select a.filename from public.attachments a
                               where a.id = m.pdf_attachment_id)
               ) order by m.period, m.template), '[]'::jsonb)
          from public.client_reports m where m.client_id = p_client
      ));
end;
$function$;

-- ── post_authorization ──

CREATE OR REPLACE FUNCTION public.post_authorization()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_amount  numeric;
  v_revenue uuid;
  v_client  public.clients;
  v_office  text;
  v_live    uuid;
  v_label   text;
begin
  if new.status = old.status then
    return new;
  end if;

  -- A coaching parent is never billed; its months are.
  if exists (select 1 from public.authorizations c where c.parent_id = new.id) then
    return new;
  end if;

  select * into v_client from public.clients where id = new.client_id;
  v_office := coalesce(
    nullif((select office from public.counselors where id = v_client.counselor_id), ''),
    v_client.referring_office, '');
  v_revenue := public.ledger_revenue_account(new.service_type);
  v_label := v_client.name || ' - ' || new.service_type
             || case when new.period is not null
                     then ', ' || to_char(new.period, 'FMMon YYYY') else '' end;

  -- ── submitted: it is owed to the practice now ──
  if new.status = 'Submitted' and old.status <> 'Submitted' then
    v_amount := public.authorization_amount(new.id);
    if v_amount > 0 and public.ledger_live_posting('Authorization', new.id, 'Submitted') is null then
      perform public.post_journal(
        coalesce(new.submitted_on, public.practice_today()),
        v_label || ' submitted',
        'Authorization', new.id,
        public.ledger_next_event('Authorization', new.id, 'Submitted'),
        jsonb_build_array(
          jsonb_build_object('account', public.ledger_account('ar'), 'debit', v_amount,
                             'client_id', new.client_id, 'service', new.service_type,
                             'counselor_id', v_client.counselor_id, 'office', v_office),
          jsonb_build_object('account', v_revenue, 'credit', v_amount,
                             'client_id', new.client_id, 'service', new.service_type,
                             'counselor_id', v_client.counselor_id, 'office', v_office)
        ),
        null, '', null, new.submitted_by,
        coalesce((select name from public.staff where id = new.submitted_by), '')
      );
    end if;
  end if;

  /**
   * ── paid without having been submitted here ──
   *
   * The receivable has to stand before it can be cleared. This is the same
   * posting as the block above, made on the way past, so a backlog item
   * cleared in one move leaves the ledger in the state the long way round
   * would have left it.
   *
   * The amount is the payment, not authorization_amount(): on these records
   * the amount is often what the warrant says and not what the record was
   * priced at, and the receivable that is about to be cleared has to be the
   * one being cleared.
   */
  if new.status = 'Paid' and old.status not in ('Paid', 'Submitted') then
    v_amount := coalesce(nullif(new.paid_amount, 0), public.authorization_amount(new.id));
    if v_amount > 0 and public.ledger_live_posting('Authorization', new.id, 'Submitted') is null then
      perform public.post_journal(
        coalesce(new.submitted_on, new.paid_on, public.practice_today()),
        v_label || ' billed',
        'Authorization', new.id,
        public.ledger_next_event('Authorization', new.id, 'Submitted'),
        jsonb_build_array(
          jsonb_build_object('account', public.ledger_account('ar'), 'debit', v_amount,
                             'client_id', new.client_id, 'service', new.service_type,
                             'counselor_id', v_client.counselor_id, 'office', v_office),
          jsonb_build_object('account', v_revenue, 'credit', v_amount,
                             'client_id', new.client_id, 'service', new.service_type,
                             'counselor_id', v_client.counselor_id, 'office', v_office)
        ),
        null, '', null, public.current_staff_id(),
        coalesce((select name from public.staff where id = public.current_staff_id()), '')
      );
    end if;
  end if;

  -- ── paid: a warrant in hand, not yet at the bank ──
  if new.status = 'Paid' and old.status <> 'Paid' then
    if coalesce(new.paid_amount, 0) > 0
       and public.ledger_live_posting('Authorization', new.id, 'Paid') is null then
      perform public.post_journal(
        coalesce(new.paid_on, public.practice_today()),
        v_label || ' paid',
        'Authorization', new.id,
        public.ledger_next_event('Authorization', new.id, 'Paid'),
        jsonb_build_array(
          jsonb_build_object('account', public.ledger_account('undeposited'), 'debit', new.paid_amount,
                             'client_id', new.client_id, 'service', new.service_type,
                             'counselor_id', v_client.counselor_id, 'office', v_office),
          jsonb_build_object('account', public.ledger_account('ar'), 'credit', new.paid_amount,
                             'client_id', new.client_id, 'service', new.service_type,
                             'counselor_id', v_client.counselor_id, 'office', v_office)
        ),
        v_revenue
      );
    end if;
  end if;

  -- ── the receivable stops standing ──
  -- Closed is here: an authorization submitted and then closed has been
  -- refused or abandoned, and what was owed is not owed any more.
  if old.status = 'Submitted' and new.status in ('Due', 'Authorized', 'Closed') then
    v_live := public.ledger_live_posting('Authorization', new.id, 'Submitted');
    if v_live is not null then
      perform public.reverse_journal(v_live, format('Went back to %s', new.status));
    end if;
  end if;

  -- ── the payment stops standing ──
  -- Closed is deliberately not here (0154): closing something that was paid
  -- does not un-pay it, and reversing would take real money off the books.
  --
  -- The receivable raised on the way to Paid comes off with it, because a
  -- payment undone on a record that was never submitted leaves nothing owed.
  if old.status = 'Paid' and new.status in ('Submitted', 'Due', 'Authorized') then
    v_live := public.ledger_live_posting('Authorization', new.id, 'Paid');
    if v_live is not null then
      perform public.reverse_journal(v_live, format('Payment undone: now %s', new.status));
    end if;
    if new.status in ('Due', 'Authorized') then
      v_live := public.ledger_live_posting('Authorization', new.id, 'Submitted');
      if v_live is not null then
        perform public.reverse_journal(v_live, format('Payment undone: now %s', new.status));
      end if;
    end if;
  end if;

  return new;
end;
$function$;

-- ── post_billing_item ──

CREATE OR REPLACE FUNCTION public.post_billing_item()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_amount    numeric;
  v_revenue   uuid;
  v_client    public.clients;
  v_office    text;
  v_live      uuid;
begin
  if new.status = old.status then
    return new;
  end if;

  select * into v_client from public.clients where id = new.client_id;
  v_office := coalesce(
    nullif((select office from public.counselors where id = v_client.counselor_id), ''),
    v_client.referring_office, '');
  v_revenue := public.ledger_revenue_account(new.service);

  -- ── submitted: it is owed to the practice now ──
  if new.status = 'Submitted' and old.status <> 'Submitted' then
    v_amount := coalesce(new.amount, round(coalesce(new.hours, 0) * coalesce(new.rate, 0), 2));
    if v_amount > 0 and public.ledger_live_posting('Billing item', new.id, 'Submitted') is null then
      perform public.post_journal(
        coalesce(new.submitted_at::date, public.practice_today()),
        format('%s - %s submitted', v_client.name, new.service),
        'Billing item', new.id,
        public.ledger_next_event('Billing item', new.id, 'Submitted'),
        jsonb_build_array(
          jsonb_build_object('account', public.ledger_account('ar'), 'debit', v_amount,
                             'client_id', new.client_id, 'service', new.service,
                             'counselor_id', v_client.counselor_id, 'office', v_office),
          jsonb_build_object('account', v_revenue, 'credit', v_amount,
                             'client_id', new.client_id, 'service', new.service,
                             'counselor_id', v_client.counselor_id, 'office', v_office,
                             'staff_id', new.assigned_staff_id)
        ),
        null, '', null, new.submitted_by,
        coalesce((select name from public.staff where id = new.submitted_by), '')
      );
    end if;
  end if;

  -- ── paid: a warrant in hand, not yet at the bank ──
  if new.status = 'Paid' and old.status <> 'Paid' then
    if coalesce(new.paid_amount, 0) > 0 and public.ledger_live_posting('Billing item', new.id, 'Paid') is null then
      perform public.post_journal(
        coalesce(new.paid_on, public.practice_today()),
        format('%s - %s paid', v_client.name, new.service),
        'Billing item', new.id,
        public.ledger_next_event('Billing item', new.id, 'Paid'),
        jsonb_build_array(
          jsonb_build_object('account', public.ledger_account('undeposited'), 'debit', new.paid_amount,
                             'client_id', new.client_id, 'service', new.service,
                             'counselor_id', v_client.counselor_id, 'office', v_office),
          jsonb_build_object('account', public.ledger_account('ar'), 'credit', new.paid_amount,
                             'client_id', new.client_id, 'service', new.service,
                             'counselor_id', v_client.counselor_id, 'office', v_office)
        ),
        -- What the money was for, so a cash-basis report does not have to
        -- work it out from an Accounts receivable credit.
        v_revenue
      );
    end if;
  end if;

  -- ── unsubmitted: the receivable stops standing ──
  --
  -- Closed is here: an item submitted and then closed has been refused or
  -- abandoned, and what was owed to the practice is not owed any more.
  if old.status = 'Submitted' and new.status in ('Billing review', 'Ready for billing', 'Closed') then
    v_live := public.ledger_live_posting('Billing item', new.id, 'Submitted');
    if v_live is not null then
      perform public.reverse_journal(v_live, format('Item went back to %s', new.status));
    end if;
  end if;

  -- ── unpaid: only where the payment actually came undone ──
  --
  -- Closed is deliberately not here. It is an ending, not a correction: an
  -- item that was paid and is then closed off has still been paid, and
  -- reversing it would take real money off the books.
  if old.status = 'Paid'
     and new.status in ('Submitted', 'Pending', 'Correction needed', 'Billing review', 'Ready for billing') then
    v_live := public.ledger_live_posting('Billing item', new.id, 'Paid');
    if v_live is not null then
      perform public.reverse_journal(v_live, format('Payment undone: item is now %s', new.status));
    end if;
  end if;

  return new;
end;
$function$;

-- ── bank_suggestions ──

CREATE OR REPLACE FUNCTION public.bank_suggestions(p_statement uuid)
 RETURNS TABLE(transaction_id uuid, kind text, why text, account_id uuid, journal_id uuid)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  with tx as (
    select t.* from public.bank_transactions t
     where t.statement_id = p_statement and t.status = 'Unmatched'
  ),
  -- Money the practice has been paid and not yet banked, which is what a
  -- deposit on the statement nearly always is.
  undeposited as (
    select coalesce(sum(l.debit) - sum(l.credit), 0) as balance
      from public.journal_lines l
     where l.account_id = public.ledger_account('undeposited')
  )
  select t.id,
         case
           when t.amount > 0 and (select balance from undeposited) > 0 then 'Deposit'
           when t.amount < 0 and p.id is not null then 'Payout already posted'
           when t.amount < 0 then 'Money out'
           else 'Money in'
         end,
         case
           when t.amount > 0 and (select balance from undeposited) > 0
             then 'Payments received and not yet banked come to ' || to_char((select balance from undeposited), 'FM999999990.00')
           when t.amount < 0 and p.id is not null
             then 'A payout of the same amount was posted on ' || p.entry_date
           when t.amount < 0
             then 'Say what this was: an expense, a transfer, or a draw'
           else 'Say what this was'
         end,
         case
           when t.amount > 0 and (select balance from undeposited) > 0 then public.ledger_account('undeposited')
           when t.amount < 0 and p.id is null then public.ledger_account('expense_other')
           else null
         end,
         p.id
    from tx t
    left join lateral (
      -- A posting that already took this money out of the bank, within a few
      -- days either side: a cheque clears when it clears.
      select j.id, j.entry_date
        from public.journals j
        join public.journal_lines l on l.journal_id = j.id
       where l.account_id = public.ledger_account('bank')
         and l.credit = abs(t.amount)
         and j.entry_date between t.posted_on - 10 and t.posted_on + 10
         and not exists (select 1 from public.bank_transactions b where b.journal_id = j.id)
       order by abs(j.entry_date - t.posted_on)
       limit 1
    ) p on true;
$function$;

commit;
