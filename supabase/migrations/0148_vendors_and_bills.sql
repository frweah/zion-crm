-- Zion Vocational Rehab CRM — vendors, bills and purchasing (ERP brief, E3)
--
-- The practice pays rent, software, insurance and an accountant, and until
-- now the only record of that was a bank statement. A bill is now a thing
-- with a life: it arrives, somebody approves it, it is scheduled, it is paid,
-- and each of those steps posts to the ledger on its own.
--
-- Three decisions worth writing down.
--
--   No vendor tax number is kept. A 1099-able vendor has a W-9, the W-9
--   lives in the practice's documents, and what the CRM stores is that it is
--   on file and the last four digits - which is exactly what a 1099 snapshot
--   records anyway (form_1099_recipients has tin_last4 and no tin). A second
--   place to hold tax numbers is a second thing to protect, for no gain.
--
--   Approval is a threshold, not a role. Under the limit the owner sets,
--   whoever does the billing can approve a bill; over it, only an Admin can.
--   A rule that says "Billing can approve small things" is a rule somebody
--   has to look up; a number is one they can see.
--
--   A recurring bill is created, not posted. Rent on the first is a bill
--   somebody still has to look at, because the month the rent changes is the
--   month an automatic posting would be wrong and nobody would notice.

-- ── a posting can come from a bill ─────────────────────────
--
-- The list is written out in full rather than added to from memory: 0059
-- lost a subject from the access log by rebuilding its list from the
-- original four, and the schema accepted that happily.
alter table public.journals drop constraint if exists journals_source_kind_check;
alter table public.journals add constraint journals_source_kind_check
  check (source_kind in (
    'Billing item', 'Contractor statement', 'Contractor payment',
    'Expense claim', 'Bank transaction', 'Vendor bill',
    'Manual', 'Opening balance', 'Reversal'));

-- ── who the practice pays ──────────────────────────────────
create table if not exists public.vendors (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.ledger_entities(id) on delete restrict,
  name text not null,
  contact_name text not null default '',
  email text not null default '',
  phone text not null default '',
  address text not null default '',

  -- Which account their bills usually land in, so a bill does not ask twice.
  expense_account_id uuid references public.ledger_accounts(id) on delete set null,
  -- Days from the bill date to when it is due, where the vendor has terms.
  terms_days integer check (terms_days is null or terms_days >= 0),

  /**
   * A vendor who gets a 1099.
   *
   * An unincorporated US vendor paid for services, broadly. The practice and
   * its CPA decide; the CRM records the decision and whether the W-9 backing
   * it is on file, and refuses to file for one where it is not.
   */
  gets_1099 boolean not null default false,
  w9_on_file boolean not null default false,
  w9_received_on date,
  tin_type text check (tin_type is null or tin_type in ('SSN', 'EIN')),
  tin_last4 text check (tin_last4 is null or tin_last4 ~ '^[0-9]{4}$'),

  active boolean not null default true,
  note text not null default '',
  created_at timestamptz not null default now(),
  created_by uuid references public.staff(id) on delete set null,
  updated_at timestamptz not null default now(),

  unique (entity_id, name),
  -- A 1099 vendor without a W-9 on file is a vendor nothing can be filed
  -- for, and the record says so rather than the filing discovering it.
  constraint vendors_1099_needs_w9_date check (not w9_on_file or w9_received_on is not null)
);

comment on table public.vendors is
  'Who the practice pays, and whether they get a 1099 (0148). No tax number is kept: the W-9 is a document, and a 1099 records only the last four digits.';

drop trigger if exists vendors_updated_at on public.vendors;
create trigger vendors_updated_at before update on public.vendors
  for each row execute function public.set_updated_at();

create index if not exists vendors_active_idx on public.vendors (entity_id, active, name);

