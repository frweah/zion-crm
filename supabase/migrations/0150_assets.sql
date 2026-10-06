-- Zion Vocational Rehab CRM — the asset register (ERP brief, E4)
--
-- Laptops, phones and equipment: what the practice owns, who has it, what it
-- cost, and what it is worth now. Three things this is actually for:
--
--   Somebody leaves and the laptop goes with them. The offboarding checklist
--   reads this, so "return assigned assets" is a list of actual things with
--   actual tags rather than a line somebody ticks from memory.
--
--   The CPA asks what the fixed assets are worth. Straight-line
--   depreciation, posted monthly, with the lives the CPA sets - so the
--   balance sheet is right without anybody keeping a spreadsheet beside it.
--
--   Something breaks and is thrown away. Disposal takes the cost and the
--   depreciation off the books together and recognises what was left as a
--   gain or a loss, which is the part a spreadsheet always gets wrong.
--
-- Depreciation is posted, not calculated on the fly, because it is a real
-- monthly expense and a report that worked it out each time would disagree
-- with the trial balance the moment a life changed.

-- ── the accounts this needs ────────────────────────────────
insert into public.ledger_accounts (entity_id, code, name, kind, role, note)
select e.id, a.code, a.name, a.kind, a.role, a.note
  from public.ledger_entities e
 cross join (values
  ('1500', 'Equipment',                 'Asset',   'equipment',        'What the practice owns, at what it cost.'),
  ('1590', 'Accumulated depreciation',  'Asset',   'accumulated_dep',  'What has been written off the equipment above. Shows as a credit.'),
  ('4900', 'Gain on disposal',          'Revenue', 'disposal_gain',    ''),
  ('5800', 'Depreciation',              'Expense', 'depreciation',     'Straight-line, monthly, at the lives the CPA set.'),
  ('5810', 'Loss on disposal',          'Expense', 'disposal_loss',    '')
) as a(code, name, kind, role, note)
 where e.is_default
on conflict (entity_id, code) do nothing;

-- ── what kind of thing it is, and how long it lasts ────────
create table if not exists public.asset_classes (
  key text primary key,
  label text not null,
  -- The CPA sets these. Null means this kind is not depreciated.
  life_months integer check (life_months is null or life_months between 1 and 600),
  -- Below this, it is an expense rather than an asset.
  capitalise_over numeric(12, 2) not null default 0,
  sort_order integer not null default 0,
  updated_at timestamptz not null default now()
);

comment on table public.asset_classes is
  'The kinds of thing the practice owns and how long each lasts (0150). Rows, because the CPA sets the lives.';

insert into public.asset_classes (key, label, life_months, capitalise_over, sort_order) values
  ('laptop',    'Laptops and computers', 36, 500,  10),
  ('phone',     'Phones and tablets',    24, 300,  20),
  ('furniture', 'Furniture',             84, 500,  30),
  ('equipment', 'Other equipment',       60, 500,  40),
  ('software',  'Software licences',     36, 1000, 50)
on conflict (key) do nothing;

-- ── the things themselves ──────────────────────────────────
create table if not exists public.assets (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.ledger_entities(id) on delete restrict,
  -- What is written on the sticker.
  tag text not null,
  name text not null,
  class_key text not null references public.asset_classes(key) on update cascade,
  serial text not null default '',
  cost numeric(14, 2) not null check (cost >= 0),
  acquired_on date not null,
  warranty_end date,
  photo_path text,

  status text not null default 'In use' check (status in (
    'In use', 'Spare', 'Being repaired', 'Lost', 'Disposed'
  )),
  assigned_staff_id uuid references public.staff(id) on delete set null,

  -- The bill it came in on, where there was one.
  bill_id uuid references public.vendor_bills(id) on delete set null,

  disposed_on date,
  disposal_reason text not null default '',
  proceeds numeric(14, 2) check (proceeds is null or proceeds >= 0),

  note text not null default '',
  created_at timestamptz not null default now(),
  created_by uuid references public.staff(id) on delete set null,
  updated_at timestamptz not null default now(),

  unique (entity_id, tag),
  constraint assets_disposed_has_reason check (
    status <> 'Disposed' or (disposed_on is not null and btrim(disposal_reason) <> '')
  ),
  -- A thing that has gone is not assigned to anybody.
  constraint assets_disposed_is_unassigned check (
    status <> 'Disposed' or assigned_staff_id is null
  )
);

