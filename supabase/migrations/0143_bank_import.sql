-- Zion Vocational Rehab CRM — bank statements, and reconciling them (E1)
--
-- The one place an outside system touches the books, and deliberately the
-- smallest one: the owner downloads a statement and uploads it. No live bank
-- link, no credentials in the CRM, nothing that can move money. The brief is
-- explicit about that and it is also the right shape - a system that can only
-- read a file somebody chose to give it has a very short list of things it
-- can do wrong.
--
-- What reconciliation is for: the ledger says what the practice believes
-- happened and the statement says what the bank did. Where they differ, one
-- of them is wrong, and the whole point is to find out which before the year
-- is closed. So a statement cannot be marked reconciled while a difference
-- remains. Not warned about - refused. A reconciliation that can be waved
-- through is a tick-box, and the first year-end that depends on it is the
-- year-end that discovers it was never true.
--
-- Deposits are why Undeposited funds exists. A warrant is paid, which is one
-- event, and banked, which is another, often days apart. The statement shows
-- the second. Matching a deposit moves the money from Undeposited to Bank,
-- and the two events stay two events.

-- ── the accounts statements come from ──────────────────────
create table if not exists public.bank_accounts (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.ledger_entities(id) on delete restrict,
  -- The ledger account this is the real-world counterpart of.
  account_id uuid not null references public.ledger_accounts(id) on delete restrict,
  name text not null,
  -- Enough to tell two accounts apart on a screen, and no more. The full
  -- number is not something the CRM needs in order to read a statement.
  last4 text not null default '',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (entity_id, name)
);

comment on table public.bank_accounts is
  'The bank accounts statements are imported for (0143). Last four digits only; the CRM never needs the number.';

create table if not exists public.bank_statements (
  id uuid primary key default gen_random_uuid(),
  bank_account_id uuid not null references public.bank_accounts(id) on delete cascade,
  period_start date not null,
  period_end date not null,
  opening_balance numeric(14, 2) not null,
  closing_balance numeric(14, 2) not null,
  imported_at timestamptz not null default now(),
  imported_by uuid references public.staff(id) on delete set null,
  reconciled_at timestamptz,
  reconciled_by uuid references public.staff(id) on delete set null,
  note text not null default '',
  unique (bank_account_id, period_start, period_end),
  constraint bank_statements_dates_in_order check (period_end >= period_start)
);

comment on table public.bank_statements is
  'One statement, with the balance it opened and closed on (0143). Reconciled only when the ledger agrees with both.';

create table if not exists public.bank_transactions (
  id uuid primary key default gen_random_uuid(),
  statement_id uuid not null references public.bank_statements(id) on delete cascade,
  posted_on date not null,
  description text not null default '',
  -- Signed the way a statement reads: money in positive, money out negative.
  amount numeric(14, 2) not null check (amount <> 0),
  -- The bank's own id for the line, where the file has one. It is what makes
  -- importing the same statement twice harmless.
  external_id text not null default '',

  journal_id uuid references public.journals(id) on delete set null,
  status text not null default 'Unmatched'
    check (status in ('Unmatched', 'Matched', 'Ignored')),
  ignored_reason text not null default '',
  decided_by uuid references public.staff(id) on delete set null,
  decided_at timestamptz,

  constraint bank_transactions_matched_has_posting check (
    status <> 'Matched' or journal_id is not null
  ),
  constraint bank_transactions_ignored_has_reason check (
    status <> 'Ignored' or btrim(ignored_reason) <> ''
  )
);

comment on table public.bank_transactions is
  'The lines on a statement, each either matched to a posting or ignored with a reason (0143).';

create index if not exists bank_transactions_statement_idx
  on public.bank_transactions (statement_id, posted_on);
create unique index if not exists bank_transactions_one_per_external_id
  on public.bank_transactions (statement_id, external_id) where external_id <> '';

-- ── who may see and do this ────────────────────────────────
alter table public.bank_accounts     enable row level security;
alter table public.bank_statements   enable row level security;
alter table public.bank_transactions enable row level security;

do $$
declare t text;
begin
  foreach t in array array['bank_accounts', 'bank_statements', 'bank_transactions'] loop
    execute format('drop policy if exists %I_read on public.%I', t, t);
    execute format(
      'create policy %I_read on public.%I for select to authenticated using ((select public.may_read_books()))',
      t, t);
  end loop;
end $$;

drop policy if exists bank_accounts_write on public.bank_accounts;
create policy bank_accounts_write on public.bank_accounts for all to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));

