-- Zion Vocational Rehab CRM — 0012 list views, preferences, placeholder staff
--
-- Phase 6 A1: sorting, filtering and saved views on the Clients, Placements
-- and Authorizations lists.

-- ─────────────────────────────────────────────────────────────
-- A staff row with no email
--
-- The Billing seat exists as a slot before anyone fills it. That row must not
-- be invitable, so it carries no email — and an account with no email must not
-- be active, or is_active_staff() would let a nameless row hold access.
-- ─────────────────────────────────────────────────────────────
alter table public.staff alter column email drop not null;

alter table public.staff drop constraint if exists staff_active_needs_email;
alter table public.staff add constraint staff_active_needs_email
  check (active = false or email is not null);

insert into public.staff (legacy_id, name, email, role, active)
values ('s4', 'Billing (to be assigned)', null, 'Billing', false)
on conflict (legacy_id) do nothing;

-- ─────────────────────────────────────────────────────────────
-- When each client was last touched
--
-- "No activity in N days" is the filter that finds people who have quietly
-- stopped being worked. A view rather than a stored column: with a caseload
-- this size it costs nothing, and a column would need triggers on six tables
-- and would drift the first time one was missed.
-- ─────────────────────────────────────────────────────────────
create or replace view public.client_last_activity as
select c.id as client_id,
       greatest(
         coalesce((select max(n.ts) from public.notes n where n.client_id = c.id), 'epoch'::timestamptz),
         coalesce((select max(e.date::timestamptz) from public.service_entries e
                    join public.authorizations a on a.id = e.auth_id
                   where a.client_id = c.id), 'epoch'::timestamptz),
         coalesce((select max(cl.date::timestamptz) from public.contact_log cl where cl.client_id = c.id), 'epoch'::timestamptz),
         coalesce((select max(f.created_at) from public.forms f where f.client_id = c.id), 'epoch'::timestamptz),
         coalesce((select max(p.created_at) from public.placements p where p.client_id = c.id), 'epoch'::timestamptz),
         coalesce((select max(t.created_at) from public.tasks t where t.client_id = c.id), 'epoch'::timestamptz)
       ) as last_activity_at
  from public.clients c;

-- A view runs as its caller, so the notes a person cannot read do not count
-- towards their view of "last activity". That is the correct behaviour: the
-- date shown matches what they can actually see.
alter view public.client_last_activity set (security_invoker = true);

grant select on public.client_last_activity to authenticated;

-- ─────────────────────────────────────────────────────────────
-- Saved views
--
-- owner_staff_id null means shared — a default the whole team sees. Only
-- Admin creates those; everyone else keeps their own.
-- ─────────────────────────────────────────────────────────────
create table public.saved_views (
  id             uuid primary key default gen_random_uuid(),
  screen         text not null check (screen in ('clients', 'placements', 'authorizations')),
  name           text not null,
  owner_staff_id uuid references public.staff(id) on delete cascade,
  params         jsonb not null default '{}'::jsonb,
  sort_order     integer not null default 0,
  created_by     uuid references public.staff(id) on delete set null,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index saved_views_screen_idx on public.saved_views (screen, sort_order);
create unique index saved_views_name_idx
  on public.saved_views (screen, coalesce(owner_staff_id, '00000000-0000-0000-0000-000000000000'::uuid), lower(name));
create trigger saved_views_updated_at before update on public.saved_views
  for each row execute function public.set_updated_at();

alter table public.saved_views enable row level security;

create policy saved_views_read on public.saved_views
  for select to authenticated
  using (
    public.is_active_staff()
    and (owner_staff_id is null or owner_staff_id = public.current_staff_id())
  );

create policy saved_views_insert on public.saved_views
  for insert to authenticated
  with check (
    public.is_active_staff()
    and (
      owner_staff_id = public.current_staff_id()
      or (owner_staff_id is null and public.is_admin())
    )
  );

create policy saved_views_update on public.saved_views
  for update to authenticated
  using (owner_staff_id = public.current_staff_id() or (owner_staff_id is null and public.is_admin()))
  with check (owner_staff_id = public.current_staff_id() or (owner_staff_id is null and public.is_admin()));

create policy saved_views_delete on public.saved_views
  for delete to authenticated
  using (owner_staff_id = public.current_staff_id() or (owner_staff_id is null and public.is_admin()));

-- ─────────────────────────────────────────────────────────────
-- Per-person interface preferences — which view someone had open last.
-- Strictly their own; nobody needs to see anyone else's.
-- ─────────────────────────────────────────────────────────────
create table public.staff_prefs (
  staff_id   uuid not null references public.staff(id) on delete cascade,
  key        text not null,
  value      jsonb not null,
  updated_at timestamptz not null default now(),
  primary key (staff_id, key)
);

alter table public.staff_prefs enable row level security;

create policy staff_prefs_own on public.staff_prefs
  for all to authenticated
  using (staff_id = public.current_staff_id())
  with check (staff_id = public.current_staff_id());

-- ─────────────────────────────────────────────────────────────
-- Shared defaults the team starts with. Admin can edit or remove them.
-- ─────────────────────────────────────────────────────────────
insert into public.saved_views (screen, name, owner_staff_id, params, sort_order) values
  ('clients', 'Active caseload', null,
   '{"status":["Active"],"sort":"name","dir":"asc"}'::jsonb, 0),
  ('clients', 'Needs review', null,
   '{"hasImportReview":true,"sort":"name","dir":"asc"}'::jsonb, 1),
  ('clients', 'Quiet 30 days', null,
   '{"status":["Active"],"inactiveDays":30,"sort":"lastActivity","dir":"asc"}'::jsonb, 2),
  ('clients', 'In job development', null,
   '{"status":["Active"],"stage":["Job Development","Placement"],"sort":"lastActivity","dir":"asc"}'::jsonb, 3),
  ('authorizations', 'Open, hourly', null,
   '{"status":["Open"],"rateType":["Hourly"],"sort":"remaining","dir":"asc"}'::jsonb, 0),
  ('placements', 'Retention checks due', null,
   '{"missingCheck":true,"sort":"startDate","dir":"asc"}'::jsonb, 0)
on conflict do nothing;
