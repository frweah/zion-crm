-- Zion Vocational Rehab CRM — postings the CRM makes for itself (E1)
--
-- Nothing here is re-entered. Every posting comes from an event the practice
-- already records, and carries a link back to it, so a figure on a report can
-- always be answered with "that is this billing item, on that day".
--
--   a billing item submitted      AR            / revenue for its service
--   a billing item paid           Undeposited   / AR
--   a statement approved          Contractor cost / Contractor payables
--   a claim on that statement     its expense   / Contractor payables
--   a contractor paid             Contractor payables / Bank
--
-- Two decisions worth writing down, because both could reasonably have gone
-- the other way:
--
--   A warrant is paid into Undeposited funds, not straight into Bank. A
--   warrant is a cheque: it exists before it is at the bank, and the deposit
--   is a separate event the statement will show. Posting it straight to Bank
--   would make the ledger disagree with the statement by however many days
--   the cheque sat in a drawer, and bank reconciliation is the one report
--   that cannot be allowed to be approximately right.
--
--   Cash comes from the billing item, not from `payments`. `payments` is
--   what the warrant-stub reader writes when Melanie uploads a warrant PDF -
--   useful, optional, and not always there. The billing item is what
--   Margaret always touches. Posting from both would count the same money
--   twice; posting from the one that is always touched misses nothing.
--
-- And one rule that makes the whole thing safe to deploy today: nothing is
-- posted before the day the books open (1 January 2027). The postings below
-- are live from this deploy and do nothing at all until then, which is how
-- the ledger can be built and verified in October without touching the
-- operational year that is still running.

-- ── the few things a posting needs to look up ──────────────
create or replace function public.ledger_entity()
returns uuid language sql stable as $$
  select id from public.ledger_entities where is_default;
$$;

comment on function public.ledger_entity is
  'The entity new postings belong to (0142). One today; E5 makes this a choice.';

create or replace function public.ledger_account(p_role text)
returns uuid language sql stable as $$
  select a.id
    from public.ledger_accounts a
    join public.ledger_entities e on e.id = a.entity_id and e.is_default
   where a.role = p_role;
$$;

comment on function public.ledger_account is
  'The account the CRM posts to for a kind of event, by role rather than by name (0142).';

create or replace function public.ledger_revenue_account(p_service text)
returns uuid language sql stable as $$
  select coalesce(
    (select account_id from public.ledger_revenue_map where service = p_service),
    public.ledger_account('revenue_other'));
$$;

comment on function public.ledger_revenue_account is
  'The revenue account a service bills to, or Other service revenue - so a new service is never unposted (0142).';

create or replace function public.ledger_expense_account(p_category text)
returns uuid language sql stable as $$
  select coalesce(
    (select account_id from public.ledger_expense_map where category = p_category),
    public.ledger_account('expense_other'));
$$;

comment on function public.ledger_expense_account is
  'The expense account a claim category lands in, or Other (0142).';

create or replace function public.ledger_open_date(p_date date)
returns date language plpgsql stable security definer set search_path = public as $$
declare
  v_entity uuid := public.ledger_entity();
  v_date   date := p_date;
  v_guard  integer := 0;
begin
  while v_guard < 120 and exists (
    select 1 from public.ledger_periods
     where entity_id = v_entity and month = date_trunc('month', v_date)::date
  ) loop
    v_date := (date_trunc('month', v_date) + interval '1 month')::date;
    v_guard := v_guard + 1;
  end loop;
  return v_date;
end;
$$;

comment on function public.ledger_open_date is
  'The first month at or after this day that will take a posting (0142).';

revoke all on function public.ledger_open_date(date) from anon, authenticated;

-- ─────────────────────────────────────────────────────────────
-- Posted exactly once
--
-- Source, id and event identify an event in a thing's life. A billing item
-- submitted, reversed because of a correction, and submitted again is three
-- postings and not one: the event names carry a number so the second
-- submission is its own posting rather than a silent no-op against the first.
-- ─────────────────────────────────────────────────────────────
create or replace function public.ledger_live_posting(p_kind text, p_id uuid, p_event text)
returns uuid language sql stable as $$
  select j.id
    from public.journals j
   where j.source_kind = p_kind
     and j.source_id = p_id
     and (j.source_event = p_event or j.source_event like p_event || '#%')
     and not exists (select 1 from public.journals r where r.reverses_id = j.id)
   order by j.created_at desc
   limit 1;
