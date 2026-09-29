-- Zion Vocational Rehab CRM — the billing item: one record per client,
-- service and service period (Billing Lifecycle Brief, from Margaret's
-- "Billing Process & Workflow"; owner decisions 29 Sept 2026)
--
-- What the practice had was an authorization, some hours, a form and later an
-- invoice, each true on its own and none of them the thing Margaret actually
-- tracks: a piece of work for one client, in one period, that has to be
-- finished, checked, sent, and paid. That is the item. Everything already
-- built stays where it is - this is the spine those bones hang from.
--
-- The rules that are the practice's, not the software's, are rows rather than
-- code (billing_service_rules): which forms a service needs, whether it
-- recurs, and what makes it ready to bill. Job Coaching is the only service
-- that recurs monthly; everything else is one item per authorization.
--
-- What the database refuses, rather than asks nicely:
--
--   Two items for the same client, service and period. The second is refused
--   and the caller is told which one already exists (her control 12.6).
--
--   An item whose service is not the service its authorization is for.
--
--   Ready for billing while the service is still in progress (12.1).
--
--   Submitted without a submission date and a recipient - the send action
--   sets it, never a person choosing a status (12.8).
--
--   Paid without a payment date and an amount - the warrant match sets it,
--   or a logged manual payment (12.9).
--
--   Closed without a reason. Closed then locks the item; reopening is
--   Admin's and is logged like everything else.
--
--   Service dates that were copied from the authorization. They are asked
--   for separately and stay separate: an authorization runs from one date to
--   another, and the work happened when it happened (her §4).
--
-- Every move from one status to the next is written down with who and when,
-- because a correction six weeks later is read by somebody who was not there.

-- ── what each service needs, as rows ───────────────────────
create table if not exists public.billing_service_rules (
  service text primary key,
  recurrence text not null check (recurrence in ('Monthly', 'One-time')),
  usor_forms text[] not null default '{}',
  ready_rule text not null check (ready_rule in ('service complete', 'month complete', 'weeks after first work day', 'indicator answered')),
  ready_weeks integer,
  billing_type text not null check (billing_type in ('Flat Fee', 'Hourly')),
  hq_separable boolean not null default false,
  active boolean not null default true,
  note text,
  updated_at timestamptz not null default now()
);

comment on table public.billing_service_rules is
  'Which forms a service needs, whether it recurs, and what makes it ready to bill (0123). Rows because the practice changes these, not the software.';

insert into public.billing_service_rules (service, recurrence, usor_forms, ready_rule, ready_weeks, billing_type, hq_separable, note) values
  ('Job Coaching',                  'Monthly',  array['95','93'], 'month complete',              null, 'Hourly',   false, 'The only service that recurs. Hours logged in the month it was worked.'),
  ('Job Development',               'One-time', array['96'],      'service complete',            null, 'Flat Fee', false, null),
  ('Job Development + HQ Indicator','One-time', array['96'],      'service complete',            null, 'Flat Fee', true,  null),
  ('Job Search',                    'One-time', array['96'],      'service complete',            null, 'Flat Fee', false, null),
  ('Job Placement',                 'One-time', array['60','92'], 'weeks after first work day',     4, 'Flat Fee', true,  'Both forms are required, and it is billable four weeks after the client''s first day of work.'),
  ('Job Placement (SE)',            'One-time', array['60','92'], 'weeks after first work day',     4, 'Flat Fee', true,  null),
  ('WSA Tier 1',                    'One-time', array['94'],      'service complete',            null, 'Hourly',   false, null),
  ('WSA Tier 2',                    'One-time', array['94'],      'service complete',            null, 'Hourly',   false, null),
  ('Job Readiness',                 'One-time', array['148'],     'service complete',            null, 'Flat Fee', false, null),
  ('Life Skills',                   'One-time', array['148'],     'service complete',            null, 'Flat Fee', false, null),
  ('CRP Group Training',            'One-time', array['148'],     'service complete',            null, 'Flat Fee', false, null),
  ('Supported Employment',          'One-time', array['148'],     'service complete',            null, 'Flat Fee', false, null),
  ('Other',                         'One-time', array[]::text[],  'service complete',            null, 'Flat Fee', false, 'No form of its own; whatever the authorization names is attached by hand.')
on conflict (service) do nothing;

