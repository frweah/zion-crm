-- Zion Vocational Rehab CRM — more than one set of books (ERP brief, E5)
--
-- "Design now, PCA later." Every posting, account, vendor, asset and budget
-- has carried an entity since 0141, because retro-fitting a dimension onto a
-- year of postings is the rebuild the brief says to avoid. What was missing
-- is the four things that make a second entity work rather than merely fit:
--
--   The reports take an entity, or none, which means every entity the person
--   may see. Today that is one and the answer is identical; the day the PCA
--   exists, the same report reads either set of books or both together.
--
--   Access is per entity. Somebody with no entity named sees the default
--   one, so nothing changes for anybody today; once a row exists for them,
--   that row is the whole list. A CPA brought in for one entity sees one.
--
--   A transfer between the two posts both sides, through an account that
--   exists for exactly that: what one entity owes the other. The two halves
--   are written in one transaction, because a transfer recorded on one side
--   only is the single worst thing that can happen to a set of books.
--
--   A posting cannot mix entities. Every line of an entry must belong to the
--   entry's own entity - which is the mistake that makes consolidated
--   figures right and each entity's own figures wrong, and is invisible
--   until somebody files.
--
-- Nothing here changes a single figure while there is one entity. That is
-- the point: it is the groundwork, verified now, so the second entity is an
-- afternoon rather than a quarter.

-- ── the account a transfer goes through ────────────────────
insert into public.ledger_accounts (entity_id, code, name, kind, role, note)
select e.id, '1900', 'Due from related entity', 'Asset', 'inter_entity',
       'What another entity of the practice owes this one, or is owed by it. Nets to nothing when the entities are consolidated.'
  from public.ledger_entities e
on conflict (entity_id, code) do nothing;

-- ── who may see which books ────────────────────────────────
create table if not exists public.staff_entities (
  staff_id uuid not null references public.staff(id) on delete cascade,
  entity_id uuid not null references public.ledger_entities(id) on delete cascade,
  granted_at timestamptz not null default now(),
  granted_by uuid references public.staff(id) on delete set null,
  primary key (staff_id, entity_id)
);

comment on table public.staff_entities is
  'Which entities a person may see the books of (0152). No row at all means the default entity, so nothing changes for anybody while there is one.';

alter table public.staff_entities enable row level security;

drop policy if exists staff_entities_read on public.staff_entities;
create policy staff_entities_read on public.staff_entities for select to authenticated
  using ((select public.is_admin()) or staff_id = (select public.current_staff_id()));

drop policy if exists staff_entities_write on public.staff_entities;
create policy staff_entities_write on public.staff_entities for all to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));

grant select, insert, update, delete on public.staff_entities to authenticated;

/**
 * The entities this person may see.
 *
 * An Admin sees all of them. The alternative - an Admin who adds the PCA's
 * books and then cannot open them until somebody grants them access - is a
 * trap, and the person who would fall into it is the owner.
 *
 * Everybody else sees the entities named for them, and with none named, the
 * default one: which is what they saw before this table existed, so its
 * arrival locks nobody out. A CPA brought in for one entity is given that
 * one row and sees that one set of books.
 */
create or replace function public.my_entities()
returns setof uuid language sql stable security definer set search_path = public as $$
  select d.id from public.ledger_entities d where public.is_admin() and d.active
  union
  select e.entity_id
    from public.staff_entities e
   where not public.is_admin() and e.staff_id = public.current_staff_id()
  union
  select d.id
    from public.ledger_entities d
   where not public.is_admin()
     and d.is_default
     and not exists (
       select 1 from public.staff_entities x where x.staff_id = public.current_staff_id());
$$;

comment on function public.my_entities() is
  'The entities whose books this person may read (0152). No row of their own means the default one.';

revoke all on function public.my_entities() from anon, authenticated;
grant execute on function public.my_entities() to authenticated;

-- ─────────────────────────────────────────────────────────────
-- A posting belongs to one entity, lines and all
-- ─────────────────────────────────────────────────────────────
create or replace function public.ledger_lines_one_entity()
returns trigger language plpgsql as $$
declare
  v_mixed text;