grant select, insert, update, delete on public.bank_accounts to authenticated;
grant select on public.bank_statements   to authenticated;
grant select on public.bank_transactions to authenticated;

-- ─────────────────────────────────────────────────────────────
-- Importing a statement
--
-- The file is read in the app - CSV and OFX are text formats and parsing
-- them in SQL would be a party trick - and arrives here as rows. Importing
-- the same file twice adds nothing: lines with the bank's own id are matched
-- on it, and a statement for a period already imported is refused rather
-- than duplicated.
-- ─────────────────────────────────────────────────────────────
create or replace function public.import_bank_statement(
  p_bank_account uuid,
  p_period_start date,
  p_period_end date,
  p_opening numeric,
  p_closing numeric,
  p_rows jsonb
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id    uuid;
  v_added integer;
begin
  if not public.is_admin() then
    raise exception 'Only Admin imports a bank statement';
  end if;

  select id into v_id from public.bank_statements
   where bank_account_id = p_bank_account
     and period_start = p_period_start and period_end = p_period_end;

  if v_id is null then
    insert into public.bank_statements (
      bank_account_id, period_start, period_end, opening_balance, closing_balance, imported_by
    ) values (
      p_bank_account, p_period_start, p_period_end, p_opening, p_closing,
      (select public.current_staff_id())
    )
    returning id into v_id;
  elsif (select reconciled_at from public.bank_statements where id = v_id) is not null then
    raise exception 'That statement is reconciled'
      using hint = 'A reconciled statement is a closed question; import the next one.';
  end if;

  insert into public.bank_transactions (statement_id, posted_on, description, amount, external_id)
  select v_id,
         (r->>'posted_on')::date,
         coalesce(r->>'description', ''),
         round((r->>'amount')::numeric, 2),
         coalesce(r->>'external_id', '')
    from jsonb_array_elements(p_rows) r
   where coalesce((r->>'amount')::numeric, 0) <> 0
     -- A line the bank gives an id to is imported once. A line without one
     -- is matched on the three things a statement always has, which is not
     -- perfect and is better than importing March twice.
     and not exists (
       select 1 from public.bank_transactions t
        where t.statement_id = v_id
          and ((coalesce(r->>'external_id', '') <> '' and t.external_id = r->>'external_id')
            or (coalesce(r->>'external_id', '') = ''
                and t.posted_on = (r->>'posted_on')::date
                and t.amount = round((r->>'amount')::numeric, 2)
                and t.description = coalesce(r->>'description', '')))
     );
  get diagnostics v_added = row_count;

  perform public.log_access('The books', null, null,
    format('imported %s lines of the statement to %s', v_added, p_period_end));

  return v_id;
end;
$$;

comment on function public.import_bank_statement is
  'Takes the rows read from a CSV or OFX file and adds the ones not already there (0143). Admin only.';

revoke all on function public.import_bank_statement(uuid, date, date, numeric, numeric, jsonb) from anon, authenticated;
grant execute on function public.import_bank_statement(uuid, date, date, numeric, numeric, jsonb) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- What a line probably is
--
-- Suggestions, not decisions. The practice confirms every one, because a
-- ledger that guesses and is usually right is worse than one that asks: the
-- wrong guess is invisible and the question is not.
-- ─────────────────────────────────────────────────────────────
create or replace function public.bank_suggestions(p_statement uuid)
returns table (
  transaction_id uuid,
  kind text,
  why text,
  account_id uuid,
  journal_id uuid
) language sql stable set search_path = public as $$
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
             then 'Warrants paid and not yet banked come to ' || to_char((select balance from undeposited), 'FM999999990.00')
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
$$;

comment on function public.bank_suggestions is
  'What each unmatched line on a statement probably is, for a person to confirm (0143).';

revoke all on function public.bank_suggestions(uuid) from anon, authenticated;
grant execute on function public.bank_suggestions(uuid) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- Settling a line
--
-- Three ways, and one shape: either the line is a posting that already
-- exists, or it is one the statement has just told us about, or it is
-- nothing (a fee the practice has decided to ignore, a line that belongs to
-- a statement already reconciled). All three are written down with who did
-- it, because "why is this matched to that" is a question somebody asks a
-- year later.
-- ─────────────────────────────────────────────────────────────
create or replace function public.match_bank_transaction(p_transaction uuid, p_journal uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_tx     public.bank_transactions;
  v_amount numeric;
begin
  if not public.is_admin() then
    raise exception 'Only Admin matches a statement line';
  end if;

  select * into v_tx from public.bank_transactions where id = p_transaction;
  if v_tx.id is null then
    raise exception 'There is no such statement line';
  end if;
  if (select reconciled_at from public.bank_statements where id = v_tx.statement_id) is not null then
    raise exception 'That statement is reconciled';
  end if;

  -- What the posting did to the bank, read as the statement would read it.
  select coalesce(sum(l.debit) - sum(l.credit), 0) into v_amount
    from public.journal_lines l
    join public.ledger_accounts a on a.id = l.account_id
    join public.bank_accounts b on b.account_id = a.id
   where l.journal_id = p_journal;

  if v_amount <> v_tx.amount then
    raise exception 'The posting moves % and the statement line is %', v_amount, v_tx.amount
      using hint = 'Matching two different numbers is how a reconciliation comes out right and means nothing.';
  end if;

  update public.bank_transactions
     set journal_id = p_journal, status = 'Matched',
         decided_by = (select public.current_staff_id()), decided_at = now()
   where id = p_transaction;
end;
$$;

/**
 * A line the ledger did not know about: post it and match it in one go.
 *
 * The direction comes from the statement, not from the person: money in
 * debits the bank, money out credits it. Choosing the account is the only
 * judgement left, which is the only part a person is better at.
 */
create or replace function public.post_bank_transaction(
  p_transaction uuid,
  p_account uuid,
  p_memo text default ''
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_tx      public.bank_transactions;
  v_bank    uuid;
  v_amount  numeric;
  v_journal uuid;
  v_class   uuid;
  v_kind    text;
begin
  if not public.is_admin() then
    raise exception 'Only Admin posts a statement line';
  end if;

  select * into v_tx from public.bank_transactions where id = p_transaction;
  if v_tx.id is null then
    raise exception 'There is no such statement line';
  end if;
  if v_tx.status <> 'Unmatched' then
    raise exception 'That line is already settled';
  end if;
  if (select reconciled_at from public.bank_statements where id = v_tx.statement_id) is not null then
    raise exception 'That statement is reconciled';
  end if;

  select a.account_id into v_bank
    from public.bank_statements s
    join public.bank_accounts a on a.id = s.bank_account_id
   where s.id = v_tx.statement_id;

  v_amount := abs(v_tx.amount);
  select kind into v_kind from public.ledger_accounts where id = p_account;
  -- Only a revenue or expense account classifies cash; moving money between
  -- two of the practice's own accounts is not income or cost.
  v_class := case when v_kind in ('Revenue', 'Expense') then p_account else null end;

  v_journal := public.post_journal(
    v_tx.posted_on,
    coalesce(nullif(btrim(p_memo), ''), v_tx.description),
    'Bank transaction', v_tx.id, 'Posted',
    case when v_tx.amount > 0 then
      jsonb_build_array(
        jsonb_build_object('account', v_bank, 'debit', v_amount),
        jsonb_build_object('account', p_account, 'credit', v_amount))
    else
      jsonb_build_array(
        jsonb_build_object('account', p_account, 'debit', v_amount),
        jsonb_build_object('account', v_bank, 'credit', v_amount))
    end,
    v_class, '', null,
    (select public.current_staff_id()),
    coalesce((select name from public.staff where id = (select public.current_staff_id())), '')
  );

  if v_journal is null then
    raise exception 'The books are not open on %', v_tx.posted_on
      using hint = 'A statement line from before the books opened is ignored, not posted.';
  end if;

  update public.bank_transactions
     set journal_id = v_journal, status = 'Matched',
         decided_by = (select public.current_staff_id()), decided_at = now()
   where id = p_transaction;

  return v_journal;
end;
$$;

create or replace function public.ignore_bank_transaction(p_transaction uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    raise exception 'Only Admin sets a statement line aside';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'Say why this line is being set aside';
  end if;

  update public.bank_transactions
     set status = 'Ignored', ignored_reason = p_reason, journal_id = null,
         decided_by = (select public.current_staff_id()), decided_at = now()
   where id = p_transaction
     and status <> 'Matched';

  if not found then
    raise exception 'That line is matched to a posting'
      using hint = 'A matched line is already accounted for; it cannot also be set aside.';
  end if;
end;
$$;

comment on function public.match_bank_transaction is
  'Ties a statement line to a posting that already exists, refusing it if the two amounts differ (0143).';
comment on function public.post_bank_transaction is
  'Posts a statement line the ledger did not know about and matches it (0143). Direction from the statement, account from a person.';
comment on function public.ignore_bank_transaction is
  'Sets a statement line aside with a reason (0143).';

revoke all on function public.match_bank_transaction(uuid, uuid) from anon, authenticated;
revoke all on function public.post_bank_transaction(uuid, uuid, text) from anon, authenticated;
revoke all on function public.ignore_bank_transaction(uuid, text) from anon, authenticated;
grant execute on function public.match_bank_transaction(uuid, uuid) to authenticated;
grant execute on function public.post_bank_transaction(uuid, uuid, text) to authenticated;
grant execute on function public.ignore_bank_transaction(uuid, text) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- Reconciling, which cannot be done with a difference
-- ─────────────────────────────────────────────────────────────
create or replace function public.bank_reconciliation(p_statement uuid)
returns table (
  statement_total numeric,
  statement_closing numeric,
  ledger_closing numeric,
  unsettled integer,
  difference numeric
) language sql stable set search_path = public as $$
  select s.opening_balance + coalesce(sum(t.amount) filter (where t.status <> 'Ignored'), 0),
         s.closing_balance,
         (select coalesce(sum(l.debit) - sum(l.credit), 0)
            from public.journal_lines l
            join public.journals j on j.id = l.journal_id
           where l.account_id = b.account_id and j.entry_date <= s.period_end),
         count(*) filter (where t.status = 'Unmatched')::integer,
         s.closing_balance -
           (select coalesce(sum(l.debit) - sum(l.credit), 0)
              from public.journal_lines l
              join public.journals j on j.id = l.journal_id
             where l.account_id = b.account_id and j.entry_date <= s.period_end)
    from public.bank_statements s
    join public.bank_accounts b on b.id = s.bank_account_id
    left join public.bank_transactions t on t.statement_id = s.id
   where s.id = p_statement
   group by s.id, s.opening_balance, s.closing_balance, s.period_end, b.account_id;
$$;

comment on function public.bank_reconciliation is
  'Where the statement and the ledger stand against each other (0143). The difference is the whole point of the screen.';

revoke all on function public.bank_reconciliation(uuid) from anon, authenticated;
grant execute on function public.bank_reconciliation(uuid) to authenticated;

create or replace function public.reconcile_bank_statement(p_statement uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  r record;
begin
  if not public.is_admin() then
    raise exception 'Only Admin reconciles a statement';
  end if;

  select * into r from public.bank_reconciliation(p_statement);
  if r is null then
    raise exception 'There is no such statement';
  end if;

  if r.unsettled > 0 then
    raise exception '% line(s) on this statement are neither matched nor set aside', r.unsettled;
  end if;

  if r.statement_total <> r.statement_closing then
    raise exception 'The statement does not add up: % from its own lines, % on its face',
      r.statement_total, r.statement_closing
      using hint = 'A line is missing from the import, or a balance was typed wrong.';
  end if;

  if r.difference <> 0 then
    raise exception 'The ledger and the statement differ by %', r.difference
      using hint = 'Find it. A reconciliation that closes with a difference is a tick nobody can rely on.';
  end if;

  update public.bank_statements
     set reconciled_at = now(), reconciled_by = (select public.current_staff_id())
   where id = p_statement;

  perform public.log_access('The books', null, null,
    format('reconciled the statement to %s', (select period_end from public.bank_statements where id = p_statement)));
end;
$$;

comment on function public.reconcile_bank_statement is
  'Marks a statement reconciled, and refuses while anything is unsettled or any difference remains (0143).';

revoke all on function public.reconcile_bank_statement(uuid) from anon, authenticated;
grant execute on function public.reconcile_bank_statement(uuid) to authenticated;

-- The operating account, so there is somewhere for the first statement to go.
insert into public.bank_accounts (entity_id, account_id, name)
select e.id, a.id, 'Operating account'
  from public.ledger_entities e
  join public.ledger_accounts a on a.entity_id = e.id and a.role = 'bank'
 where e.is_default
on conflict (entity_id, name) do nothing;

-- ─────────────────────────────────────────────────────────────
-- The automated accounts stay read-only here too
--
-- Every table with row-level security refuses writes from a system account -
-- the deploy check, the document agent - and eleven new ones arrived with the
-- ledger. The sweep is the same one 0110 wrote; verify_system_account.sql
-- caught these the moment they existed, which is what it is for.
-- ─────────────────────────────────────────────────────────────
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