-- ── the item ───────────────────────────────────────────────
create table if not exists public.billing_items (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.clients(id) on delete cascade,
  auth_id uuid references public.authorizations(id) on delete set null,
  service text not null,
  -- The month, for a service that recurs; null for a one-time item, which is
  -- a milestone rather than a period.
  period date,
  status text not null default 'Authorization received',
  -- Asked for, never inherited from the authorization (her §4).
  service_start date,
  service_end date,
  -- Job Placement's milestone starts here, not at the authorization.
  first_work_day date,
  assigned_staff_id uuid references public.staff(id) on delete set null,
  billing_type text check (billing_type in ('Flat Fee', 'Hourly')),
  hours numeric(10, 2),
  rate numeric(10, 2),
  amount numeric(10, 2),
  invoice_id uuid references public.invoices(id) on delete set null,
  recipient text,
  submitted_at timestamptz,
  submitted_by uuid references public.staff(id) on delete set null,
  paid_on date,
  paid_amount numeric(10, 2),
  warrant text,
  correction_note text,
  followup_due date,
  -- A coaching month with no hours: flagged first, and only skipped once
  -- somebody says it really was a month with no service.
  zero_hours_flagged boolean not null default false,
  zero_hours_confirmed_by uuid references public.staff(id) on delete set null,
  zero_hours_confirmed_at timestamptz,
  signed_auth_path text,
  closed_reason text,
  closed_at timestamptz,
  closed_by uuid references public.staff(id) on delete set null,
  notes text,
  created_at timestamptz not null default now(),
  created_by uuid references public.staff(id) on delete set null,
  updated_at timestamptz not null default now(),

  constraint billing_items_status_known check (status in (
    'Referral received', 'Authorization received', 'Service in progress',
    'Service period complete', 'Ready for billing', 'Billing review',
    'Submitted', 'Pending', 'Correction needed', 'Paid', 'Closed'
  )),
  -- Submitted is what the send action leaves behind, and it leaves both.
  constraint billing_items_submitted_has_both check (
    status not in ('Submitted', 'Pending', 'Correction needed', 'Paid')
    or (submitted_at is not null and recipient is not null)
  ),
  constraint billing_items_paid_has_payment check (
    status <> 'Paid' or (paid_on is not null and paid_amount is not null)
  ),
  constraint billing_items_closed_has_reason check (
    status <> 'Closed' or (closed_reason is not null and btrim(closed_reason) <> '')
  ),
  constraint billing_items_period_is_a_month check (
    period is null or date_trunc('month', period)::date = period
  ),
  constraint billing_items_service_dates_in_order check (
    service_start is null or service_end is null or service_end >= service_start
  )
);

comment on table public.billing_items is
  'One piece of billable work: a client, a service, and a period (0123). The spine of Margaret''s process.';
comment on column public.billing_items.period is
  'The month, for Job Coaching. Null for a one-time service, which is a milestone rather than a period.';
comment on column public.billing_items.service_start is
  'When the work actually started. Never copied from the authorization (her §4) - the two answer different questions.';

-- One item per client, service and period. A null period is one particular
-- period - the one-time one - not "any", so nulls are not distinct here.
create unique index if not exists billing_items_one_per_period
  on public.billing_items (client_id, service, period) nulls not distinct;

create index if not exists billing_items_client_idx on public.billing_items (client_id);
create index if not exists billing_items_auth_idx on public.billing_items (auth_id);
create index if not exists billing_items_status_idx on public.billing_items (status);
create index if not exists billing_items_assigned_idx on public.billing_items (assigned_staff_id);
create index if not exists billing_items_followup_idx on public.billing_items (followup_due) where followup_due is not null;

-- ── what happened to it, and who did it ────────────────────
create table if not exists public.billing_item_events (
  id uuid primary key default gen_random_uuid(),
  item_id uuid not null references public.billing_items(id) on delete cascade,
  at timestamptz not null default now(),
  staff_id uuid references public.staff(id) on delete set null,
  staff_name text,
  was text,
  became text,
  note text
);

create index if not exists billing_item_events_item_idx on public.billing_item_events (item_id, at desc);

comment on table public.billing_item_events is
  'Every move from one status to the next, with who and when (0123, her 12.10). A correction six weeks later is read by somebody who was not there.';

-- ── the rules the database keeps for itself ────────────────

/**
 * Refuses the things that cannot be true of an item, and writes down every
 * change of status.
 *
 * The order matters: an item that is locked is locked before anything else
 * is considered, so a closed item cannot be quietly corrected on its way to
 * being reopened.
 */
create or replace function public.billing_items_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_auth_service text;
  v_role text := public.current_staff_role();
  v_staff uuid := public.current_staff_id();
  v_name text;