$$;

comment on function public.ledger_live_posting is
  'The posting for this event that still stands, if there is one (0142). A reversed posting does not stand.';

create or replace function public.ledger_next_event(p_kind text, p_id uuid, p_event text)
returns text language sql stable as $$
  select case when n = 0 then p_event else p_event || '#' || (n + 1) end
    from (
      select count(*) as n
        from public.journals j
       where j.source_kind = p_kind
         and j.source_id = p_id
         and (j.source_event = p_event or j.source_event like p_event || '#%')
    ) c;
$$;

comment on function public.ledger_next_event is
  'The name for this posting of an event, numbered if the event has been posted before (0142).';

-- ─────────────────────────────────────────────────────────────
-- The one way into the ledger
-- ─────────────────────────────────────────────────────────────
create or replace function public.post_journal(
  p_entry_date date,
  p_memo text,
  p_source_kind text,
  p_source_id uuid,
  p_source_event text,
  p_lines jsonb,
  p_cash_class uuid default null,
  p_reason text default '',
  p_attachment text default null,
  p_by uuid default null,
  p_by_name text default '',
  p_shift_if_closed boolean default true
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_entity uuid := public.ledger_entity();
  v_start  date;
  v_date   date := p_entry_date;
  v_memo   text := coalesce(p_memo, '');
  v_id     uuid;
begin
  select books_start into v_start from public.ledger_settings where entity_id = v_entity;

  -- The books are not open yet, so there is nothing to post to. The practice
  -- carries on exactly as before; this is what lets the ledger ship months
  -- ahead of the day it starts counting.
  if v_start is null or v_date < v_start then
    return null;
  end if;

  /**
   * A closed month cannot take a posting, and a warrant that arrives after
   * the month was closed is still money that arrived. It posts to the
   * earliest open month instead, saying on its face what day it happened -
   * which is what a bookkeeper does, and is better than either breaking the
   * action that caused it or losing it.
   */
  if p_shift_if_closed then
    v_date := public.ledger_open_date(v_date);
    if v_date <> p_entry_date then
      v_memo := v_memo || format(' (happened %s; %s was closed)', p_entry_date, to_char(p_entry_date, 'FMMonth YYYY'));
    end if;
  end if;

  insert into public.journals (
    entity_id, entry_date, memo, source_kind, source_id, source_event,
    reason, attachment_path, cash_class_account_id, created_by, created_by_name
  ) values (
    v_entity, v_date, v_memo, p_source_kind, p_source_id, coalesce(p_source_event, ''),
    coalesce(p_reason, ''), p_attachment, p_cash_class, p_by, coalesce(p_by_name, '')
  )
  returning id into v_id;

  insert into public.journal_lines (
    journal_id, account_id, debit, credit, memo,
    client_id, staff_id, counselor_id, office, service
  )
  select v_id,
         (l->>'account')::uuid,
         round(coalesce((l->>'debit')::numeric, 0), 2),
         round(coalesce((l->>'credit')::numeric, 0), 2),
         coalesce(l->>'memo', ''),
         nullif(l->>'client_id', '')::uuid,
         nullif(l->>'staff_id', '')::uuid,
         nullif(l->>'counselor_id', '')::uuid,
         coalesce(l->>'office', ''),
         coalesce(l->>'service', '')
    from jsonb_array_elements(p_lines) l;

  return v_id;
end;
$$;

comment on function public.post_journal is
  'The one way a posting enters the ledger (0142). Silent before the books open; a closed month moves it to the next open one, saying so.';

revoke all on function public.post_journal(date, text, text, uuid, text, jsonb, uuid, text, text, uuid, text, boolean) from anon, authenticated;

-- ─────────────────────────────────────────────────────────────
-- A correction: reverse it and say why
-- ─────────────────────────────────────────────────────────────
create or replace function public.reverse_journal(p_journal uuid, p_reason text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_src    public.journals;
  v_id     uuid;
  v_entity uuid := public.ledger_entity();
begin
  select * into v_src from public.journals where id = p_journal;
  if v_src.id is null then
    raise exception 'There is no posting to reverse';
  end if;
  if exists (select 1 from public.journals where reverses_id = p_journal) then
    raise exception 'That posting has already been reversed';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'A reversal needs a reason'
      using hint = 'Somebody will read this in six months and was not here today.';
  end if;

  insert into public.journals (
    entity_id, entry_date, memo, source_kind, source_id, source_event,
    reverses_id, reason, cash_class_account_id, created_by, created_by_name
  ) values (
    v_entity,
    -- Dated the day the correction is made, not the day of the mistake: a
    -- month that has been reported on does not change afterwards.
    public.ledger_open_date(greatest(v_src.entry_date, public.practice_today())),
    'Reverses: ' || v_src.memo,
    'Reversal', p_journal, '',
    p_journal, p_reason, v_src.cash_class_account_id,
    (select public.current_staff_id()),
    coalesce((select name from public.staff where id = (select public.current_staff_id())), '')
  )
  returning id into v_id;

  insert into public.journal_lines (
    journal_id, account_id, debit, credit, memo,
    client_id, staff_id, counselor_id, office, service
  )
  select v_id, l.account_id, l.credit, l.debit, l.memo,
         l.client_id, l.staff_id, l.counselor_id, l.office, l.service
    from public.journal_lines l where l.journal_id = p_journal;

  return v_id;
end;
$$;

comment on function public.reverse_journal is
  'Undoes a posting by posting its mirror, dated today, with a reason (0142). The original stays where it is.';

revoke all on function public.reverse_journal(uuid, text) from anon, authenticated;
grant execute on function public.reverse_journal(uuid, text) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- A billing item: revenue when it is submitted, cash when it is paid
-- ─────────────────────────────────────────────────────────────
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

  -- ── unsubmitted, or unpaid: the posting stops standing ──
  if old.status = 'Submitted' and new.status in ('Billing review', 'Ready for billing', 'Closed') then
    v_live := public.ledger_live_posting('Billing item', new.id, 'Submitted');
    if v_live is not null then
      perform public.reverse_journal(v_live, format('Item went back to %s', new.status));
    end if;
  end if;

  if old.status = 'Paid' and new.status <> 'Paid' then
    v_live := public.ledger_live_posting('Billing item', new.id, 'Paid');
    if v_live is not null then
      perform public.reverse_journal(v_live, format('Payment undone: item is now %s', new.status));
    end if;
  end if;

  return new;
end;
$$;

comment on function public.post_billing_item is
  'Revenue when an item is submitted, cash when it is paid, and a reversal if either is undone (0142).';

drop trigger if exists billing_items_post on public.billing_items;
create trigger billing_items_post after update of status on public.billing_items
  for each row execute function public.post_billing_item();

-- ─────────────────────────────────────────────────────────────
-- A contractor statement approved: the cost is the practice's now
--
-- The labour and the claims are separate postings, because they are separate
-- expenses and a report that cannot tell mileage from coaching hours is not
-- worth running. Both are owed to the same person, so both credit Contractor
-- payables and the payout clears them together.
-- ─────────────────────────────────────────────────────────────
create or replace function public.post_statement_approval()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_staff   public.staff;
  v_claim   record;
  v_amount  numeric;
  v_rate    numeric;
begin
  if new.status <> 'Approved' or old.status = 'Approved' then
    return new;
  end if;

  select * into v_staff from public.staff where id = new.staff_id;

  -- ── the work on it ──
  if coalesce(new.approved_amount, 0) > 0
     and public.ledger_live_posting('Contractor statement', new.id, 'Approved') is null then
    perform public.post_journal(
      new.period_end,
      format('%s - statement to %s approved', v_staff.name, new.period_end),
      'Contractor statement', new.id,
      public.ledger_next_event('Contractor statement', new.id, 'Approved'),
      jsonb_build_array(
        jsonb_build_object('account', public.ledger_account('contractor_cost'),
                           'debit', new.approved_amount, 'staff_id', new.staff_id),
        jsonb_build_object('account', public.ledger_account('contractor_payable'),
                           'credit', new.approved_amount, 'staff_id', new.staff_id)
      )
    );
  end if;

  -- ── and the claims it carries ──
  for v_claim in
    select e.id, e.incurred_on, e.category, e.description, e.amount, e.miles, e.client_id,
           c.is_mileage
      from public.expenses e
      join public.expense_categories c on c.key = e.category
     where e.statement_id = new.id
  loop
    if v_claim.is_mileage then
      v_rate := public.mileage_rate_on(v_claim.incurred_on);
      -- No rate covering the day means unpriced, not free. It waits for a
      -- rate rather than posting a number nobody set.
      v_amount := case when v_rate is null then null else round(v_claim.miles * v_rate / 100.0, 2) end;
    else
      v_amount := v_claim.amount;
    end if;

    if coalesce(v_amount, 0) > 0
       and public.ledger_live_posting('Expense claim', v_claim.id, 'Approved') is null then
      perform public.post_journal(
        v_claim.incurred_on,
        format('%s - %s%s', v_staff.name, v_claim.category,
               case when coalesce(v_claim.description, '') <> '' then ': ' || v_claim.description else '' end),
        'Expense claim', v_claim.id,
        public.ledger_next_event('Expense claim', v_claim.id, 'Approved'),
        jsonb_build_array(
          jsonb_build_object('account', public.ledger_expense_account(v_claim.category),
                             'debit', v_amount, 'staff_id', new.staff_id,
                             'client_id', coalesce(v_claim.client_id::text, '')),
          jsonb_build_object('account', public.ledger_account('contractor_payable'),
                             'credit', v_amount, 'staff_id', new.staff_id)
        )
      );
    end if;
  end loop;

  return new;
end;
$$;

comment on function public.post_statement_approval is
  'The cost of an approved statement and each claim on it, owed to the person who earned it (0142).';

drop trigger if exists contractor_statements_post on public.contractor_statements;
create trigger contractor_statements_post after update of status on public.contractor_statements
  for each row execute function public.post_statement_approval();

-- ─────────────────────────────────────────────────────────────
-- A contractor paid: what was owed leaves the bank
-- ─────────────────────────────────────────────────────────────
create or replace function public.post_contractor_payment()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_staff public.staff;
begin
  select * into v_staff from public.staff where id = new.staff_id;

  perform public.post_journal(
    new.paid_on,
    format('%s paid%s', v_staff.name,
           case when coalesce(new.reference, '') <> '' then ', ' || new.method || ' ' || new.reference
                else ', ' || new.method end),
    'Contractor payment', new.id,
    public.ledger_next_event('Contractor payment', new.id, 'Paid'),
    jsonb_build_array(
      jsonb_build_object('account', public.ledger_account('contractor_payable'),
                         'debit', new.amount, 'staff_id', new.staff_id),
      jsonb_build_object('account', public.ledger_account('bank'),
                         'credit', new.amount, 'staff_id', new.staff_id)
    ),
    public.ledger_account('contractor_cost')
  );

  return new;
end;
$$;

comment on function public.post_contractor_payment is
  'A payout clears what the practice owed and leaves the bank (0142).';

drop trigger if exists contractor_payments_post on public.contractor_payments;
create trigger contractor_payments_post after insert on public.contractor_payments
  for each row execute function public.post_contractor_payment();

-- ─────────────────────────────────────────────────────────────
-- A journal somebody writes by hand
--
-- Admin posts. Billing drafts, if the practice turns that on: the two-person
-- rule is optional in the brief, so it is a setting rather than a shape, and
-- until somebody asks for it a draft is simply a journal Admin has not
-- posted yet. Both need a reason, and either can carry an attachment.
-- ─────────────────────────────────────────────────────────────
create or replace function public.post_manual_journal(
  p_entry_date date,
  p_memo text,
  p_reason text,
  p_lines jsonb,
  p_attachment text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_entity uuid := public.ledger_entity();
  v_start  date;
  v_id     uuid;
begin
  if not public.is_admin() then
    raise exception 'Only Admin posts a journal entry';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'A journal entry needs a reason'
      using hint = 'An entry nobody can explain is one nobody can audit.';
  end if;

  select books_start into v_start from public.ledger_settings where entity_id = v_entity;
  if v_start is null or p_entry_date < v_start then
    raise exception 'The books open on %', coalesce(v_start::text, 'a day nobody has set yet');
  end if;
  if exists (
    select 1 from public.ledger_periods
     where entity_id = v_entity and month = date_trunc('month', p_entry_date)::date
  ) then
    raise exception '% is closed', to_char(p_entry_date, 'FMMonth YYYY')
      using hint = 'Reopen the month, or date the entry in an open one.';
  end if;

  v_id := public.post_journal(
    p_entry_date, p_memo, 'Manual', null, '', p_lines,
    null, p_reason, p_attachment,
    (select public.current_staff_id()),
    coalesce((select name from public.staff where id = (select public.current_staff_id())), ''),
    false
  );
  return v_id;
end;
$$;

comment on function public.post_manual_journal is
  'A journal entry written by hand, with a reason and optionally an attachment (0142). Admin only.';

revoke all on function public.post_manual_journal(date, text, text, jsonb, text) from anon, authenticated;
grant execute on function public.post_manual_journal(date, text, text, jsonb, text) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- Opening balances
--
-- One entry, dated the day the books open, and only one: a second would mean
-- the books opened twice. The owner's answer is that they are zero, which
-- makes this a mechanism that will be used once and has to be right anyway -
-- the day a balance is not zero is the day somebody finds out whether it
-- worked.
-- ─────────────────────────────────────────────────────────────
create or replace function public.set_opening_balances(p_lines jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_entity uuid := public.ledger_entity();
  v_start  date;
  v_id     uuid;
begin
  if not public.is_admin() then
    raise exception 'Only Admin enters opening balances';
  end if;

  select books_start into v_start from public.ledger_settings where entity_id = v_entity;
  if v_start is null then
    raise exception 'Set the day the books open first';
  end if;
  if exists (select 1 from public.journals where entity_id = v_entity and source_kind = 'Opening balance') then
    raise exception 'The opening balances are already in'
      using hint = 'Correct them with a journal entry; the books open once.';
  end if;

  v_id := public.post_journal(
    v_start, 'Opening balances', 'Opening balance', null, '', p_lines,
    null, 'The balances the books opened with', null,
    (select public.current_staff_id()),
    coalesce((select name from public.staff where id = (select public.current_staff_id())), ''),
    false
  );
  return v_id;
end;
$$;

comment on function public.set_opening_balances is
  'The balances the books opened with, entered once, dated the day they opened (0142).';

revoke all on function public.set_opening_balances(jsonb) from anon, authenticated;
grant execute on function public.set_opening_balances(jsonb) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- Closing and reopening a month
-- ─────────────────────────────────────────────────────────────
create or replace function public.close_ledger_month(p_month date, p_note text default '')
returns void language plpgsql security definer set search_path = public as $$
declare
  v_entity uuid := public.ledger_entity();
  v_month  date := date_trunc('month', p_month)::date;
begin
  if not public.is_admin() then
    raise exception 'Only Admin closes a month';
  end if;
  if v_month >= date_trunc('month', public.practice_today())::date then
    raise exception 'A month is closed after it has finished';
  end if;

  insert into public.ledger_periods (entity_id, month, closed_by, closed_by_name, note)
  values (v_entity, v_month, (select public.current_staff_id()),
          coalesce((select name from public.staff where id = (select public.current_staff_id())), ''),
          coalesce(p_note, ''))
  on conflict (entity_id, month) do nothing;

  perform public.log_access('The books', null, null, format('closed %s', to_char(v_month, 'FMMonth YYYY')));
end;
$$;

create or replace function public.reopen_ledger_month(p_month date, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_entity uuid := public.ledger_entity();
  v_month  date := date_trunc('month', p_month)::date;
begin
  if not public.is_admin() then
    raise exception 'Only Admin reopens a month';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'Reopening a closed month needs a reason';
  end if;

  delete from public.ledger_periods where entity_id = v_entity and month = v_month;
  perform public.log_access('The books', null, null, format('reopened %s: %s', to_char(v_month, 'FMMonth YYYY'), p_reason));
end;
$$;

comment on function public.close_ledger_month is
  'Shuts a finished month to postings (0142). Admin only, and written down.';
comment on function public.reopen_ledger_month is
  'Opens a closed month again, with a reason, in the access log (0142). Admin only.';

revoke all on function public.close_ledger_month(date, text) from anon, authenticated;
revoke all on function public.reopen_ledger_month(date, text) from anon, authenticated;
grant execute on function public.close_ledger_month(date, text) to authenticated;
grant execute on function public.reopen_ledger_month(date, text) to authenticated;