comment on table public.assets is
  'What the practice owns, who has it, and what it cost (0150).';

drop trigger if exists assets_updated_at on public.assets;
create trigger assets_updated_at before update on public.assets
  for each row execute function public.set_updated_at();

create index if not exists assets_assigned_idx on public.assets (assigned_staff_id)
  where assigned_staff_id is not null;
create index if not exists assets_status_idx on public.assets (entity_id, status, tag);

-- ── who has had it ─────────────────────────────────────────
create table if not exists public.asset_assignments (
  id uuid primary key default gen_random_uuid(),
  asset_id uuid not null references public.assets(id) on delete cascade,
  staff_id uuid references public.staff(id) on delete set null,
  staff_name text not null default '',
  from_date date not null,
  to_date date,
  note text not null default '',
  recorded_by uuid references public.staff(id) on delete set null,
  recorded_at timestamptz not null default now(),
  constraint asset_assignments_dates_in_order check (to_date is null or to_date >= from_date)
);

comment on table public.asset_assignments is
  'Who has had each thing, and when (0150). The name is kept as well as the link, because somebody who leaves is still who had the laptop.';

create index if not exists asset_assignments_asset_idx on public.asset_assignments (asset_id, from_date desc);
create index if not exists asset_assignments_open_idx on public.asset_assignments (staff_id) where to_date is null;

-- One person at a time holds a thing.
create unique index if not exists asset_assignments_one_open
  on public.asset_assignments (asset_id) where to_date is null;

-- ── what has been written off ──────────────────────────────
create table if not exists public.asset_depreciation (
  asset_id uuid not null references public.assets(id) on delete cascade,
  month date not null,
  amount numeric(14, 2) not null check (amount > 0),
  journal_id uuid references public.journals(id) on delete set null,
  posted_at timestamptz not null default now(),
  primary key (asset_id, month),
  constraint asset_depreciation_is_a_month check (date_trunc('month', month)::date = month)
);

comment on table public.asset_depreciation is
  'One row per thing per month it was depreciated (0150). The row is what stops a month being posted twice.';

-- ─────────────────────────────────────────────────────────────
-- Assigning and returning
--
-- One function, because the two halves have to happen together: a laptop
-- handed from one person to another is a return and an assignment, and a
-- screen that did them separately would eventually do one of them.
-- ─────────────────────────────────────────────────────────────
create or replace function public.assign_asset(
  p_asset uuid,
  p_staff uuid,
  p_note text default ''
) returns void language plpgsql security definer set search_path = public as $$
declare
  v_asset public.assets;
  v_name  text;
begin
  if not public.is_admin() then
    raise exception 'Only Admin assigns equipment';
  end if;

  select * into v_asset from public.assets where id = p_asset;
  if v_asset.id is null then
    raise exception 'There is no such thing on the register';
  end if;
  if v_asset.status = 'Disposed' then
    raise exception 'That one has gone'
      using hint = 'A disposed asset is history; it is not handed to anybody.';
  end if;

  -- Whoever had it, stops having it today.
  update public.asset_assignments
     set to_date = public.practice_today()
   where asset_id = p_asset and to_date is null;

  if p_staff is null then
    update public.assets
       set assigned_staff_id = null,
           status = case when status = 'In use' then 'Spare' else status end
     where id = p_asset;
    return;
  end if;

  select name into v_name from public.staff where id = p_staff;
  if v_name is null then
    raise exception 'There is no such person';
  end if;

  insert into public.asset_assignments (asset_id, staff_id, staff_name, from_date, note, recorded_by)
  values (p_asset, p_staff, v_name, public.practice_today(), coalesce(p_note, ''),
          (select public.current_staff_id()));

  update public.assets
     set assigned_staff_id = p_staff, status = 'In use'
   where id = p_asset;