-- ── what they have billed ──────────────────────────────────
create table if not exists public.vendor_bills (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.ledger_entities(id) on delete restrict,
  vendor_id uuid not null references public.vendors(id) on delete restrict,
  number text not null default '',
  bill_date date not null,
  due_date date,
  amount numeric(14, 2) not null check (amount > 0),
  account_id uuid not null references public.ledger_accounts(id) on delete restrict,
  description text not null default '',

  status text not null default 'Awaiting approval' check (status in (
    'Awaiting approval', 'Approved', 'Scheduled', 'Paid', 'Void'
  )),
  approved_by uuid references public.staff(id) on delete set null,
  approved_at timestamptz,
  scheduled_for date,
  paid_on date,
  method text check (method is null or method in ('Check', 'ACH', 'Card', 'Cash', 'Other')),
  reference text not null default '',
  void_reason text not null default '',

  -- Where the document agent filed the paper, when it came from a folder.
  document_path text,
  schedule_id uuid,

  created_at timestamptz not null default now(),
  created_by uuid references public.staff(id) on delete set null,
  updated_at timestamptz not null default now(),

  constraint vendor_bills_approved_has_approver check (
    status not in ('Approved', 'Scheduled', 'Paid') or approved_by is not null
  ),
  constraint vendor_bills_paid_has_payment check (
    status <> 'Paid' or (paid_on is not null and method is not null)
  ),
  constraint vendor_bills_void_has_reason check (
    status <> 'Void' or btrim(void_reason) <> ''
  ),
  constraint vendor_bills_dates_in_order check (due_date is null or due_date >= bill_date)
);

comment on table public.vendor_bills is
  'A bill with a life: awaiting approval, approved, scheduled, paid (0148). Each step posts to the ledger on its own.';

drop trigger if exists vendor_bills_updated_at on public.vendor_bills;
create trigger vendor_bills_updated_at before update on public.vendor_bills
  for each row execute function public.set_updated_at();

create index if not exists vendor_bills_vendor_idx on public.vendor_bills (vendor_id, bill_date desc);
create index if not exists vendor_bills_due_idx on public.vendor_bills (due_date)
  where status in ('Approved', 'Scheduled');
create index if not exists vendor_bills_status_idx on public.vendor_bills (status);

-- A bill arriving twice from the same folder is one bill.
create unique index if not exists vendor_bills_one_per_number
  on public.vendor_bills (vendor_id, number) where number <> '';

-- ── the ones that come every month ─────────────────────────
create table if not exists public.vendor_bill_schedules (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.ledger_entities(id) on delete restrict,
  vendor_id uuid not null references public.vendors(id) on delete cascade,
  amount numeric(14, 2) not null check (amount > 0),
  account_id uuid not null references public.ledger_accounts(id) on delete restrict,
  description text not null default '',
  -- Every month by default; three for a quarterly one.
  every_months integer not null default 1 check (every_months between 1 and 12),
  day_of_month integer not null default 1 check (day_of_month between 1 and 28),
  next_due date not null,
  until date,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid references public.staff(id) on delete set null
);

comment on table public.vendor_bill_schedules is
  'Rent, software, insurance: a bill the CRM creates on the day it is due, awaiting approval like any other (0148).';

alter table public.vendor_bills
  drop constraint if exists vendor_bills_schedule_fkey;
alter table public.vendor_bills
  add constraint vendor_bills_schedule_fkey
  foreign key (schedule_id) references public.vendor_bill_schedules(id) on delete set null;

-- A schedule creates one bill per due date, however many times it runs.
--
-- Not a partial index: a null schedule_id is distinct from every other null,
-- so bills nobody scheduled are unaffected, and "on conflict" can name this
-- index - which it cannot do for a partial one.
drop index if exists vendor_bills_one_per_schedule_date;
create unique index if not exists vendor_bills_one_per_schedule_date
  on public.vendor_bills (schedule_id, bill_date);

-- ── asking before spending ─────────────────────────────────
create table if not exists public.purchase_requests (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references public.staff(id) on delete cascade,
  what text not null,
  why text not null default '',
  amount numeric(14, 2) not null check (amount > 0),
  vendor_id uuid references public.vendors(id) on delete set null,
  status text not null default 'Requested' check (status in ('Requested', 'Approved', 'Declined')),
  decided_by uuid references public.staff(id) on delete set null,
  decided_at timestamptz,
  decision_note text not null default '',
  created_at timestamptz not null default now(),

  constraint purchase_requests_decided_has_decider check (
    status = 'Requested' or decided_by is not null
  )
);

comment on table public.purchase_requests is
  'Somebody asking before spending (0148). Off unless the owner sets the amount it applies over.';

create index if not exists purchase_requests_open_idx on public.purchase_requests (status, created_at desc);

-- ── the two numbers that decide who may approve what ───────
alter table public.ledger_settings
  add column if not exists bill_approval_limit numeric(14, 2),
  add column if not exists purchase_request_over numeric(14, 2);

comment on column public.ledger_settings.bill_approval_limit is
  'Under this, whoever bills may approve a bill; over it, only an Admin (0148). Null means Admin approves everything.';
comment on column public.ledger_settings.purchase_request_over is
  'Staff ask before spending more than this (0148). Null switches purchase requests off.';