begin
  select a.code || ' ' || a.name into v_mixed
    from public.journal_lines l
    join public.ledger_accounts a on a.id = l.account_id
    join public.journals j on j.id = l.journal_id
   where l.journal_id = coalesce(new.journal_id, old.journal_id)
     and a.entity_id <> j.entity_id
   limit 1;

  if v_mixed is not null then
    raise exception 'That entry mixes entities: % belongs to another set of books', v_mixed
      using hint = 'A transfer between entities is two entries, one in each, through Due from related entity.';
  end if;
  return null;
end;
$$;

comment on function public.ledger_lines_one_entity() is
  'Refuses an entry whose lines reach into another entity''s chart (0152). Consolidated figures would still be right; each entity''s own would not.';

drop trigger if exists journal_lines_one_entity on public.journal_lines;
create constraint trigger journal_lines_one_entity
  after insert or update on public.journal_lines
  deferrable initially deferred
  for each row execute function public.ledger_lines_one_entity();

-- ─────────────────────────────────────────────────────────────
-- post_journal learns which entity it is posting to
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
  p_shift_if_closed boolean default true,
  p_entity uuid default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_entity uuid := coalesce(p_entity, public.ledger_entity());
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
    v_date := public.ledger_open_date(v_date, v_entity);
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

revoke all on function public.post_journal(date, text, text, uuid, text, jsonb, uuid, text, text, uuid, text, boolean, uuid) from anon, authenticated;

-- The open-month walk takes an entity too: one entity's March may be closed
-- while another's is not.
create or replace function public.ledger_open_date(p_date date, p_entity uuid default null)
returns date language plpgsql stable security definer set search_path = public as $$
declare
  v_entity uuid := coalesce(p_entity, public.ledger_entity());
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

comment on function public.ledger_open_date(date, uuid) is
  'The first month at or after this day that will take a posting, for one entity (0152).';

revoke all on function public.ledger_open_date(date, uuid) from anon, authenticated;
drop function if exists public.ledger_open_date(date);

