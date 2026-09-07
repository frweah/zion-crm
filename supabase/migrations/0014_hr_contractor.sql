-- Zion Vocational Rehab CRM — 0014 HR: employment type, work sessions, statements
--
-- Phase 6 Group B, contractor path. Rei and Margaret are 1099 contractors.
--
-- The classification drives the design, not just a label. A contractor logs
-- work sessions and produces a statement that is the basis of their invoice.
-- There is deliberately no shift clock, no break tracking and no schedule
-- here: building those against a contractor record would create exactly the
-- evidence of employee-style control that the classification review is about.
-- The employee path is a later migration, needed only if a W-2 hire is made.

-- ─────────────────────────────────────────────────────────────
-- Organisation settings
-- ─────────────────────────────────────────────────────────────
create table public.org_settings (
  id            boolean primary key default true check (id),
  pay_period    text not null default 'Biweekly'
                  check (pay_period in ('Weekly', 'Biweekly', 'Semimonthly')),
  period_anchor date not null default date '2026-01-05',
  updated_at    timestamptz not null default now()
);

insert into public.org_settings (id, pay_period, period_anchor)
values (true, 'Biweekly', date '2026-01-05')
on conflict (id) do nothing;

alter table public.org_settings enable row level security;
create policy org_settings_read on public.org_settings
  for select to authenticated using (public.is_active_staff());
create policy org_settings_write on public.org_settings
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

/**
 * The statement period containing a date.
 *
 * Anchored rather than calendar-derived so biweekly periods stay put: without
 * an anchor, "every two weeks" drifts depending on where you start counting,
 * and two people would disagree about which period a Sunday belongs to.
 */
create or replace function public.period_start(d date)
returns date language plpgsql stable as $$
declare
  s record;
begin
  select pay_period, period_anchor into s from public.org_settings where id;

  if s.pay_period = 'Weekly' then
    return s.period_anchor + (floor((d - s.period_anchor)::numeric / 7) * 7)::int;
  elsif s.pay_period = 'Semimonthly' then
    return case when extract(day from d) <= 15
                then date_trunc('month', d)::date
                else (date_trunc('month', d) + interval '15 days')::date end;
  else
    return s.period_anchor + (floor((d - s.period_anchor)::numeric / 14) * 14)::int;
  end if;
end;
$$;

create or replace function public.period_end(d date)
returns date language plpgsql stable as $$
declare
  s record;
  st date := public.period_start(d);
begin
  select pay_period into s from public.org_settings where id;
  if s.pay_period = 'Weekly' then return st + 6;
  elsif s.pay_period = 'Semimonthly' then
    return case when extract(day from st) = 1
                then (date_trunc('month', st) + interval '14 days')::date
                else (date_trunc('month', st) + interval '1 month - 1 day')::date end;
  else return st + 13;
  end if;
end;
$$;

grant execute on function public.period_start(date), public.period_end(date) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- Employment type — visible to the person it describes, and to Admin.
-- Not on public.staff, which every active staff member can read: how a
-- colleague is engaged is not their business.
-- ─────────────────────────────────────────────────────────────
create table public.staff_employment (
  staff_id        uuid primary key references public.staff(id) on delete cascade,
  employment_type text not null default 'Contractor'
                    check (employment_type in ('Employee', 'Contractor')),
  started_on      date,
  notes           text not null default '',
  updated_at      timestamptz not null default now()
);
create trigger staff_employment_updated_at before update on public.staff_employment
  for each row execute function public.set_updated_at();

alter table public.staff_employment enable row level security;
create policy staff_employment_read on public.staff_employment
  for select to authenticated
  using (public.is_admin() or staff_id = public.current_staff_id());
