-- Zion Vocational Rehab CRM — the ledger (ERP brief, E1)
--
-- The practice already records everything that happens: an authorization, a
-- billing item submitted, a warrant paid, a contractor statement approved, a
-- claim for mileage. What it has never had is the other half of each of those
-- - what it did to the books - so the year is closed by a person reading the
-- CRM and typing into something else.
--
-- This is that other half. A chart of accounts, double-entry journals, and
-- three rules the database keeps rather than trusting:
--
--   Debits equal credits. Not checked on save in some code path somebody
--   will later forget: a deferred constraint, so an unbalanced entry cannot
--   be committed by anybody, through any route, ever.
--
--   The ledger is append-only. A mistake is not edited; it is reversed with
--   a reason and posted again. Books that can be quietly rewritten are not
--   books, and the first time the CPA asks "what changed in March" the
--   answer has to be a list, not a shrug.
--
--   A closed month refuses postings. Admin can reopen it, and the reopening
--   is written down.
--
-- The chart is rows, not code. The practice and its CPA will change the
-- account names and add accounts; neither of them should need a deploy. The
-- same is true of which revenue account a service bills to and which expense
-- account a claim lands in: those are two small map tables, so renaming a
-- service does not mean editing a posting function.
--
-- Entities (one, Zion Voc Rehab) are here from the start. E5 adds the PCA by
-- adding a row and a chart, and that is only cheap if every posting carried
-- an entity from the first day. Retro-fitting a dimension onto a year of
-- postings is the rebuild the brief says to avoid.

-- ── the access log learns one more subject ─────────────────
--
-- Closing a month, reopening one, importing a statement and reconciling it
-- are all read later by somebody asking who did this. The log's subjects are
-- a closed list on purpose, and the list is rebuilt in full here rather than
-- from memory: 0059 lost 'Staff document' by rebuilding it from the original
-- four, which the schema accepted happily.
alter table public.access_log drop constraint if exists access_log_subject_check;
alter table public.access_log add constraint access_log_subject_check
  check (subject in (
    'Client restricted details', 'Client intake', 'Contractor tax number', 'Signed tax form',
    'Staff document', 'Records request', 'Staff personal details', 'The books'));

