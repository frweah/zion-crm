-- Zion Vocational Rehab CRM - a payment recorded by hand is not paid twice
-- (owner, 14 Oct 2026: "A later warrant line that matches links to it
-- instead of paying twice.")
--
-- 0190 lets Billing clear a months-old item from the working list with a
-- received date and an amount. Often there is no warrant number to type: the
-- remittance says what arrived and when, and the stub itself turns up weeks
-- later in a scan.
--
-- Before this, that scan produced a line the reader could not account for.
-- The authorization was already Paid and no payment on it carried the
-- warrant number, so the line was held for review with "does not match that
-- payment" - and the obvious way to clear it, recording it, would have put
-- the money on the books twice.
--
-- So the reader's idea of "already recorded" now includes a payment with no
-- warrant number at all, matched on the authorization and the amount. When it
-- links, the number the payment never had is written onto it and onto the
-- authorization. An exact warrant match still wins, so a page carrying both
-- an exact and a blank candidate takes the exact one.
--
-- The function is otherwise 0174's, read back out of the database rather than
-- out of the migration, because those two have drifted before.

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
     * An authorization already Paid may only be claimed by the payment that
     * paid it - the same warrant, the same amount, seen again in another scan.
     * Anything else is a line nobody can account for, and recording it would
     * put money on the books against work that was already settled. It waits.
     */
    if v_problem is null and v_auth.status = 'Paid'
       and not exists (
         select 1 from public.payments p
          where p.auth_id = v_auth.id
            and p.amount = v_amount
            and (p.warrant_no = v_page.warrant_no
                 -- Or recorded by hand before the stub arrived (0190). The
                 -- warrant number was on paper nobody had yet, so the
                 -- payment went on the record without one; this line is
                 -- where that number finally turns up.
                 or (p.warrant_no = '' and p.source = 'By hand'))) then
      v_problem := format('%s was paid on %s for %s, and this line does not match that payment.',
                          coalesce(nullif(v_auth.number, ''), v_auth.service_type),
                          coalesce(v_auth.paid_on::text, 'an unrecorded date'),
                          coalesce(v_auth.paid_amount::text, 'an unrecorded amount'));
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
        update public.authorizations
           set status = 'Paid',
               paid_on = v_page.warrant_date,
               paid_amount = v_amount,
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

comment on function public.reconcile_warrant_line is
  'Reconciles one warrant line against the authorization it pays. A payment already recorded for that authorization and amount claims the line rather than being paid again - including one recorded by hand with no warrant number, which takes its number from the line.';
