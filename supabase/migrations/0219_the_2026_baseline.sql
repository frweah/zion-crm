-- Zion Vocational Rehab CRM — the 2026 baseline
-- (owner, 18 Oct 2026)
--
-- The books open on 1 January 2027. ledger_settings.books_start says so, and
-- post_journal refuses to post anything dated before it - so everything the
-- practice has done in 2026 sits outside the ledger entirely, and on the day
-- the books open there is nothing to say what came before.
--
-- A baseline is that record: what the practice had authorized, billed,
-- received and was still owed at a date, counted once and kept. 2027 is
-- measured from it, and the CPA is handed it.
--
-- **Frozen, and that is the whole point.** The figures are stored rather than
-- worked out again on each view, because a baseline that recomputes is not a
-- baseline: an authorization corrected in March would quietly change what
-- December said, and the number the practice compared itself against would
-- move without anybody deciding it should. So a snapshot is taken, and once
-- taken it cannot be edited - only superseded by another one with a note
-- saying why.
--
-- What is counted, and where each figure comes from, so the CPA can be told:
--
--   authorized / earned / invoiced / received / outstanding / unbilled - from
--   authorization_economics, which is the practice's own definition of each
--   and is what Admin → Money already shows on screen.
--
--   The counts beside them - clients, authorizations, documents, logged hours
--   - so that a restore or a migration can be checked against a known good
--   row, not only the money.

create table if not exists public.money_baselines (
  id           uuid primary key default gen_random_uuid(),
  -- What the figures describe: everything up to and including this day.
  as_of        date not null,
  label        text not null default '',
  -- The money, as authorization_economics defines it.
  authorized   numeric(14,2) not null default 0,
  earned       numeric(14,2) not null default 0,
  invoiced     numeric(14,2) not null default 0,
  received     numeric(14,2) not null default 0,
  outstanding  numeric(14,2) not null default 0,
  unbilled     numeric(14,2) not null default 0,
  -- The shape of the practice at the same moment.
  clients      integer not null default 0,
  authorizations integer not null default 0,
  documents    integer not null default 0,
  hours        numeric(12,2) not null default 0,
  taken_at     timestamptz not null default now(),
  taken_by     uuid references public.staff(id) on delete set null,
  note         text not null default '',
  constraint money_baselines_one_per_day unique (as_of)
);

comment on table public.money_baselines is
  'The practice''s position at a date, counted once and kept, so 2027 has something to be measured from (0219).';

/**
 * A baseline cannot be edited.
 *
 * Append-only, like every other record in this system that somebody will
 * later rely on. A figure that can be changed after the fact is a figure
 * nobody can cite.
 */
create or replace function public.baselines_are_kept()
returns trigger language plpgsql set search_path = public as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'A baseline is not deleted. Take another one and say why.'
      using errcode = 'check_violation';
  end if;
  if new.note is distinct from old.note then
    -- A note added afterwards is the one thing that may change: it explains
    -- the row rather than altering it.
    return new;
  end if;
  raise exception 'A baseline is not edited. Take another one and say why.'
    using errcode = 'check_violation';
end;
$$;

drop trigger if exists money_baselines_are_kept on public.money_baselines;
create trigger money_baselines_are_kept
  before update or delete on public.money_baselines
  for each row execute function public.baselines_are_kept();

/**
 * Take one.
 *
 * Admin's, because it is the practice's account of itself. Counted from the
 * same views the Money screen reads, so the snapshot and the screen cannot
 * disagree on the day it is taken.
 */
create or replace function public.take_money_baseline(p_as_of date, p_label text default '')
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  if not public.is_admin() then
    raise exception 'The practice''s baseline is Admin''s to take.'
      using errcode = 'insufficient_privilege';
  end if;
  if p_as_of is null then
    raise exception 'As at which day?' using errcode = 'check_violation';
  end if;
  if p_as_of > public.practice_today() then
    raise exception 'That day has not happened yet.' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.money_baselines where as_of = p_as_of) then
    raise exception 'There is already a baseline for %. A baseline is taken once.', p_as_of
      using errcode = 'unique_violation';
  end if;

  insert into public.money_baselines (
    as_of, label, authorized, earned, invoiced, received, outstanding, unbilled,
    clients, authorizations, documents, hours, taken_by
  )
  select
    p_as_of,
    coalesce(nullif(btrim(p_label), ''), to_char(p_as_of, 'YYYY') || ' baseline'),
    coalesce(sum(e.authorized), 0),
    coalesce(sum(e.earned), 0),
    coalesce(sum(e.invoiced), 0),
    coalesce(sum(e.received), 0),
    coalesce(sum(e.outstanding), 0),
    coalesce(sum(e.unbilled), 0),
    (select count(*) from public.clients),
    (select count(*) from public.authorizations),
    (select count(*) from public.attachments),
    (select coalesce(sum(se.hours), 0) from public.service_entries se where se.date <= p_as_of),
    public.current_staff_id()
  from public.authorization_economics e
  join public.authorizations a on a.id = e.auth_id
  where a.received_on is null or a.received_on <= p_as_of
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.take_money_baseline(date, text) from anon, authenticated;
grant execute on function public.take_money_baseline(date, text) to authenticated;

alter table public.money_baselines enable row level security;

-- Admin's to read, as the rest of Admin → Money is.
drop policy if exists money_baselines_read on public.money_baselines;
create policy money_baselines_read on public.money_baselines
  for select to authenticated
  using ((select public.is_active_staff()) and (select public.is_admin()));

drop policy if exists money_baselines_note on public.money_baselines;
create policy money_baselines_note on public.money_baselines
  for update to authenticated
  using ((select public.is_admin()))
  with check ((select public.is_admin()));

grant select on public.money_baselines to authenticated;
grant update (note) on public.money_baselines to authenticated;

select public.apply_system_read_only('money_baselines');

do $$
begin
  if not exists (select 1 from information_schema.tables
                  where table_schema = 'public' and table_name = 'money_baselines') then
    raise exception 'money_baselines did not arrive.';
  end if;
  raise notice 'ok  the practice can write down where it stood, and not change it afterwards';
end $$;
