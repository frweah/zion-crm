-- Zion Vocational Rehab CRM — closing a paid item is not undoing it (E1)
--
-- The posting trigger reversed the cash whenever an item left Paid for
-- anything else, which is right for every status except one. Closed is an
-- ending, not a correction: an item that was paid and is then closed off has
-- still been paid, and the money is still in the practice's hands.
--
-- Left as it was, closing a paid item would have reversed a receipt - taking
-- real money off the books with a reversal nobody would read until the month
-- would not reconcile. The reversal now happens only for the statuses that
-- actually mean the payment came undone.
--
-- Submitted is not changed: an item submitted and then closed has been
-- refused or abandoned, and the receivable should come off.

create or replace function public.post_billing_item()
returns trigger language plpgsql security definer set search_path = public as $$
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
        format('%s - %s paid%s', v_client.name, new.service,
               case when coalesce(new.warrant, '') <> '' then ', warrant ' || new.warrant else '' end),
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
$$;

comment on function public.post_billing_item is
  'Revenue when an item is submitted, cash when it is paid, and a reversal only where one of those actually came undone (0154).';