create policy staff_employment_write on public.staff_employment
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- ─────────────────────────────────────────────────────────────
-- Pay rates — Admin only, full stop. Not even the person's own row: a rate is
-- set out in their agreement, and the CRM is not where they check it.
-- ─────────────────────────────────────────────────────────────
create table public.staff_pay (
  id             uuid primary key default gen_random_uuid(),
  staff_id       uuid not null references public.staff(id) on delete cascade,
  pay_rate       numeric(10,2) not null,
  rate_unit      text not null default 'Hourly' check (rate_unit in ('Hourly', 'Flat')),
  effective_from date not null default current_date,
  note           text not null default '',
  created_by     uuid references public.staff(id) on delete set null,
  created_at     timestamptz not null default now()
);
create index staff_pay_staff_idx on public.staff_pay (staff_id, effective_from desc);

alter table public.staff_pay enable row level security;
create policy staff_pay_admin on public.staff_pay
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- ─────────────────────────────────────────────────────────────
-- Statements
--
-- Created before the sessions attach to them, so a period exists as a thing
-- that can be submitted and approved.
-- ─────────────────────────────────────────────────────────────
create table public.contractor_statements (
  id           uuid primary key default gen_random_uuid(),
  staff_id     uuid not null references public.staff(id) on delete cascade,
  period_start date not null,
  period_end   date not null,
  status       text not null default 'Draft'
                 check (status in ('Draft', 'Submitted', 'Approved', 'Returned')),
  submitted_at timestamptz,
  decided_at   timestamptz,
  decided_by   uuid references public.staff(id) on delete set null,
  return_note  text not null default '',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (staff_id, period_start)
);
create index contractor_statements_staff_idx on public.contractor_statements (staff_id, period_start desc);
create trigger contractor_statements_updated_at before update on public.contractor_statements
  for each row execute function public.set_updated_at();

alter table public.contractor_statements enable row level security;

create policy statements_read on public.contractor_statements
  for select to authenticated
  using (public.is_admin() or staff_id = public.current_staff_id());

create policy statements_insert on public.contractor_statements
  for insert to authenticated
  with check (public.is_admin() or staff_id = public.current_staff_id());

create policy statements_update on public.contractor_statements
  for update to authenticated
  using (public.is_admin() or staff_id = public.current_staff_id())
  with check (public.is_admin() or staff_id = public.current_staff_id());

create policy statements_delete on public.contractor_statements
  for delete to authenticated using (public.is_admin());

-- ─────────────────────────────────────────────────────────────
-- Work sessions
--
-- Append-only. A mistake is corrected by adding a row that references the one
-- it replaces, with a reason — never by rewriting history. Hours records are
-- kept indefinitely; the federal minimum is three years and there is no reason
-- to discard them after that.
-- ─────────────────────────────────────────────────────────────
create table public.work_sessions (
  id                uuid primary key default gen_random_uuid(),
  staff_id          uuid not null references public.staff(id) on delete cascade,
  worked_on         date not null,
  hours             numeric(6,2) not null check (hours > 0 and hours <= 24),
  description       text not null default '',
  client_id         uuid references public.clients(id) on delete set null,
  statement_id      uuid references public.contractor_statements(id) on delete set null,
  corrects_id       uuid references public.work_sessions(id) on delete restrict,
  correction_reason text not null default '',
  voided            boolean not null default false,
  created_by        uuid references public.staff(id) on delete set null,
  created_at        timestamptz not null default now()
);
create index work_sessions_staff_idx on public.work_sessions (staff_id, worked_on desc);
create index work_sessions_statement_idx on public.work_sessions (statement_id);
create index work_sessions_corrects_idx on public.work_sessions (corrects_id) where corrects_id is not null;

-- A correction must say what it is correcting and why.
alter table public.work_sessions add constraint work_sessions_correction_needs_reason
  check (corrects_id is null or correction_reason <> '');

alter table public.work_sessions enable row level security;

create policy work_sessions_read on public.work_sessions
  for select to authenticated
  using (public.is_admin() or staff_id = public.current_staff_id());

create policy work_sessions_insert on public.work_sessions
  for insert to authenticated
  with check (
    (public.is_admin() or staff_id = public.current_staff_id())
    and created_by is not distinct from public.current_staff_id()
  );

-- Deliberately no update or delete policy. Time records are evidence: the only
-- way to change what they say is to add a correction that says so.

