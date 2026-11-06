-- Zion Vocational Rehab CRM — the invoice ledger (Phase 3, part two)
--
-- An invoice is written when the packet is sent, and settled when the money
-- arrives. Neither is something anybody has to remember to do.
--
-- ── sending ───────────────────────────────────────────────────
--
-- submit_invoice is the record of what went out: the amount, the office, the
-- services it was for, and the progress report that went with it. It refuses
-- an authorization that already has an invoice outstanding, because sending
-- the same claim again while the first is unanswered is the duplicate this
-- whole exercise was about. A genuine repeat claim is sent after the first is
-- paid, and that is allowed.
--
-- What stops the same work being billed twice is narrower and harder: a
-- service entry can appear on one invoice line, by unique index. Submit can be
-- pressed all day and the second press bills nothing.
--
-- ── settling ──────────────────────────────────────────────────
--
-- A payment landing finds the invoice it answers rather than being filed
-- against it by hand. That matters because two of the three ways money
-- arrives are not a person: the warrant import, and the nightly sweep. A
-- short payment then becomes Short-paid by arithmetic, and taking a payment
-- back puts the invoice back to Submitted - which is what "the difference" on
-- the chase list is read from.

begin;

-- ── a payment settles its invoice ────────────────────────────
create or replace function public.payment_settles_the_invoice()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_auth    uuid;
  v_invoice uuid;
  v_open    integer;
  r         record;
begin
  -- The update below writes to payments, which fires this again. One level
  -- deep is the real event; anything deeper is this trigger's own doing.
  if pg_trigger_depth() > 1 then
    return null;
  end if;

  v_auth := coalesce(
    case when tg_op <> 'DELETE' then new.auth_id end,
    case when tg_op <> 'INSERT' then old.auth_id end);
  if v_auth is null then
    return null;
  end if;

  /*
   * A payment with no invoice named finds one only when there is exactly one
   * it could be: an invoice on that authorization that is still open and has
   * no payment against it. One candidate is an answer; two is a guess.
   *
   * That is not a theoretical scruple. The first version took the oldest open
   * invoice, and the backfill of 161 invoices caught it within a minute: on
   * V996569, which the state paid as three claims, two payments went onto the
   * same claim and a third claim was left looking unpaid for $250. An
   * authorization with several claims outstanding cannot be settled by
   * guessing which one a warrant line answers - the voucher says, and whoever
   * has the voucher names the invoice.
   *
   * Only the row that just arrived, too, rather than every payment on the
   * authorization: the trigger is per row and sweeping the others is how one
   * insert reassigned three.
   */
  if tg_op <> 'DELETE' and new.invoice_id is null then
    -- Counted first, and the id read only when there is one of it. There is
    -- no min() for a uuid, and reaching for one would have been the wrong
    -- shape anyway: the question is whether there is exactly one candidate,
    -- not which of several sorts first.
    select count(*) into v_open
      from public.invoices i
     where i.auth_id = v_auth
       and i.status in ('Submitted', 'Short-paid')
       and not exists (select 1 from public.payments q where q.invoice_id = i.id);

    if v_open = 1 then
      select i.id into v_invoice
        from public.invoices i
       where i.auth_id = v_auth
         and i.status in ('Submitted', 'Short-paid')
         and not exists (select 1 from public.payments q where q.invoice_id = i.id);
      update public.payments set invoice_id = v_invoice where id = new.id;
    end if;
  end if;

  -- And every invoice on that authorization is brought to what its own
  -- payments say. The status trigger turns the figures into the word.
  for r in select i.id from public.invoices i where i.auth_id = v_auth loop
    update public.invoices i
       set amount_paid = s.total,
           paid_on     = s.last_day,
           warrant     = coalesce(s.warrant, i.warrant),
           voucher     = coalesce(s.voucher, i.voucher)
      from (select nullif(sum(p.amount), 0) as total,
                   max(p.warrant_date) as last_day,
                   (array_agg(nullif(btrim(p.warrant_no), '') order by p.warrant_date desc nulls last))[1] as warrant,
                   (array_agg(nullif(btrim(p.voucher), '') order by p.warrant_date desc nulls last))[1] as voucher
              from public.payments p where p.invoice_id = r.id) s
     where i.id = r.id;
  end loop;

  return null;
end $$;

drop trigger if exists payments_settle_invoices on public.payments;
create trigger payments_settle_invoices
  after insert or update or delete on public.payments
  for each row execute function public.payment_settles_the_invoice();

revoke execute on function public.payment_settles_the_invoice() from anon, authenticated;