end;
$$;

comment on function public.assign_asset is
  'Hands a thing to somebody, or takes it back when p_staff is null (0150). The return and the assignment happen together.';

revoke all on function public.assign_asset(uuid, uuid, text) from anon, authenticated;
grant execute on function public.assign_asset(uuid, uuid, text) to authenticated;

/** What somebody still has. The offboarding checklist reads this. */
create or replace function public.assets_held_by(p_staff uuid)
returns table (id uuid, tag text, name text, class_label text, since date)
language sql stable set search_path = public as $$
  select a.id, a.tag, a.name, c.label, g.from_date
    from public.assets a
    join public.asset_classes c on c.key = a.class_key
    left join public.asset_assignments g on g.asset_id = a.id and g.to_date is null
   where a.assigned_staff_id = p_staff and a.status <> 'Disposed'
   order by a.tag;
$$;

comment on function public.assets_held_by is
  'What somebody still has to hand back (0150). "Return assigned assets" is a list of real things with real tags, not a line ticked from memory.';

revoke all on function public.assets_held_by(uuid) from anon, authenticated;
grant execute on function public.assets_held_by(uuid) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- Depreciation, straight line, one month at a time
--
-- Monthly cost is the cost divided by the life, and the last month takes
-- whatever rounding left behind rather than leaving a few cents on the books
-- forever - which is the thing that makes a fixed-asset schedule stop
-- agreeing with the ledger.
-- ─────────────────────────────────────────────────────────────
create or replace function public.post_depreciation_for(p_month date)
returns integer language plpgsql security definer set search_path = public as $$
declare
  v_month   date := date_trunc('month', p_month)::date;
  v_entity  uuid := public.ledger_entity();
  v_dep     uuid := public.ledger_account('depreciation');
  v_acc     uuid := public.ledger_account('accumulated_dep');
  v_posted  integer := 0;
  v_journal uuid;
  a         record;
  v_monthly numeric;
  v_sofar   numeric;
  v_left    numeric;
begin
  if v_dep is null or v_acc is null then
    raise exception 'The chart has no depreciation accounts';
  end if;
  -- A month that has not finished is a month that cannot be depreciated.
  if v_month >= date_trunc('month', public.practice_today())::date then
    return 0;
  end if;

  for a in
    select s.id, s.tag, s.name, s.cost, s.acquired_on, c.life_months,
           coalesce((select sum(d.amount) from public.asset_depreciation d where d.asset_id = s.id), 0) as written_off
      from public.assets s
      join public.asset_classes c on c.key = s.class_key
     where s.entity_id = v_entity
       and c.life_months is not null
       and s.cost > 0
       -- In service by that month, and not already gone before it.
       and date_trunc('month', s.acquired_on)::date <= v_month
       and (s.disposed_on is null or date_trunc('month', s.disposed_on)::date > v_month)
       and not exists (select 1 from public.asset_depreciation d
                        where d.asset_id = s.id and d.month = v_month)
  loop
    v_monthly := round(a.cost / a.life_months, 2);
    v_left := a.cost - a.written_off;
    if v_left <= 0 then
      continue;
    end if;
    -- The last month takes the rounding with it.
    if v_left < v_monthly then
      v_monthly := v_left;
    end if;

    v_journal := public.post_journal(
      (v_month + interval '1 month - 1 day')::date,
      format('Depreciation, %s - %s', a.tag, a.name),
      'Depreciation', a.id, to_char(v_month, 'YYYY-MM'),
      jsonb_build_array(
        jsonb_build_object('account', v_dep, 'debit', v_monthly),
        jsonb_build_object('account', v_acc, 'credit', v_monthly)
      ));

    -- Before the books open there is nothing to post to, and nothing is
    -- written down as depreciated either - otherwise the first real month
    -- would find the asset already written off.
    if v_journal is not null then
      insert into public.asset_depreciation (asset_id, month, amount, journal_id)
      values (a.id, v_month, v_monthly, v_journal)
      on conflict (asset_id, month) do nothing;
      v_posted := v_posted + 1;
    end if;
  end loop;

  return v_posted;