/**
 * Enforce the append-only rule in the database rather than by omitting a
 * button. Attaching a session to a statement is the one field that may change
 * after the fact, because that is bookkeeping rather than a claim about work.
 */
create or replace function public.work_sessions_append_only()
returns trigger language plpgsql as $$
begin
  if new.staff_id      is distinct from old.staff_id
  or new.worked_on     is distinct from old.worked_on
  or new.hours         is distinct from old.hours
  or new.description   is distinct from old.description
  or new.client_id     is distinct from old.client_id
  or new.corrects_id   is distinct from old.corrects_id
  or new.created_by    is distinct from old.created_by then
    raise exception
      'A time record cannot be edited. Add a correction referencing this entry and say why.'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create trigger work_sessions_no_edit before update on public.work_sessions
  for each row execute function public.work_sessions_append_only();

/**
 * A correction supersedes what it corrects, and the superseded row stops
 * counting towards any total. The history stays readable — that is the point.
 */
create or replace function public.work_sessions_apply_correction()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.corrects_id is not null then
    update public.work_sessions set voided = true where id = new.corrects_id;
  end if;
  return new;
end;
$$;

create trigger work_sessions_correction after insert on public.work_sessions
  for each row execute function public.work_sessions_apply_correction();

/**
 * Once a statement is approved the hours behind it are settled: nothing new
 * may be attached to it, and nothing already on it may be corrected away.
 * Correcting settled hours is a conversation, not a form.
 */
create or replace function public.work_sessions_respect_approval()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  s text;
begin
  if new.statement_id is not null then
    select status into s from public.contractor_statements where id = new.statement_id;
    if s = 'Approved' then
      raise exception 'That statement is approved and can no longer be changed.'
        using errcode = 'check_violation';
    end if;
  end if;

  if new.corrects_id is not null then
    select cs.status into s
      from public.work_sessions w
      join public.contractor_statements cs on cs.id = w.statement_id
     where w.id = new.corrects_id;
    if s = 'Approved' then
      raise exception
        'Those hours are on an approved statement. Ask Admin to reopen it before correcting them.'
        using errcode = 'check_violation';
    end if;
  end if;

  return new;
end;
$$;

create trigger work_sessions_approval_guard before insert on public.work_sessions
  for each row execute function public.work_sessions_respect_approval();

-- An approved statement is locked; only Admin may reopen it by returning it.
create or replace function public.statements_lock_when_approved()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if old.status = 'Approved' and new.status <> 'Approved' and not public.is_admin() then
    raise exception 'Only Admin can reopen an approved statement.'
      using errcode = 'insufficient_privilege';
  end if;

  if new.status = 'Submitted' and old.status <> 'Submitted' then
    new.submitted_at := coalesce(new.submitted_at, now());
  end if;

  if new.status in ('Approved', 'Returned') and old.status <> new.status then
    new.decided_at := now();
    new.decided_by := coalesce(new.decided_by, public.current_staff_id());
  end if;

  return new;
end;
$$;

create trigger statements_lock before update on public.contractor_statements
  for each row execute function public.statements_lock_when_approved();

-- ─────────────────────────────────────────────────────────────
-- Current roster
-- ─────────────────────────────────────────────────────────────
insert into public.staff_employment (staff_id, employment_type)
select id, case when role = 'Admin' then 'Employee' else 'Contractor' end
  from public.staff
on conflict (staff_id) do nothing;

-- ─────────────────────────────────────────────────────────────
-- Hours that count: the live sessions in a period, excluding anything a
-- correction has superseded.
-- ─────────────────────────────────────────────────────────────
create or replace view public.work_session_totals as
select w.staff_id,
       public.period_start(w.worked_on) as period_start,
       public.period_end(w.worked_on)   as period_end,
       sum(w.hours)                     as total_hours,
       count(*)                         as session_count
  from public.work_sessions w
 where not w.voided
 group by w.staff_id, public.period_start(w.worked_on), public.period_end(w.worked_on);

alter view public.work_session_totals set (security_invoker = true);
grant select on public.work_session_totals to authenticated;