-- ── which office an invoice goes to ──────────────────────────
--
-- The authorization says who it was sent to in words; client_billing_office
-- says which billing office covers the client, through their counselor's
-- office. The first is what somebody typed and the second is what the
-- directory knows, so the words are tried first and the directory answers
-- when they are blank or do not match anything.
create or replace function public.billing_office_for_authorization(p_auth uuid)
returns uuid
language sql
stable security definer
set search_path to 'public'
as $$
  select coalesce(
    (select b.id from public.authorizations a
       join public.billing_offices b
         on lower(btrim(b.name)) = lower(btrim(replace(coalesce(a.recipient, ''), ' CRP', '')))
      where a.id = p_auth),
    (select o.billing_office_id
       from public.authorizations a
       join public.client_billing_office o on o.client_id = a.client_id
      where a.id = p_auth)
  );
$$;

revoke execute on function public.billing_office_for_authorization(uuid) from anon, authenticated;
grant execute on function public.billing_office_for_authorization(uuid) to authenticated;

-- ── the invoice itself ───────────────────────────────────────
create or replace function public.submit_invoice(
  p_auth uuid,
  p_office uuid default null,
  p_report uuid default null,
  p_amount numeric default null)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  a        public.authorizations;
  v_me     uuid := public.current_staff_id();
  v_office uuid;
  v_amount numeric;
  v_hours  numeric;
  v_id     uuid;
  v_lines  integer := 0;
begin
  if not public.billing_hands() then
    raise exception 'Raising an invoice is Billing''s, or an Admin''s.'
      using errcode = 'insufficient_privilege';
  end if;
  if v_me is null then
    raise exception 'An invoice has to say who sent it.' using errcode = 'insufficient_privilege';
  end if;

  select * into a from public.authorizations where id = p_auth for update;
  if not found then
    raise exception 'That authorization does not exist.' using errcode = 'no_data_found';
  end if;

  if exists (select 1 from public.invoices i
              where i.auth_id = p_auth and i.status in ('Submitted', 'Short-paid')) then
    raise exception 'There is already an invoice outstanding on %.',
      coalesce(nullif(a.number, ''), a.service_type)
      using hint = 'Record what came in against it first, or chase it. A second invoice while the first is unanswered is how the same claim gets sent twice.',
            errcode = 'unique_violation';
  end if;

  v_office := coalesce(p_office, public.billing_office_for_authorization(p_auth));

  -- What is being billed: the amount given, or the flat fee, or the hours
  -- that have not been billed yet at the authorization's rate.
  select coalesce(sum(e.hours), 0) into v_hours
    from public.service_entries e
   where e.auth_id = p_auth and not e.non_billable
     and not exists (select 1 from public.invoice_lines l where l.entry_id = e.id);

  v_amount := coalesce(
    nullif(p_amount, 0),
    case when a.rate_type = 'Flat Fee' then nullif(coalesce(a.rate, 0), 0)
         else nullif(round(v_hours * coalesce(a.rate, 0), 2), 0) end);

  if coalesce(v_amount, 0) <= 0 then
    raise exception '% comes to nothing, so there is no invoice to send.',
      coalesce(nullif(a.number, ''), a.service_type)
      using hint = 'Log the hours, or type the amount being invoiced.',
            errcode = 'invalid_parameter_value';
  end if;

  insert into public.invoices
    (client_id, auth_id, submitted_on, submitted_by, office_id, sent_to,
     amount, report_id, status, source)
  values
    (a.client_id, p_auth, public.practice_today(), v_me, v_office,
     coalesce((select b.billing_email from public.billing_offices b where b.id = v_office), ''),
     v_amount, p_report, 'Submitted', 'Submit')
  returning id into v_id;

  -- The hours it is for, each one billed once and never again.
  insert into public.invoice_lines (invoice_id, entry_id, on_date, description, hours, rate, amount)
  select v_id, e.id, e.date, coalesce(nullif(btrim(e.notes), ''), a.service_type),
         e.hours, a.rate, round(e.hours * coalesce(a.rate, 0), 2)
    from public.service_entries e
   where e.auth_id = p_auth and not e.non_billable
     and not exists (select 1 from public.invoice_lines l where l.entry_id = e.id);
  get diagnostics v_lines = row_count;

  -- A flat fee has no hours behind it, so it is one line saying what it is.
  if v_lines = 0 then
    insert into public.invoice_lines (invoice_id, on_date, description, amount)
    values (v_id, coalesce(a.service_end, a.end_date, public.practice_today()),
            a.service_type, v_amount);
  end if;

  return v_id;
end $$;

revoke execute on function public.submit_invoice(uuid, uuid, uuid, numeric) from anon, authenticated;
grant execute on function public.submit_invoice(uuid, uuid, uuid, numeric) to authenticated;

commit;