-- ── a vendor is a dimension a posting can carry ────────────
alter table public.journal_lines
  add column if not exists vendor_id uuid references public.vendors(id) on delete set null;

comment on column public.journal_lines.vendor_id is
  'Which vendor a posting is about (0148), so payables age by vendor and not only by person.';

create index if not exists journal_lines_vendor_idx on public.journal_lines (vendor_id)
  where vendor_id is not null;

-- post_journal learns the one new dimension.
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
    client_id, staff_id, counselor_id, vendor_id, office, service
  )
  select v_id,
         (l->>'account')::uuid,
         round(coalesce((l->>'debit')::numeric, 0), 2),
         round(coalesce((l->>'credit')::numeric, 0), 2),
         coalesce(l->>'memo', ''),
         nullif(l->>'client_id', '')::uuid,
         nullif(l->>'staff_id', '')::uuid,
         nullif(l->>'counselor_id', '')::uuid,
         nullif(l->>'vendor_id', '')::uuid,
         coalesce(l->>'office', ''),
         coalesce(l->>'service', '')
    from jsonb_array_elements(p_lines) l;

  return v_id;
end;
$$;

revoke all on function public.post_journal(date, text, text, uuid, text, jsonb, uuid, text, text, uuid, text, boolean) from anon, authenticated;

-- A reversal mirrors the vendor too.
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
    client_id, staff_id, counselor_id, vendor_id, office, service
  )
  select v_id, l.account_id, l.credit, l.debit, l.memo,
         l.client_id, l.staff_id, l.counselor_id, l.vendor_id, l.office, l.service
    from public.journal_lines l where l.journal_id = p_journal;

  return v_id;
end;
$$;

revoke all on function public.reverse_journal(uuid, text) from anon, authenticated;
grant execute on function public.reverse_journal(uuid, text) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- A bill approved is owed; a bill paid leaves the bank
-- ─────────────────────────────────────────────────────────────
create or replace function public.post_vendor_bill()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_vendor text;
  v_live   uuid;
begin
  if new.status = old.status then
    return new;
  end if;
  select name into v_vendor from public.vendors where id = new.vendor_id;

  -- ── approved: the practice owes it now ──
  if new.status in ('Approved', 'Scheduled', 'Paid') and old.status = 'Awaiting approval' then
    if public.ledger_live_posting('Vendor bill', new.id, 'Approved') is null then
      perform public.post_journal(
        new.bill_date,
        format('%s%s', v_vendor,
               case when coalesce(new.description, '') <> '' then ' - ' || new.description else '' end),
        'Vendor bill', new.id,
        public.ledger_next_event('Vendor bill', new.id, 'Approved'),
        jsonb_build_array(
          jsonb_build_object('account', new.account_id, 'debit', new.amount, 'vendor_id', new.vendor_id),
          jsonb_build_object('account', public.ledger_account('ap'), 'credit', new.amount, 'vendor_id', new.vendor_id)
        ),
        null, '', null, new.approved_by,
        coalesce((select name from public.staff where id = new.approved_by), '')
      );
    end if;
  end if;

  -- ── paid: what was owed leaves the bank ──
  if new.status = 'Paid' and old.status <> 'Paid' then
    if public.ledger_live_posting('Vendor bill', new.id, 'Paid') is null then
      perform public.post_journal(
        coalesce(new.paid_on, public.practice_today()),
        format('%s paid%s', v_vendor,
               case when coalesce(new.reference, '') <> '' then ', ' || coalesce(new.method, '') || ' ' || new.reference
                    else coalesce(', ' || new.method, '') end),
        'Vendor bill', new.id,
        public.ledger_next_event('Vendor bill', new.id, 'Paid'),
        jsonb_build_array(
          jsonb_build_object('account', public.ledger_account('ap'), 'debit', new.amount, 'vendor_id', new.vendor_id),
          jsonb_build_object('account', public.ledger_account('bank'), 'credit', new.amount, 'vendor_id', new.vendor_id)
        ),
        new.account_id
      );
    end if;
  end if;

  -- ── void: whatever was posted stops standing ──
  if new.status = 'Void' and old.status <> 'Void' then
    for v_live in
      select public.ledger_live_posting('Vendor bill', new.id, e)
        from unnest(array['Paid', 'Approved']) e
    loop
      if v_live is not null then
        perform public.reverse_journal(v_live, 'Bill voided: ' || new.void_reason);
      end if;
    end loop;
  end if;

  return new;
end;
$$;