end;
$$;

comment on function public.post_depreciation_for is
  'Straight-line depreciation for one finished month (0150). The row in asset_depreciation is what stops a month posting twice.';

revoke all on function public.post_depreciation_for(date) from public, anon, authenticated;
grant execute on function public.post_depreciation_for(date) to service_role;

-- ─────────────────────────────────────────────────────────────
-- Disposal
--
-- The cost and the depreciation come off together, and whatever is left is a
-- gain or a loss. Doing it in one function is the point: a disposal recorded
-- on a screen and posted later is a disposal that gets posted wrongly.
-- ─────────────────────────────────────────────────────────────
create or replace function public.dispose_asset(
  p_asset uuid,
  p_on date,
  p_reason text,
  p_proceeds numeric default 0
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_asset   public.assets;
  v_written numeric;
  v_book    numeric;
  v_result  numeric;
  v_lines   jsonb;
  v_journal uuid;
  v_equip   uuid := public.ledger_account('equipment');
  v_acc     uuid := public.ledger_account('accumulated_dep');
  v_bank    uuid := public.ledger_account('undeposited');
begin
  if not public.is_admin() then
    raise exception 'Only Admin disposes of equipment';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'Say why it is going'
      using hint = 'Somebody will ask what happened to it.';
  end if;

  select * into v_asset from public.assets where id = p_asset;
  if v_asset.id is null then
    raise exception 'There is no such thing on the register';
  end if;
  if v_asset.status = 'Disposed' then
    raise exception 'That one has already gone';
  end if;

  select coalesce(sum(d.amount), 0) into v_written
    from public.asset_depreciation d where d.asset_id = p_asset;
  v_book := v_asset.cost - v_written;
  v_result := coalesce(p_proceeds, 0) - v_book;

  update public.asset_assignments set to_date = coalesce(p_on, public.practice_today())
   where asset_id = p_asset and to_date is null;
  update public.assets
     set status = 'Disposed', disposed_on = coalesce(p_on, public.practice_today()),
         disposal_reason = p_reason, proceeds = coalesce(p_proceeds, 0),
         assigned_staff_id = null
   where id = p_asset;

  -- Nothing was ever capitalised, so there is nothing to take off.
  if v_asset.cost = 0 or v_equip is null then
    return null;
  end if;

  v_lines := jsonb_build_array(
    jsonb_build_object('account', v_equip, 'credit', v_asset.cost)
  );
  if v_written > 0 then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object('account', v_acc, 'debit', v_written));
  end if;
  if coalesce(p_proceeds, 0) > 0 then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object('account', v_bank, 'debit', p_proceeds));
  end if;
  if v_result > 0 then
    v_lines := v_lines || jsonb_build_array(
      jsonb_build_object('account', public.ledger_account('disposal_gain'), 'credit', v_result));
  elsif v_result < 0 then
    v_lines := v_lines || jsonb_build_array(
      jsonb_build_object('account', public.ledger_account('disposal_loss'), 'debit', -v_result));
  end if;

  v_journal := public.post_journal(
    coalesce(p_on, public.practice_today()),
    format('%s - %s disposed: %s', v_asset.tag, v_asset.name, p_reason),
    'Asset disposal', p_asset, 'Disposed', v_lines,
    case when v_result < 0 then public.ledger_account('disposal_loss')
         when v_result > 0 then public.ledger_account('disposal_gain') end,
    p_reason, null,
    (select public.current_staff_id()),
    coalesce((select name from public.staff where id = (select public.current_staff_id())), '')
  );

  return v_journal;