begin
  if tg_op = 'UPDATE' then
    -- Closed locks it. Admin reopens, and that is a status change like any
    -- other, so it is written down below.
    if old.status = 'Closed' and new.status = 'Closed' and v_role is distinct from 'Admin' then
      raise exception 'This item is closed. Reopening it is Admin''s, and is recorded.'
        using errcode = 'check_violation';
    end if;
    if old.status = 'Closed' and new.status <> 'Closed' and v_role is distinct from 'Admin' then
      raise exception 'Only an Admin reopens a closed item.' using errcode = 'check_violation';
    end if;
  end if;

  -- The item's service is the authorization's service, or there is no honest
  -- way to read what was billed.
  if new.auth_id is not null then
    select a.service_type into v_auth_service from public.authorizations a where a.id = new.auth_id;
    if v_auth_service is distinct from new.service then
      raise exception 'This authorization is for % - it cannot carry a % item.', v_auth_service, new.service
        using errcode = 'check_violation';
    end if;
  end if;

  -- Ready for billing is a statement that the work is finished (12.1).
  if new.status in ('Ready for billing', 'Billing review', 'Submitted', 'Pending', 'Correction needed', 'Paid')
     and tg_op = 'UPDATE' and old.status = 'Service in progress'
     and new.status not in ('Service period complete') then
    if new.service_end is null and new.first_work_day is null then
      raise exception 'The service is still in progress: record when it finished before billing it.'
        using errcode = 'check_violation';
    end if;
  end if;

  new.updated_at := now();

  if tg_op = 'UPDATE' and new.status is distinct from old.status then
    select s.name into v_name from public.staff s where s.id = v_staff;
    insert into public.billing_item_events (item_id, staff_id, staff_name, was, became, note)
    values (new.id, v_staff, v_name, old.status, new.status,
            case when new.status = 'Closed' then new.closed_reason
                 when new.status = 'Correction needed' then new.correction_note end);
  end if;

  return new;
end;
$$;
revoke execute on function public.billing_items_guard() from public, anon, authenticated;

drop trigger if exists billing_items_guard_trigger on public.billing_items;
create trigger billing_items_guard_trigger before insert or update on public.billing_items
  for each row execute function public.billing_items_guard();

/** The first line of an item's history: that it was made, and by whom. */
create or replace function public.billing_items_opened()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_staff uuid := public.current_staff_id(); v_name text;
begin
  select s.name into v_name from public.staff s where s.id = v_staff;
  insert into public.billing_item_events (item_id, staff_id, staff_name, was, became, note)
  values (new.id, v_staff, v_name, null, new.status, 'Item opened');
  return new;
end;
$$;
revoke execute on function public.billing_items_opened() from public, anon, authenticated;

drop trigger if exists billing_items_opened_trigger on public.billing_items;
create trigger billing_items_opened_trigger after insert on public.billing_items
  for each row execute function public.billing_items_opened();

-- ── who may see and change one ─────────────────────────────
-- Billing's, and the client's people's. Reading follows the client, as
-- everywhere else; changing is Billing's, a billing grant's, or Admin's,
-- because an item is a billing record even when the work was somebody else's.
alter table public.billing_items enable row level security;
alter table public.billing_item_events enable row level security;
alter table public.billing_service_rules enable row level security;

drop policy if exists billing_items_select on public.billing_items;
create policy billing_items_select on public.billing_items for select to authenticated
  using (
    (select public.current_staff_role()) = any (array['Admin', 'Billing', 'Reports', 'Job Search'])
    or (select public.staff_has_area('billing', 'view'))
  );

drop policy if exists billing_items_write on public.billing_items;
create policy billing_items_write on public.billing_items for all to authenticated
  using (
    (select public.current_staff_role()) = any (array['Admin', 'Billing'])
    or (select public.staff_has_area('billing', 'edit'))
  )
  with check (
    (select public.current_staff_role()) = any (array['Admin', 'Billing'])
    or (select public.staff_has_area('billing', 'edit'))
  );

drop policy if exists billing_item_events_select on public.billing_item_events;
create policy billing_item_events_select on public.billing_item_events for select to authenticated
  using (
    (select public.current_staff_role()) = any (array['Admin', 'Billing', 'Reports', 'Job Search'])
    or (select public.staff_has_area('billing', 'view'))
  );

drop policy if exists billing_service_rules_select on public.billing_service_rules;
create policy billing_service_rules_select on public.billing_service_rules for select to authenticated
  using (true);

drop policy if exists billing_service_rules_write on public.billing_service_rules;
create policy billing_service_rules_write on public.billing_service_rules for all to authenticated
  using ((select public.current_staff_role()) = 'Admin')
  with check ((select public.current_staff_role()) = 'Admin');

-- History is written by the trigger and never edited by hand: no insert,
-- update or delete policy exists for anybody.

select public.apply_system_read_only('public.billing_items'::regclass);
select public.apply_system_read_only('public.billing_item_events'::regclass);
select public.apply_system_read_only('public.billing_service_rules'::regclass);

grant select on public.billing_items to authenticated;
grant insert, update, delete on public.billing_items to authenticated;
grant select on public.billing_item_events to authenticated;
grant select on public.billing_service_rules to authenticated;
grant insert, update, delete on public.billing_service_rules to authenticated;