comment on function public.post_vendor_bill is
  'A bill approved is owed, a bill paid leaves the bank, a bill voided is reversed (0148).';

drop trigger if exists vendor_bills_post on public.vendor_bills;
create trigger vendor_bills_post after update of status on public.vendor_bills
  for each row execute function public.post_vendor_bill();

-- ─────────────────────────────────────────────────────────────
-- Who may approve this one
-- ─────────────────────────────────────────────────────────────
create or replace function public.may_approve_bill(p_amount numeric)
returns boolean language sql stable security definer set search_path = public as $$
  select case
    when public.is_admin() then true
    when not public.staff_has_area('billing', 'edit') then false
    else coalesce(
      (select s.bill_approval_limit
         from public.ledger_settings s
         join public.ledger_entities e on e.id = s.entity_id and e.is_default), 0) >= p_amount
  end;
$$;

comment on function public.may_approve_bill is
  'Admin always; whoever bills, up to the limit the owner set (0148). No limit means Admin only.';

revoke all on function public.may_approve_bill(numeric) from anon, authenticated;
grant execute on function public.may_approve_bill(numeric) to authenticated;

create or replace function public.approve_vendor_bill(p_bill uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_bill public.vendor_bills;
begin
  select * into v_bill from public.vendor_bills where id = p_bill;
  if v_bill.id is null then
    raise exception 'There is no such bill';
  end if;
  if v_bill.status <> 'Awaiting approval' then
    raise exception 'That bill is already %', lower(v_bill.status);
  end if;
  if not public.may_approve_bill(v_bill.amount) then
    raise exception 'This one is over the limit you may approve'
      using hint = 'An Admin approves bills above the practice''s limit.';
  end if;

  update public.vendor_bills
     set status = 'Approved', approved_by = (select public.current_staff_id()), approved_at = now()
   where id = p_bill;
end;
$$;

revoke all on function public.approve_vendor_bill(uuid) from anon, authenticated;
grant execute on function public.approve_vendor_bill(uuid) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- The bills the CRM writes for itself
-- ─────────────────────────────────────────────────────────────
create or replace function public.create_due_recurring_bills(p_today date default null)
returns integer language plpgsql security definer set search_path = public as $$
declare
  v_today date := coalesce(p_today, public.practice_today());
  v_made  integer := 0;
  s       record;
begin
  for s in
    select * from public.vendor_bill_schedules
     where active and next_due <= v_today and (until is null or next_due <= until)
  loop
    insert into public.vendor_bills (
      entity_id, vendor_id, bill_date, due_date, amount, account_id, description, schedule_id
    ) values (
      s.entity_id, s.vendor_id, s.next_due,
      s.next_due + coalesce((select terms_days from public.vendors where id = s.vendor_id), 0),
      s.amount, s.account_id, s.description, s.id
    )
    on conflict (schedule_id, bill_date) do nothing;

    if found then
      v_made := v_made + 1;
    end if;

    update public.vendor_bill_schedules
       set next_due = (s.next_due + (s.every_months || ' months')::interval)::date
     where id = s.id;
  end loop;

  return v_made;
end;
$$;

comment on function public.create_due_recurring_bills is
  'Writes the bills that are due today from their schedules, awaiting approval like any other (0148). Nothing is posted until somebody looks at it.';

revoke all on function public.create_due_recurring_bills(date) from public, anon, authenticated;
grant execute on function public.create_due_recurring_bills(date) to service_role;

-- ─────────────────────────────────────────────────────────────
-- Payables, by vendor as well as by person
-- ─────────────────────────────────────────────────────────────
create or replace function public.ledger_ap_aging(p_as_of date)
returns table (
  staff_id uuid, person text, bucket text, amount numeric
) language sql stable set search_path = public as $$
  with owed as (
    select l.staff_id,
           l.vendor_id,
           j.entry_date,
           sum(l.credit) - sum(l.debit) as amount
      from public.journals j
      join public.journal_lines l on l.journal_id = j.id
     where l.account_id in (
             select a.id from public.ledger_accounts a
              join public.ledger_entities e on e.id = a.entity_id and e.is_default
              where a.role in ('contractor_payable', 'ap'))
       and j.entry_date <= p_as_of
     group by l.staff_id, l.vendor_id, j.entry_date
  ),
  /**
   * A payment clears the oldest thing owed to that person or vendor first,
   * which is what actually happens and is the only assumption that makes an
   * aging report mean anything: without it, paying this month's bill would
   * leave last month's looking unpaid.
   */
  running as (
    select o.staff_id, o.vendor_id, o.entry_date, o.amount,
           sum(o.amount) over (partition by o.staff_id, o.vendor_id
                               order by o.entry_date, o.amount) as cumulative,
           sum(o.amount) over (partition by o.staff_id, o.vendor_id) as net
      from owed o
  )
  select r.staff_id,
         coalesce(s.name, v.name, 'Not against anybody'),
         case
           when p_as_of - r.entry_date <= 30 then 'Current'
           when p_as_of - r.entry_date <= 60 then '31 to 60 days'
           when p_as_of - r.entry_date <= 90 then '61 to 90 days'
           else 'Over 90 days'
         end,
         greatest(least(r.amount, r.net - (r.cumulative - r.amount)), 0)
    from running r
    left join public.staff s on s.id = r.staff_id
    left join public.vendors v on v.id = r.vendor_id
   where r.net > 0
     and greatest(least(r.amount, r.net - (r.cumulative - r.amount)), 0) > 0
   order by 2, r.entry_date;
$$;

comment on function public.ledger_ap_aging is
  'What the practice still owes each contractor and each vendor, by how long it has been owed (0148). Payments clear the oldest first.';

revoke all on function public.ledger_ap_aging(date) from anon, authenticated;
grant execute on function public.ledger_ap_aging(date) to authenticated;

-- ── what is due, and what is late ──────────────────────────
create or replace function public.bills_due_by(p_by date)
returns table (
  id uuid, vendor text, number text, due_date date, amount numeric, status text, late boolean
) language sql stable set search_path = public as $$
  select b.id, v.name, b.number, b.due_date, b.amount, b.status,
         b.due_date is not null and b.due_date < public.practice_today()
    from public.vendor_bills b
    join public.vendors v on v.id = b.vendor_id
   where b.status in ('Awaiting approval', 'Approved', 'Scheduled')
     and (b.due_date is null or b.due_date <= p_by)
   order by b.due_date nulls last, v.name;
$$;

comment on function public.bills_due_by is
  'Bills due by a day, and whether they are already late (0148). The owner''s "due this week".';

revoke all on function public.bills_due_by(date) from anon, authenticated;
grant execute on function public.bills_due_by(date) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- Who may see and do this
-- ─────────────────────────────────────────────────────────────
alter table public.vendors               enable row level security;
alter table public.vendor_bills          enable row level security;
alter table public.vendor_bill_schedules enable row level security;
alter table public.purchase_requests     enable row level security;

do $$
declare t text;
begin
  foreach t in array array['vendors', 'vendor_bills', 'vendor_bill_schedules'] loop
    execute format('drop policy if exists %I_read on public.%I', t, t);
    execute format(
      'create policy %I_read on public.%I for select to authenticated using ((select public.may_read_books()))',
      t, t);
    execute format('drop policy if exists %I_write on public.%I', t, t);
  end loop;
end $$;

-- A bill is entered and chased by whoever bills; approving it is what the
-- threshold decides, and that is enforced in approve_vendor_bill.
create policy vendors_write on public.vendors for all to authenticated
  using ((select public.may_read_books())) with check ((select public.may_read_books()));
create policy vendor_bills_write on public.vendor_bills for all to authenticated
  using ((select public.may_read_books())) with check ((select public.may_read_books()));
create policy vendor_bill_schedules_write on public.vendor_bill_schedules for all to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));

-- A purchase request is somebody's own, until an Admin decides it.
drop policy if exists purchase_requests_read on public.purchase_requests;
create policy purchase_requests_read on public.purchase_requests for select to authenticated
  using ((select public.is_admin()) or staff_id = (select public.current_staff_id()));

drop policy if exists purchase_requests_insert on public.purchase_requests;
create policy purchase_requests_insert on public.purchase_requests for insert to authenticated
  with check (staff_id = (select public.current_staff_id()) and status = 'Requested');

drop policy if exists purchase_requests_decide on public.purchase_requests;
create policy purchase_requests_decide on public.purchase_requests for update to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));

grant select, insert, update, delete on public.vendors               to authenticated;
grant select, insert, update, delete on public.vendor_bills          to authenticated;
grant select, insert, update, delete on public.vendor_bill_schedules to authenticated;
grant select, insert, update          on public.purchase_requests    to authenticated;

-- ── the automated accounts stay read-only ──────────────────
do $$
declare r record;
begin
  for r in
    select c.oid::regclass as t
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity
  loop
    perform public.apply_system_read_only(r.t);
  end loop;
end $$;