end;
$$;

comment on function public.dispose_asset is
  'Takes a thing off the books: its cost, its depreciation, what was got for it, and the gain or loss left over (0150).';

revoke all on function public.dispose_asset(uuid, date, text, numeric) from anon, authenticated;
grant execute on function public.dispose_asset(uuid, date, text, numeric) to authenticated;

-- ── a posting can come from an asset ───────────────────────
alter table public.journals drop constraint if exists journals_source_kind_check;
alter table public.journals add constraint journals_source_kind_check
  check (source_kind in (
    'Billing item', 'Contractor statement', 'Contractor payment',
    'Expense claim', 'Bank transaction', 'Vendor bill',
    'Depreciation', 'Asset disposal',
    'Manual', 'Opening balance', 'Reversal'));

-- ── what the register is worth ─────────────────────────────
create or replace function public.asset_register(p_as_of date default null)
returns table (
  id uuid, tag text, name text, class_label text, serial text,
  cost numeric, written_off numeric, book_value numeric,
  acquired_on date, warranty_end date, status text, held_by text
) language sql stable set search_path = public as $$
  select a.id, a.tag, a.name, c.label, a.serial,
         a.cost,
         coalesce(d.written_off, 0),
         a.cost - coalesce(d.written_off, 0),
         a.acquired_on, a.warranty_end, a.status,
         coalesce(s.name, '')
    from public.assets a
    join public.asset_classes c on c.key = a.class_key
    left join public.staff s on s.id = a.assigned_staff_id
    left join lateral (
      select sum(x.amount) as written_off
        from public.asset_depreciation x
       where x.asset_id = a.id
         and (p_as_of is null or x.month <= date_trunc('month', p_as_of)::date)
    ) d on true
   order by a.status, a.tag;
$$;

comment on function public.asset_register is
  'Everything on the register with what it cost, what has been written off, and what it is worth (0150).';

revoke all on function public.asset_register(date) from anon, authenticated;
grant execute on function public.asset_register(date) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- Who may see and do this
--
-- Wider than the books: everybody sees what they themselves have, because
-- "which laptop am I supposed to have" is a question people ask about
-- themselves. Admin keeps the register.
-- ─────────────────────────────────────────────────────────────
alter table public.asset_classes      enable row level security;
alter table public.assets             enable row level security;
alter table public.asset_assignments  enable row level security;
alter table public.asset_depreciation enable row level security;

drop policy if exists asset_classes_read on public.asset_classes;
create policy asset_classes_read on public.asset_classes for select to authenticated
  using ((select public.is_active_staff()));
drop policy if exists asset_classes_write on public.asset_classes;
create policy asset_classes_write on public.asset_classes for all to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));

drop policy if exists assets_read on public.assets;
create policy assets_read on public.assets for select to authenticated
  using (
    (select public.is_admin())
    or (select public.may_read_books())
    or assigned_staff_id = (select public.current_staff_id())
  );
drop policy if exists assets_write on public.assets;
create policy assets_write on public.assets for all to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));

drop policy if exists asset_assignments_read on public.asset_assignments;
create policy asset_assignments_read on public.asset_assignments for select to authenticated
  using ((select public.is_admin()) or staff_id = (select public.current_staff_id()));

drop policy if exists asset_depreciation_read on public.asset_depreciation;
create policy asset_depreciation_read on public.asset_depreciation for select to authenticated
  using ((select public.may_read_books()));

grant select on public.asset_classes to authenticated;
grant insert, update, delete on public.asset_classes to authenticated;
grant select, insert, update, delete on public.assets to authenticated;
grant select on public.asset_assignments to authenticated;
grant select on public.asset_depreciation to authenticated;

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