-- ─────────────────────────────────────────────────────────────
-- A second set of books, with the first one's chart
-- ─────────────────────────────────────────────────────────────
create or replace function public.create_entity(
  p_name text,
  p_books_start date default null,
  p_copy_chart_from uuid default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_from uuid := coalesce(p_copy_chart_from, public.ledger_entity());
  v_new  uuid;
begin
  if not public.is_admin() then
    raise exception 'Only Admin adds a set of books';
  end if;
  if coalesce(btrim(p_name), '') = '' then
    raise exception 'A set of books belongs to somebody named';
  end if;

  insert into public.ledger_entities (name) values (btrim(p_name)) returning id into v_new;

  -- The same chart, so the two can be read side by side and consolidated
  -- without mapping one onto the other.
  insert into public.ledger_accounts (entity_id, code, name, kind, role, active, note)
  select v_new, a.code, a.name, a.kind, a.role, a.active, a.note
    from public.ledger_accounts a where a.entity_id = v_from;

  insert into public.ledger_settings (entity_id, books_start, basis)
  select v_new,
         coalesce(p_books_start, (select books_start from public.ledger_settings where entity_id = v_from)),
         coalesce((select basis from public.ledger_settings where entity_id = v_from), 'Cash');

  perform public.log_access('The books', null, null, format('added the books for %s', btrim(p_name)));
  return v_new;
end;
$$;

comment on function public.create_entity(text, date, uuid) is
  'A new set of books with the same chart as an existing one (0152). Adding the PCA is this, not a rebuild.';

revoke all on function public.create_entity(text, date, uuid) from anon, authenticated;
grant execute on function public.create_entity(text, date, uuid) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- Money moving between the two
-- ─────────────────────────────────────────────────────────────
create or replace function public.post_inter_entity_transfer(
  p_from uuid,
  p_to uuid,
  p_amount numeric,
  p_on date,
  p_memo text
) returns uuid[] language plpgsql security definer set search_path = public as $$
declare
  v_out uuid;
  v_in  uuid;
  v_from_name text;
  v_to_name   text;
  v_from_bank uuid;
  v_to_bank   uuid;
  v_from_due  uuid;
  v_to_due    uuid;
begin
  if not public.is_admin() then
    raise exception 'Only Admin moves money between entities';
  end if;
  if p_from = p_to then
    raise exception 'That is the same set of books';
  end if;
  if coalesce(p_amount, 0) <= 0 then
    raise exception 'An amount, above zero';
  end if;

  select name into v_from_name from public.ledger_entities where id = p_from;
  select name into v_to_name from public.ledger_entities where id = p_to;
  if v_from_name is null or v_to_name is null then
    raise exception 'One of those is not a set of books this practice keeps';
  end if;

  select id into v_from_bank from public.ledger_accounts where entity_id = p_from and role = 'bank';
  select id into v_to_bank   from public.ledger_accounts where entity_id = p_to   and role = 'bank';
  select id into v_from_due  from public.ledger_accounts where entity_id = p_from and role = 'inter_entity';
  select id into v_to_due    from public.ledger_accounts where entity_id = p_to   and role = 'inter_entity';
  if v_from_bank is null or v_to_bank is null or v_from_due is null or v_to_due is null then
    raise exception 'One of those charts has no bank or no related-entity account';
  end if;

  -- Both halves, or neither: one function, one transaction.
  v_out := public.post_journal(
    p_on, format('To %s: %s', v_to_name, coalesce(p_memo, '')),
    'Inter-entity transfer', null, 'Out',
    jsonb_build_array(
      jsonb_build_object('account', v_from_due, 'debit', p_amount),
      jsonb_build_object('account', v_from_bank, 'credit', p_amount)),
    null, coalesce(p_memo, ''), null,
    (select public.current_staff_id()),
    coalesce((select name from public.staff where id = (select public.current_staff_id())), ''),
    true, p_from);

  v_in := public.post_journal(
    p_on, format('From %s: %s', v_from_name, coalesce(p_memo, '')),
    'Inter-entity transfer', null, 'In',
    jsonb_build_array(
      jsonb_build_object('account', v_to_bank, 'debit', p_amount),
      jsonb_build_object('account', v_to_due, 'credit', p_amount)),
    null, coalesce(p_memo, ''), null,
    (select public.current_staff_id()),
    coalesce((select name from public.staff where id = (select public.current_staff_id())), ''),
    true, p_to);

  if (v_out is null) <> (v_in is null) then
    raise exception 'One side of that transfer falls before its books open'
      using hint = 'Both sets of books have to be open on the day money moves between them.';
  end if;

  return array[v_out, v_in];
end;
$$;

comment on function public.post_inter_entity_transfer(uuid, uuid, numeric, date, text) is
  'Money from one entity to another, both sides in one transaction (0152). A transfer posted on one side only is the worst thing that can happen to a set of books.';

revoke all on function public.post_inter_entity_transfer(uuid, uuid, numeric, date, text) from anon, authenticated;
grant execute on function public.post_inter_entity_transfer(uuid, uuid, numeric, date, text) to authenticated;

alter table public.journals drop constraint if exists journals_source_kind_check;
alter table public.journals add constraint journals_source_kind_check
  check (source_kind in (
    'Billing item', 'Contractor statement', 'Contractor payment',
    'Expense claim', 'Bank transaction', 'Vendor bill',
    'Depreciation', 'Asset disposal', 'Inter-entity transfer',
    'Manual', 'Opening balance', 'Reversal'));

-- ─────────────────────────────────────────────────────────────
-- Reading one set of books, or all of them at once
--
-- Every report takes an entity. Null means every entity this person may
-- see, which today is one, so today every answer is unchanged - and that is
-- what makes this safe to deploy now and useful later.
-- ─────────────────────────────────────────────────────────────
create or replace function public.ledger_trial_balance(p_as_of date, p_entity uuid default null)
returns table (
  code text, name text, kind text,
  debits numeric, credits numeric, balance numeric
) language sql stable set search_path = public as $$
  select a.code, a.name, a.kind,
         coalesce(sum(l.debit), 0),
         coalesce(sum(l.credit), 0),
         case when a.kind in ('Asset', 'Expense')
              then coalesce(sum(l.debit), 0) - coalesce(sum(l.credit), 0)
              else coalesce(sum(l.credit), 0) - coalesce(sum(l.debit), 0) end
    from public.ledger_accounts a
    left join public.journal_lines l on l.account_id = a.id
    left join public.journals j on j.id = l.journal_id and j.entry_date <= p_as_of
   where (l.id is null or j.id is not null)
     and a.entity_id in (select public.my_entities())
     and (p_entity is null or a.entity_id = p_entity)
   -- Consolidated: the same code in two charts is one line, which is what
   -- "sum the entities" means on a report somebody reads.
   group by a.code, a.name, a.kind
  having coalesce(sum(l.debit), 0) <> 0 or coalesce(sum(l.credit), 0) <> 0
   order by a.code;
$$;

create or replace function public.ledger_profit_and_loss(
  p_from date, p_to date, p_basis text default null, p_entity uuid default null
)
returns table (
  code text, name text, kind text, amount numeric
) language sql stable set search_path = public as $$
  with mine as (
    select a.id, a.code, a.name, a.kind
      from public.ledger_accounts a
     where a.entity_id in (select public.my_entities())
       and (p_entity is null or a.entity_id = p_entity)
  ),
  basis as (
    select coalesce(
      nullif(p_basis, ''),
      (select s.basis from public.ledger_settings s
         join public.ledger_entities e on e.id = s.entity_id and e.is_default)) as b
  ),
  accrual as (
    select a.code, a.name, a.kind,
           case when a.kind = 'Revenue'
                then coalesce(sum(l.credit), 0) - coalesce(sum(l.debit), 0)
                else coalesce(sum(l.debit), 0) - coalesce(sum(l.credit), 0) end as amount
      from mine a
      join public.journal_lines l on l.account_id = a.id
      join public.journals j on j.id = l.journal_id
     where a.kind in ('Revenue', 'Expense')
       and j.entry_date between p_from and p_to
     group by a.code, a.name, a.kind
  ),
  moved as (
    select j.cash_class_account_id as account_id,
           sum(case when l.account_id in (select public.ledger_cash_accounts())
                    then l.debit - l.credit else 0 end) as cash
      from public.journals j
      join public.journal_lines l on l.journal_id = j.id
     where j.cash_class_account_id is not null
       and j.entity_id in (select public.my_entities())
       and (p_entity is null or j.entity_id = p_entity)
       and j.entry_date between p_from and p_to
     group by j.id, j.cash_class_account_id
  ),
  cash as (
    select a.code, a.name, a.kind,
           sum(case when a.kind = 'Revenue' then m.cash else -m.cash end) as amount
      from moved m
      join mine a on a.id = m.account_id
     where m.cash <> 0
     group by a.code, a.name, a.kind
  )
  select r.code, r.name, r.kind, sum(r.amount)
    from (
      select code, name, kind, amount from accrual where (select b from basis) = 'Accrual'
      union all
      select code, name, kind, amount from cash where (select b from basis) = 'Cash'
    ) r
   group by r.code, r.name, r.kind
  having sum(r.amount) <> 0
   order by r.code;
$$;

create or replace function public.ledger_balance_sheet(p_as_of date, p_entity uuid default null)
returns table (
  code text, name text, kind text, balance numeric
) language sql stable set search_path = public as $$
  select t.code, t.name, t.kind, t.balance
    from public.ledger_trial_balance(p_as_of, p_entity) t
   where t.kind in ('Asset', 'Liability', 'Equity')
  union all
  select '3999', 'Earnings to date', 'Equity',
         coalesce((select sum(case when t.kind = 'Revenue' then t.balance else -t.balance end)
                     from public.ledger_trial_balance(p_as_of, p_entity) t
                    where t.kind in ('Revenue', 'Expense')), 0)
   order by 1;
$$;

create or replace function public.ledger_cash_accounts(p_entity uuid default null)
returns setof uuid language sql stable set search_path = public as $$
  select a.id
    from public.ledger_accounts a
   where a.role in ('bank', 'undeposited')
     and a.entity_id in (select public.my_entities())
     and (p_entity is null or a.entity_id = p_entity);
$$;

comment on function public.ledger_cash_accounts(uuid) is
  'The accounts that are money the practice has, for one entity or all the ones this person may see (0152).';

create or replace function public.ledger_cash_flow(p_from date, p_to date, p_entity uuid default null)
returns table (
  month date, money_in numeric, money_out numeric, net numeric, closing numeric
) language sql stable set search_path = public as $$
  with movement as (
    select date_trunc('month', j.entry_date)::date as month,
           sum(l.debit) as in_, sum(l.credit) as out_
      from public.journals j
      join public.journal_lines l on l.journal_id = j.id
     where l.account_id in (select public.ledger_cash_accounts(p_entity))
       and j.entry_date between p_from and p_to
     group by 1
  ),
  opening as (
    select coalesce(sum(l.debit) - sum(l.credit), 0) as balance
      from public.journals j
      join public.journal_lines l on l.journal_id = j.id
     where l.account_id in (select public.ledger_cash_accounts(p_entity))
       and j.entry_date < p_from
  )
  select m.month, m.in_, m.out_, m.in_ - m.out_,
         (select balance from opening)
           + sum(m.in_ - m.out_) over (order by m.month rows between unbounded preceding and current row)
    from movement m
   order by m.month;
$$;

create or replace function public.ledger_revenue_by(
  p_from date, p_to date, p_dimension text default 'service', p_entity uuid default null
)
returns table (label text, amount numeric) language sql stable set search_path = public as $$
  select case p_dimension
           when 'office'    then coalesce(nullif(l.office, ''), 'No office on the record')
           when 'counselor' then coalesce(k.name, 'No counselor on the record')
           when 'entity'    then e.name
           else coalesce(nullif(l.service, ''), 'No service named')
         end,
         sum(l.credit) - sum(l.debit)
    from public.journals j
    join public.journal_lines l on l.journal_id = j.id
    join public.ledger_accounts a on a.id = l.account_id and a.kind = 'Revenue'
    join public.ledger_entities e on e.id = j.entity_id
    left join public.counselors k on k.id = l.counselor_id
   where j.entry_date between p_from and p_to
     and j.entity_id in (select public.my_entities())
     and (p_entity is null or j.entity_id = p_entity)
   group by 1
  having sum(l.credit) - sum(l.debit) <> 0
   order by 2 desc;
$$;

comment on function public.ledger_revenue_by(date, date, text, uuid) is
  'Revenue for a period by service, office, counselor or entity (0152).';

create or replace function public.ledger_contractor_cost(p_from date, p_to date, p_entity uuid default null)
returns table (staff_id uuid, person text, amount numeric)
language sql stable set search_path = public as $$
  select l.staff_id, coalesce(s.name, 'Not against a person'),
         sum(l.debit) - sum(l.credit)
    from public.journals j
    join public.journal_lines l on l.journal_id = j.id
    join public.ledger_accounts a on a.id = l.account_id
    left join public.staff s on s.id = l.staff_id
   where a.role = 'contractor_cost'
     and j.entry_date between p_from and p_to
     and j.entity_id in (select public.my_entities())
     and (p_entity is null or j.entity_id = p_entity)
   group by l.staff_id, s.name
  having sum(l.debit) - sum(l.credit) <> 0
   order by 3 desc;
$$;

create or replace function public.ledger_ap_aging(p_as_of date, p_entity uuid default null)
returns table (
  staff_id uuid, person text, bucket text, amount numeric
) language sql stable set search_path = public as $$
  with owed as (
    select l.staff_id, l.vendor_id, j.entry_date,
           sum(l.credit) - sum(l.debit) as amount
      from public.journals j
      join public.journal_lines l on l.journal_id = j.id
      join public.ledger_accounts a on a.id = l.account_id
     where a.role in ('contractor_payable', 'ap')
       and j.entry_date <= p_as_of
       and j.entity_id in (select public.my_entities())
       and (p_entity is null or j.entity_id = p_entity)
     group by l.staff_id, l.vendor_id, j.entry_date
  ),
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

create or replace function public.ledger_general_ledger(
  p_account uuid, p_from date, p_to date
)
returns table (
  journal_id uuid, entry_date date, memo text, source_kind text, source_id uuid,
  debit numeric, credit numeric, running numeric, client text, person text
) language sql stable set search_path = public as $$
  with opening as (
    select coalesce(sum(l.debit) - sum(l.credit), 0) as balance
      from public.journals j
      join public.journal_lines l on l.journal_id = j.id
     where l.account_id = p_account and j.entry_date < p_from
       and j.entity_id in (select public.my_entities())
  )
  select j.id, j.entry_date, j.memo, j.source_kind, j.source_id,
         l.debit, l.credit,
         (select balance from opening)
           + sum(l.debit - l.credit) over (order by j.entry_date, j.created_at, l.id
                                           rows between unbounded preceding and current row),
         coalesce(c.name, ''), coalesce(s.name, '')
    from public.journals j
    join public.journal_lines l on l.journal_id = j.id
    left join public.clients c on c.id = l.client_id
    left join public.staff s on s.id = l.staff_id
   where l.account_id = p_account
     and j.entry_date between p_from and p_to
     and j.entity_id in (select public.my_entities())
   order by j.entry_date, j.created_at, l.id;
$$;

create or replace function public.ledger_budget_variance(
  p_from date, p_to date, p_entity uuid default null
)
returns table (
  account_id uuid, code text, name text, kind text,
  budget numeric, actual numeric, variance numeric, over boolean
) language sql stable set search_path = public as $$
  with mine as (
    select a.* from public.ledger_accounts a
     where a.entity_id in (select public.my_entities())
       and (p_entity is null or a.entity_id = p_entity)
  ),
  months as (
    select generate_series(date_trunc('month', p_from), date_trunc('month', p_to), interval '1 month')::date as month
  ),
  budgeted as (
    select b.account_id, sum(b.amount) as amount
      from public.ledger_budgets b
      join months m on m.month = b.month
      join mine a on a.id = b.account_id
     group by b.account_id
  ),
  actual as (
    select l.account_id,
           case when a.kind = 'Revenue'
                then sum(l.credit) - sum(l.debit)
                else sum(l.debit) - sum(l.credit) end as amount
      from public.journal_lines l
      join public.journals j on j.id = l.journal_id
      join mine a on a.id = l.account_id
     where a.kind in ('Revenue', 'Expense')
       and j.entry_date between p_from and p_to
     group by l.account_id, a.kind
  )
  select a.id, a.code, a.name, a.kind,
         coalesce(b.amount, 0), coalesce(x.amount, 0),
         case when a.kind = 'Revenue'
              then coalesce(x.amount, 0) - coalesce(b.amount, 0)
              else coalesce(b.amount, 0) - coalesce(x.amount, 0) end,
         a.kind = 'Expense' and b.amount is not null and coalesce(x.amount, 0) > b.amount
    from mine a
    left join budgeted b on b.account_id = a.id
    left join actual x on x.account_id = a.id
   where a.kind in ('Revenue', 'Expense')
     and (b.amount is not null or x.amount is not null)
   order by a.code;
$$;

-- ── who may run them ───────────────────────────────────────
do $$
declare f text;
begin
  foreach f in array array[
    'ledger_cash_accounts(uuid)',
    'ledger_trial_balance(date, uuid)',
    'ledger_profit_and_loss(date, date, text, uuid)',
    'ledger_balance_sheet(date, uuid)',
    'ledger_cash_flow(date, date, uuid)',
    'ledger_ap_aging(date, uuid)',
    'ledger_general_ledger(uuid, date, date)',
    'ledger_revenue_by(date, date, text, uuid)',
    'ledger_contractor_cost(date, date, uuid)',
    'ledger_budget_variance(date, date, uuid)'
  ] loop
    execute format('revoke all on function public.%s from anon, authenticated', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

-- The old shapes, now that every caller passes the entity (or does not).
-- Two overloads of post_journal would make every call ambiguous, which is a
-- failure at the moment of posting rather than at deploy.
drop function if exists public.post_journal(
  date, text, text, uuid, text, jsonb, uuid, text, text, uuid, text, boolean);
drop function if exists public.ledger_cash_accounts();
drop function if exists public.ledger_trial_balance(date);
drop function if exists public.ledger_profit_and_loss(date, date, text);
drop function if exists public.ledger_balance_sheet(date);
drop function if exists public.ledger_cash_flow(date, date);
drop function if exists public.ledger_ap_aging(date);
drop function if exists public.ledger_revenue_by(date, date, text);
drop function if exists public.ledger_contractor_cost(date, date);
drop function if exists public.ledger_budget_variance(date, date);

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