-- ── who the books belong to ────────────────────────────────
create table if not exists public.ledger_entities (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  -- The one new postings default to, so nothing has to name it.
  is_default boolean not null default false,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

comment on table public.ledger_entities is
  'Whose books these are (0141). One today; E5 adds the PCA as a row, not a rebuild.';

create unique index if not exists ledger_entities_one_default
  on public.ledger_entities (is_default) where is_default;

insert into public.ledger_entities (name, is_default)
values ('Zion Voc Rehab', true)
on conflict (name) do nothing;

-- ── the chart of accounts ──────────────────────────────────
create table if not exists public.ledger_accounts (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.ledger_entities(id) on delete restrict,
  code text not null,
  name text not null,
  kind text not null check (kind in ('Asset', 'Liability', 'Equity', 'Revenue', 'Expense')),

  /**
   * What the CRM posts here automatically, where it is one particular
   * account rather than one of many.
   *
   * A posting function that found its account by name would break the first
   * time somebody renamed "Accounts receivable (USOR)", and silently: the
   * entry would go somewhere else or nowhere. A role is a name the practice
   * does not own.
   */
  role text,

  -- Never deleted once it holds postings; retired instead.
  active boolean not null default true,
  note text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  unique (entity_id, code)
);

comment on table public.ledger_accounts is
  'The chart of accounts (0141). Rows, because the practice and its CPA change these and software should not need a deploy to let them.';
comment on column public.ledger_accounts.role is
  'The account the CRM posts to for a particular kind of event. A name the practice does not own, so renaming an account cannot break a posting.';

create unique index if not exists ledger_accounts_one_per_role
  on public.ledger_accounts (entity_id, role) where role is not null;

create index if not exists ledger_accounts_kind_idx
  on public.ledger_accounts (entity_id, kind, code);

drop trigger if exists ledger_accounts_updated_at on public.ledger_accounts;
create trigger ledger_accounts_updated_at before update on public.ledger_accounts
  for each row execute function public.set_updated_at();

-- ── how the books are kept ─────────────────────────────────
create table if not exists public.ledger_settings (
  entity_id uuid primary key references public.ledger_entities(id) on delete cascade,
  -- Nothing posts before this day. The books open once.
  books_start date not null,
  /**
   * Which Profit & Loss the practice reads by default.
   *
   * Cash, because USOR pays on warrant and the owner's question all year is
   * "what came in". Accrual is the same ledger read differently, not a
   * second set of books, so it is a toggle on the report rather than a
   * setting that changes what is posted. The CPA confirms this before the
   * books open (owner, 5 Oct 2026).
   */
  basis text not null default 'Cash' check (basis in ('Cash', 'Accrual')),
  updated_at timestamptz not null default now()
);

comment on table public.ledger_settings is
  'When the books open and which basis the reports default to (0141).';

insert into public.ledger_settings (entity_id, books_start, basis)
select id, date '2027-01-01', 'Cash' from public.ledger_entities where is_default
on conflict (entity_id) do nothing;

drop trigger if exists ledger_settings_updated_at on public.ledger_settings;
create trigger ledger_settings_updated_at before update on public.ledger_settings
  for each row execute function public.set_updated_at();

-- ── the entries ────────────────────────────────────────────
create table if not exists public.journals (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.ledger_entities(id) on delete restrict,
  entry_date date not null,
  memo text not null default '',

  /**
   * Where this came from, and the one event in its life that caused it.
   *
   * A billing item posts twice - revenue when it is submitted, cash when it
   * is paid - so the source on its own is not enough to tell one posting
   * from the other. Source, id and event together are unique, which is how
   * "every source event posts exactly once" is a rule rather than a hope.
   */
  source_kind text not null check (source_kind in (
    'Billing item', 'Contractor statement', 'Contractor payment',
    'Expense claim', 'Bank transaction', 'Manual', 'Opening balance', 'Reversal'
  )),
  source_id uuid,
  source_event text not null default '',

  -- A correction: the entry this one undoes, and why.
  reverses_id uuid references public.journals(id) on delete restrict,
  reason text not null default '',
  attachment_path text,

  /**
   * Which revenue or expense account a movement of cash belongs to.
   *
   * A payment credits Accounts receivable, not revenue, which is right and
   * is also why a cash-basis Profit & Loss cannot be read off the accounts
   * alone. Carrying the classification on the entry means the cash report
   * knows what the money was for without inferring it, and both bases come
   * from one ledger rather than two.
   */
  cash_class_account_id uuid references public.ledger_accounts(id) on delete restrict,

  created_by uuid references public.staff(id) on delete set null,
  created_by_name text not null default '',
  created_at timestamptz not null default now()
);

comment on table public.journals is
  'One double-entry posting (0141). Append-only: a mistake is reversed with a reason and posted again.';
comment on column public.journals.cash_class_account_id is
  'The revenue or expense account a cash movement belongs to, so a cash-basis report does not have to guess.';

create unique index if not exists journals_one_per_source_event
  on public.journals (source_kind, source_id, source_event)
  where source_id is not null;

create index if not exists journals_date_idx on public.journals (entity_id, entry_date);
create index if not exists journals_source_idx on public.journals (source_kind, source_id);

create table if not exists public.journal_lines (
  id uuid primary key default gen_random_uuid(),
  journal_id uuid not null references public.journals(id) on delete cascade,
  account_id uuid not null references public.ledger_accounts(id) on delete restrict,
  debit numeric(14, 2) not null default 0 check (debit >= 0),
  credit numeric(14, 2) not null default 0 check (credit >= 0),
  memo text not null default '',

  -- What a report slices by. All optional: a line about rent is about
  -- nobody in particular.
  client_id uuid references public.clients(id) on delete set null,
  staff_id uuid references public.staff(id) on delete set null,
  counselor_id uuid references public.counselors(id) on delete set null,
  office text not null default '',
  service text not null default '',

  constraint journal_lines_one_side check (
    (debit > 0 and credit = 0) or (credit > 0 and debit = 0)
  )
);

comment on table public.journal_lines is
  'The two or more sides of a posting, with the dimensions reports group by (0141).';

create index if not exists journal_lines_journal_idx on public.journal_lines (journal_id);
create index if not exists journal_lines_account_idx on public.journal_lines (account_id);
create index if not exists journal_lines_client_idx on public.journal_lines (client_id) where client_id is not null;
create index if not exists journal_lines_staff_idx on public.journal_lines (staff_id) where staff_id is not null;

-- ── which account a service bills to, and a claim lands in ──
create table if not exists public.ledger_revenue_map (
  service text primary key references public.billing_service_rules(service) on update cascade on delete cascade,
  account_id uuid not null references public.ledger_accounts(id) on delete restrict
);

comment on table public.ledger_revenue_map is
  'The revenue account each service bills to (0141). A row, so renaming a service is not a code change.';

create table if not exists public.ledger_expense_map (
  category text primary key references public.expense_categories(key) on update cascade on delete cascade,
  account_id uuid not null references public.ledger_accounts(id) on delete restrict
);

comment on table public.ledger_expense_map is
  'The expense account each claim category lands in (0141).';

-- ── the months that are shut ───────────────────────────────
create table if not exists public.ledger_periods (
  entity_id uuid not null references public.ledger_entities(id) on delete cascade,
  month date not null,
  closed_at timestamptz not null default now(),
  closed_by uuid references public.staff(id) on delete set null,
  closed_by_name text not null default '',
  note text not null default '',
  primary key (entity_id, month),
  constraint ledger_periods_is_a_month check (date_trunc('month', month)::date = month)
);

comment on table public.ledger_periods is
  'Closed months (0141). A posting dated inside one is refused; reopening is Admin only and is written down in the access log.';

-- ─────────────────────────────────────────────────────────────
-- Debits equal credits
--
-- Deferred, so a function may insert a journal and then its lines and still
-- be checked at commit. Nothing can commit an unbalanced entry: not a
-- posting function, not a migration, not somebody at a SQL prompt.
-- ─────────────────────────────────────────────────────────────
create or replace function public.ledger_assert_balanced(p_journal uuid)
returns void language plpgsql as $$
declare
  v_debit  numeric;
  v_credit numeric;
  v_lines  integer;
begin
  -- Nothing left to balance: the entry itself has gone.
  if not exists (select 1 from public.journals where id = p_journal) then
    return;
  end if;

  select coalesce(sum(debit), 0), coalesce(sum(credit), 0), count(*)
    into v_debit, v_credit, v_lines
    from public.journal_lines where journal_id = p_journal;

  if v_lines < 2 then
    raise exception 'A posting has at least two sides; this one has %', v_lines
      using hint = 'Every entry debits something and credits something.';
  end if;

  if v_debit <> v_credit then
    raise exception 'Debits (%) and credits (%) are not equal', v_debit, v_credit
      using hint = 'An entry that does not balance is not a posting.';
  end if;
end;
$$;

comment on function public.ledger_assert_balanced is
  'Raises unless the posting has at least two sides and balances (0141).';

create or replace function public.ledger_lines_balanced()
returns trigger language plpgsql as $$
begin
  perform public.ledger_assert_balanced(coalesce(new.journal_id, old.journal_id));
  return null;
end;
$$;

create or replace function public.ledger_journal_balanced()
returns trigger language plpgsql as $$
begin
  perform public.ledger_assert_balanced(new.id);
  return null;
end;
$$;

drop trigger if exists journal_lines_balance on public.journal_lines;
create constraint trigger journal_lines_balance
  after insert or update or delete on public.journal_lines
  deferrable initially deferred
  for each row execute function public.ledger_lines_balanced();

drop trigger if exists journals_balance on public.journals;
create constraint trigger journals_balance
  after insert on public.journals
  deferrable initially deferred
  for each row execute function public.ledger_journal_balanced();

-- ─────────────────────────────────────────────────────────────
-- Append-only
-- ─────────────────────────────────────────────────────────────
create or replace function public.ledger_append_only()
returns trigger language plpgsql as $$
begin
  raise exception 'The ledger is append-only'
    using hint = 'Reverse the entry with a reason and post it again; do not change what was posted.';
end;
$$;

comment on function public.ledger_append_only is
  'Refuses any change to a posting (0141). Corrections reverse and repost.';

drop trigger if exists journals_append_only on public.journals;
create trigger journals_append_only before update or delete on public.journals
  for each row execute function public.ledger_append_only();

drop trigger if exists journal_lines_append_only on public.journal_lines;
create trigger journal_lines_append_only before update or delete on public.journal_lines
  for each row execute function public.ledger_append_only();

-- ─────────────────────────────────────────────────────────────
-- Before the books opened, or into a month that is shut
-- ─────────────────────────────────────────────────────────────
create or replace function public.ledger_period_open()
returns trigger language plpgsql as $$
declare
  v_start date;
begin
  select books_start into v_start
    from public.ledger_settings where entity_id = new.entity_id;

  if v_start is null then
    raise exception 'These books have no start date yet'
      using hint = 'Set the day the books open before anything is posted.';
  end if;

  -- An opening balance is dated the day the books open and is the one entry
  -- allowed to sit on that line rather than after it.
  if new.entry_date < v_start then
    raise exception 'The books open on % and this is dated %', v_start, new.entry_date
      using hint = 'Nothing is posted before the books open.';
  end if;

  if exists (
    select 1 from public.ledger_periods
     where entity_id = new.entity_id
       and month = date_trunc('month', new.entry_date)::date
  ) then
    raise exception '% is closed', to_char(new.entry_date, 'FMMonth YYYY')
      using hint = 'Reopen the month first; reopening is Admin only and is written down.';
  end if;

  return new;
end;
$$;

comment on function public.ledger_period_open is
  'Refuses a posting dated before the books open or inside a closed month (0141).';

drop trigger if exists journals_period_open on public.journals;
create trigger journals_period_open before insert on public.journals
  for each row execute function public.ledger_period_open();

-- ─────────────────────────────────────────────────────────────
-- An account with postings is retired, not deleted
-- ─────────────────────────────────────────────────────────────
create or replace function public.ledger_account_in_use()
returns trigger language plpgsql as $$
begin
  if exists (select 1 from public.journal_lines where account_id = old.id) then
    raise exception 'This account holds postings'
      using hint = 'Mark it inactive instead; deleting it would take the entries with it.';
  end if;
  return old;
end;
$$;

drop trigger if exists ledger_accounts_in_use on public.ledger_accounts;
create trigger ledger_accounts_in_use before delete on public.ledger_accounts
  for each row execute function public.ledger_account_in_use();

-- ─────────────────────────────────────────────────────────────
-- Who may see the books, and who may change them
--
-- The brief: every ledger screen is Admin and Billing (view), Admin (post,
-- close). Postings arrive through security-definer functions, so there is no
-- insert policy on journals at all - not even for Admin. The only way into
-- the ledger is a posting function that balances the entry.
-- ─────────────────────────────────────────────────────────────
alter table public.ledger_entities    enable row level security;
alter table public.ledger_accounts    enable row level security;
alter table public.ledger_settings    enable row level security;
alter table public.ledger_revenue_map enable row level security;
alter table public.ledger_expense_map enable row level security;
alter table public.journals           enable row level security;
alter table public.journal_lines      enable row level security;
alter table public.ledger_periods     enable row level security;

/**
 * Who reads the books.
 *
 * Admin, Billing (by role or by grant), and anyone given Insights - which is
 * how the CPA gets in: a read-only grant, logged like every other.
 */
create or replace function public.may_read_books()
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_admin()
      or public.staff_has_area('billing')
      or public.staff_has_area('insights');
$$;

comment on function public.may_read_books is
  'Admin, Billing, or anyone granted Insights - which is how a CPA is let in (0141).';

revoke all on function public.may_read_books() from anon, authenticated;
grant execute on function public.may_read_books() to authenticated;

do $$
declare t text;
begin
  foreach t in array array[
    'ledger_entities', 'ledger_accounts', 'ledger_settings',
    'ledger_revenue_map', 'ledger_expense_map',
    'journals', 'journal_lines', 'ledger_periods'
  ] loop
    execute format('drop policy if exists %I_read on public.%I', t, t);
    execute format(
      'create policy %I_read on public.%I for select to authenticated using ((select public.may_read_books()))',
      t, t);
  end loop;
end $$;

-- The chart, the maps, the entities and the settings are Admin's to change.
do $$
declare t text;
begin
  foreach t in array array[
    'ledger_entities', 'ledger_accounts', 'ledger_settings',
    'ledger_revenue_map', 'ledger_expense_map'
  ] loop
    execute format('drop policy if exists %I_write on public.%I', t, t);
    execute format(
      'create policy %I_write on public.%I for all to authenticated '
      'using ((select public.is_admin())) with check ((select public.is_admin()))',
      t, t);
  end loop;
end $$;

grant select, insert, update, delete on public.ledger_entities    to authenticated;
grant select, insert, update, delete on public.ledger_accounts    to authenticated;
grant select, insert, update, delete on public.ledger_settings    to authenticated;
grant select, insert, update, delete on public.ledger_revenue_map to authenticated;
grant select, insert, update, delete on public.ledger_expense_map to authenticated;
grant select on public.journals       to authenticated;
grant select on public.journal_lines  to authenticated;
grant select on public.ledger_periods to authenticated;

-- ─────────────────────────────────────────────────────────────
-- The chart itself
--
-- A small nonprofit-style service chart, as the brief asks, with one revenue
-- account per service the practice actually bills - because "revenue by
-- service" is the owner's question, and a single Revenue account cannot
-- answer it. The CPA confirms names and codes before the books open; none of
-- this needs a deploy to change.
-- ─────────────────────────────────────────────────────────────
insert into public.ledger_accounts (entity_id, code, name, kind, role, note)
select e.id, a.code, a.name, a.kind, a.role, a.note
  from public.ledger_entities e
 cross join (values
  ('1000', 'Bank',                        'Asset',     'bank',               'The operating account. Statements are imported here.'),
  ('1010', 'Undeposited funds',           'Asset',     'undeposited',        'A warrant in hand and not yet at the bank.'),
  ('1100', 'Accounts receivable (USOR)',  'Asset',     'ar',                 'Billed and not yet paid.'),
  ('2000', 'Accounts payable',            'Liability', 'ap',                 'Vendor bills owed (E3).'),
  ('2100', 'Contractor payables',         'Liability', 'contractor_payable', 'Approved statements and claims not yet paid out.'),
  ('3000', 'Owner equity',                'Equity',    'equity',             ''),
  ('3100', 'Owner draw',                  'Equity',    'owner_draw',         ''),
  ('4010', 'Job Development',             'Revenue',   null,                 ''),
  ('4011', 'Job Development + HQ',        'Revenue',   null,                 ''),
  ('4020', 'Job Coaching',                'Revenue',   null,                 'The only service that recurs monthly.'),
  ('4030', 'Job Placement',               'Revenue',   null,                 ''),
  ('4031', 'Job Placement (SE)',          'Revenue',   null,                 ''),
  ('4040', 'WSA Tier 1',                  'Revenue',   null,                 ''),
  ('4041', 'WSA Tier 2',                  'Revenue',   null,                 ''),
  ('4050', 'Life Skills',                 'Revenue',   null,                 ''),
  ('4051', 'Job Readiness',               'Revenue',   null,                 ''),
  ('4052', 'CRP Group Training',          'Revenue',   null,                 ''),
  ('4053', 'Supported Employment',        'Revenue',   null,                 ''),
  ('4060', 'Job Search',                  'Revenue',   null,                 ''),
  ('4090', 'Other service revenue',       'Revenue',   'revenue_other',      'Where a service with no account of its own bills, so nothing is ever unposted.'),
  ('5000', 'Contractor cost',             'Expense',   'contractor_cost',    ''),
  ('5100', 'Payroll',                     'Expense',   'payroll',            ''),
  ('5200', 'Mileage',                     'Expense',   null,                 'Claims at the rate on the day driven.'),
  ('5210', 'Travel - parking and tolls',  'Expense',   null,                 ''),
  ('5300', 'Software',                    'Expense',   null,                 ''),
  ('5400', 'Rent',                        'Expense',   null,                 ''),
  ('5500', 'Insurance',                   'Expense',   null,                 ''),
  ('5600', 'Professional fees',           'Expense',   null,                 'Accounting, legal.'),
  ('5650', 'Training',                    'Expense',   null,                 ''),
  ('5700', 'Office',                      'Expense',   null,                 ''),
  ('5750', 'Phone',                       'Expense',   null,                 ''),
  ('5900', 'Other',                       'Expense',   'expense_other',      'Where a claim with no account of its own lands.')
) as a(code, name, kind, role, note)
 where e.is_default
on conflict (entity_id, code) do nothing;

-- Which revenue account each service bills to.
insert into public.ledger_revenue_map (service, account_id)
select m.service, a.id
  from (values
    ('Job Development',                '4010'),
    ('Job Development + HQ Indicator', '4011'),
    ('Job Coaching',                   '4020'),
    ('Job Placement',                  '4030'),
    ('Job Placement (SE)',             '4031'),
    ('WSA Tier 1',                     '4040'),
    ('WSA Tier 2',                     '4041'),
    ('Life Skills',                    '4050'),
    ('Job Readiness',                  '4051'),
    ('CRP Group Training',             '4052'),
    ('Supported Employment',           '4053'),
    ('Job Search',                     '4060'),
    ('Other',                          '4090')
  ) as m(service, code)
  join public.ledger_accounts a on a.code = m.code
  join public.ledger_entities e on e.id = a.entity_id and e.is_default
 where exists (select 1 from public.billing_service_rules r where r.service = m.service)
on conflict (service) do nothing;

-- Which expense account each claim category lands in.
insert into public.ledger_expense_map (category, account_id)
select m.category, a.id
  from (values
    ('mileage',  '5200'),
    ('parking',  '5210'),
    ('tolls',    '5210'),
    ('supplies', '5700'),
    ('training', '5650'),
    ('phone',    '5750'),
    ('other',    '5900')
  ) as m(category, code)
  join public.ledger_accounts a on a.code = m.code
  join public.ledger_entities e on e.id = a.entity_id and e.is_default
 where exists (select 1 from public.expense_categories c where c.key = m.category)
on conflict (category) do nothing;
