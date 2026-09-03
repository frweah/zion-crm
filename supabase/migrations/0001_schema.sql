-- Zion Vocational Rehab CRM — 0001 schema
-- Ported from zion-crm-prototype.jsx state shape. The prototype is the product spec.
-- Roles: Admin (owner) | Job Search | Reports (Intake & Reports) | Billing

create extension if not exists pgcrypto;

-- ─────────────────────────────────────────────────────────────
-- Shared helpers
-- ─────────────────────────────────────────────────────────────
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ─────────────────────────────────────────────────────────────
-- Staff (linked to Supabase Auth users)
-- A staff row is created first (invite flow); user_id is filled in when the
-- invited person accepts and an auth user exists.
-- ─────────────────────────────────────────────────────────────
create table public.staff (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid unique references auth.users(id) on delete set null,
  legacy_id       text unique,                       -- 's1'..'s4' from the prototype
  name            text not null,
  email           text not null unique,
  phone           text,
  role            text not null check (role in ('Admin','Job Search','Reports','Billing')),
  active          boolean not null default true,
  invited_at      timestamptz,
  accepted_at     timestamptz,
  deactivated_at  timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index staff_user_id_idx on public.staff (user_id) where user_id is not null;
create index staff_role_active_idx on public.staff (role) where active;
create trigger staff_updated_at before update on public.staff
  for each row execute function public.set_updated_at();

-- Offboarding: deactivating must remove access the same moment.
create or replace function public.staff_deactivation_stamp()
returns trigger language plpgsql as $$
begin
  if new.active = false and old.active = true then
    new.deactivated_at = now();
  elsif new.active = true and old.active = false then
    new.deactivated_at = null;
  end if;
  return new;
end;
$$;
create trigger staff_deactivation before update on public.staff
  for each row execute function public.staff_deactivation_stamp();

-- ─────────────────────────────────────────────────────────────
-- Reference data
-- ─────────────────────────────────────────────────────────────
create table public.offices (
  name text primary key
);

create table public.rate_schedule (
  id              uuid primary key default gen_random_uuid(),
  funding_source  text not null default 'Utah VR',   -- multi-funder ready (spec 3d)
  service         text not null,
  sub             text not null default '',
  fee             numeric(10,2) not null,
  unit            text not null check (unit in ('flat','per hour')),
  effective_from  date,
  effective_to    date
);
create unique index rate_schedule_key_idx
  on public.rate_schedule (funding_source, service, sub, coalesce(effective_from, '1900-01-01'::date));

create table public.counselors (
  id          uuid primary key default gen_random_uuid(),
  legacy_id   text unique,                            -- 'k1'..'k19'
  name        text not null,
  agency      text not null default 'Utah State Office of Rehabilitation',
  office      text,
  phone       text,
  fax         text,
  email       text,
  notes       text not null default '',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create trigger counselors_updated_at before update on public.counselors
  for each row execute function public.set_updated_at();

-- ─────────────────────────────────────────────────────────────
-- Clients
-- Non-restricted columns live here; DOB and address are in client_private,
-- which carries the restricted-tier RLS policy.
-- ─────────────────────────────────────────────────────────────
create table public.clients (
  id                uuid primary key default gen_random_uuid(),
  legacy_id         text unique,                      -- 'c1001'
  client_no         integer unique,
  ghl_id            text unique,                      -- kept so GHL stays reconcilable
  name              text not null,
  agency_id         text not null default '',         -- USOR client / agency ID
  funding_source    text not null default 'Utah VR',
  caseload          text not null default '',
  unit              text not null default '',
  counselor_id      uuid references public.counselors(id) on delete set null,
  counselor_contact text not null default '',
  referring_office  text not null default '',
  phone             text not null default '',
  email             text not null default '',
  gender            text not null default '',
  schedule          text not null default '',
  target_jobs       text not null default '',
  ce                boolean not null default false,   -- competitive integrated employment flag
  wsa_tier          integer check (wsa_tier in (1,2)),
  wsa_completed     date,
  wsa_submitted     date,
  wsa_paid          date,
  status            text not null default 'Active' check (status in ('Active','Closed')),
  assigned_staff_id uuid references public.staff(id) on delete set null,
  stage             text not null default 'Referral' check (stage in
                      ('Referral','Intake','Assessment','Job Development',
                       'Placement','Job Coaching','Follow-Along','Closed')),
  import_review     text not null default '',         -- migration flag, preserved
  created_at        date not null default current_date,
  updated_at        timestamptz not null default now()
);
create index clients_assigned_staff_idx on public.clients (assigned_staff_id);
create index clients_counselor_idx on public.clients (counselor_id);
create index clients_stage_idx on public.clients (stage);
create trigger clients_updated_at before update on public.clients
  for each row execute function public.set_updated_at();

-- Restricted tier: DOB and address (kickoff, "Restricted fields").
create table public.client_private (
  client_id   uuid primary key references public.clients(id) on delete cascade,
  dob         date,
  address     text not null default '',
  updated_at  timestamptz not null default now()
);
create trigger client_private_updated_at before update on public.client_private
  for each row execute function public.set_updated_at();

create table public.client_stage_history (
  id          uuid primary key default gen_random_uuid(),
  client_id   uuid not null references public.clients(id) on delete cascade,
  stage       text not null,
  at          date not null default current_date,
  staff_id    uuid references public.staff(id) on delete set null,
  created_at  timestamptz not null default now()
);
create index client_stage_history_client_idx on public.client_stage_history (client_id, at);

-- ─────────────────────────────────────────────────────────────
-- Intake — restricted tier as a whole: it carries disability,
-- accommodation, address and emergency-contact content (spec 3b).
-- ─────────────────────────────────────────────────────────────
create table public.intakes (
  id              uuid primary key default gen_random_uuid(),
  client_id       uuid not null unique references public.clients(id) on delete cascade,
  phone           text not null default '',
  email           text not null default '',
  address         text not null default '',
  emergency_name  text not null default '',
  emergency_phone text not null default '',
  goals           text not null default '',
  availability    text not null default '',
  transportation  text not null default 'Own vehicle',
  accommodations  text not null default '',
  consent_signed  boolean not null default false,
  submitted_at    date not null default current_date,
  updated_on      date,
  staff_id        uuid references public.staff(id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  -- An intake cannot be submitted without the consent box (prototype rule).
  constraint intakes_consent_required check (consent_signed)
);
create trigger intakes_updated_at before update on public.intakes
  for each row execute function public.set_updated_at();

-- ─────────────────────────────────────────────────────────────
-- Authorizations, service log, completions, invoices
-- ─────────────────────────────────────────────────────────────
create table public.authorizations (
  id              uuid primary key default gen_random_uuid(),
  legacy_id       text unique,
  client_id       uuid not null references public.clients(id) on delete cascade,
  number          text not null default '',           -- USOR authorization number
  service_type    text not null,
  funding_source  text not null default 'Utah VR',
  total_hours     numeric(8,2),
  carried_used    numeric(8,2) not null default 0,    -- hours already used before migration
  rate_type       text not null check (rate_type in ('Hourly','Flat Fee')),
  rate            numeric(10,2) not null default 0,
  start_date      date,
  end_date        date,
  status          text not null default 'Open' check (status in ('Open','Paid','Closed')),
  requires_forms  text not null default '',
  note            text not null default '',
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint authorizations_hourly_needs_hours
    check (rate_type <> 'Hourly' or total_hours is not null)
);
create index authorizations_client_idx on public.authorizations (client_id);
create index authorizations_status_idx on public.authorizations (status);
create trigger authorizations_updated_at before update on public.authorizations
  for each row execute function public.set_updated_at();

create table public.service_entries (
  id             uuid primary key default gen_random_uuid(),
  auth_id        uuid not null references public.authorizations(id) on delete cascade,
  date           date not null,
  hours          numeric(6,2) not null check (hours > 0),
  notes          text not null default '',
  non_billable   boolean not null default false,
  primary_code   text not null default '',
  secondary_code text not null default '',
  staff_id       uuid references public.staff(id) on delete set null,
  created_at     timestamptz not null default now()
  -- Hours are never logged ahead of the day the service happened. That rule
  -- lives in the trigger in 0002: a CHECK constraint cannot call current_date.
);
create index service_entries_auth_idx on public.service_entries (auth_id, date);

create table public.completions (
  id          uuid primary key default gen_random_uuid(),
  legacy_id   text unique,
  auth_id     uuid not null references public.authorizations(id) on delete cascade,
  start_date  date,
  completion  date,
  notes       text not null default '',
  billed      boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index completions_auth_idx on public.completions (auth_id);
create trigger completions_updated_at before update on public.completions
  for each row execute function public.set_updated_at();

create table public.invoices (
  id            uuid primary key default gen_random_uuid(),
  legacy_id     text unique,
  auth_id       uuid not null references public.authorizations(id) on delete cascade,
  number        text not null default '',
  date          date not null default current_date,
  amount        numeric(10,2) not null check (amount >= 0),
  status        text not null default 'Draft' check (status in ('Draft','Sent','Paid','Void')),
  sent_date     date,
  paid_date     date,
  warrant       text not null default '',
  voucher       text not null default '',
  payee         text not null default '',
  service_type  text not null default '',
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index invoices_auth_idx on public.invoices (auth_id);
create index invoices_status_idx on public.invoices (status);
create trigger invoices_updated_at before update on public.invoices
  for each row execute function public.set_updated_at();

create table public.placements (
  id            uuid primary key default gen_random_uuid(),
  legacy_id     text unique,
  client_id     uuid not null references public.clients(id) on delete cascade,
  employer      text not null default '',
  title         text not null default '',
  start_date    date,
  wage          numeric(8,2),
  hours_week    numeric(5,2),
  check30       date,
  check60       date,
  check90       date,
  jp_submitted  date,
  jp_paid       date,
  notes         text not null default '',
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index placements_client_idx on public.placements (client_id);
create trigger placements_updated_at before update on public.placements
  for each row execute function public.set_updated_at();

-- ─────────────────────────────────────────────────────────────
-- Tasks and notes
-- ─────────────────────────────────────────────────────────────
create table public.tasks (
  id                uuid primary key default gen_random_uuid(),
  legacy_id         text unique,
  client_id         uuid references public.clients(id) on delete cascade,
  assigned_staff_id uuid references public.staff(id) on delete set null,
  title             text not null,
  due               date,
  status            text not null default 'Open' check (status in ('Open','Done')),
  done_at           date,
  created_by        uuid references public.staff(id) on delete set null,
  system_generated  boolean not null default false,   -- prototype createdBy = 'system'
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
create index tasks_assigned_idx on public.tasks (assigned_staff_id) where status = 'Open';
create index tasks_client_idx on public.tasks (client_id);
create trigger tasks_updated_at before update on public.tasks
  for each row execute function public.set_updated_at();

create table public.notes (
  id            uuid primary key default gen_random_uuid(),
  legacy_id     text unique,
  client_id     uuid not null references public.clients(id) on delete cascade,
  staff_id      uuid references public.staff(id) on delete set null,
  staff_name    text not null default '',            -- kept for imported/legacy attribution
  text          text not null,
  type          text not null default 'General',
  at            date not null default current_date,
  ts            timestamptz not null default now(),
  visible_roles text[] not null default array['Admin','Job Search','Reports','Billing'],
  created_at    timestamptz not null default now()
);
create index notes_client_idx on public.notes (client_id, ts desc);
create index notes_roles_idx on public.notes using gin (visible_roles);

-- ─────────────────────────────────────────────────────────────
-- DWS-USOR forms
-- Template field definitions stay in application code (FORM_TEMPLATES);
-- this table holds only the metadata the database needs to enforce rules.
-- ─────────────────────────────────────────────────────────────
create table public.form_templates (
  id                   text primary key,              -- 'usor60', 'wsa', ...
  usor                 text not null,                 -- 'DWS-USOR 60'
  name                 text not null,
  services             text[] not null default '{}',
  required_for_billing boolean not null default false,
  monthly              boolean not null default false,
  incoming             boolean not null default false,
  sensitive            boolean not null default false, -- restricted tier (USOR 94 / 98)
  sort_order           integer not null default 0
);

create table public.forms (
  id                uuid primary key default gen_random_uuid(),
  template_id       text not null references public.form_templates(id),
  client_id         uuid not null references public.clients(id) on delete cascade,
  auth_id           uuid references public.authorizations(id) on delete set null,
  month             text,                             -- 'YYYY-MM' for monthly reports
  status            text not null default 'Draft' check (status in ('Draft','Completed','Sent')),
  data              jsonb not null default '{}'::jsonb,
  sensitive         boolean not null default false,   -- mirrored from the template
  created_by        uuid references public.staff(id) on delete set null,
  created_by_name   text not null default '',
  created_at        timestamptz not null default now(),
  completed_by      uuid references public.staff(id) on delete set null,
  completed_by_name text not null default '',
  completed_at      timestamptz,
  sent_at           timestamptz,
  sent_to           text not null default '',
  updated_at        timestamptz not null default now()
);
create index forms_client_idx on public.forms (client_id);
create index forms_auth_idx on public.forms (auth_id, template_id);
create index forms_status_idx on public.forms (status);
create trigger forms_updated_at before update on public.forms
  for each row execute function public.set_updated_at();

-- ─────────────────────────────────────────────────────────────
-- Counselor contact log and additional-hours requests
-- ─────────────────────────────────────────────────────────────
create table public.contact_log (
  id             uuid primary key default gen_random_uuid(),
  legacy_id      text unique,
  counselor_id   uuid references public.counselors(id) on delete set null,
  client_id      uuid references public.clients(id) on delete cascade,
  date           date not null default current_date,
  method         text not null default 'Phone call',
  topic          text not null default '',
  outcome        text not null default '',
  follow_up      date,
  follow_up_done boolean not null default false,
  staff_id       uuid references public.staff(id) on delete set null,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index contact_log_counselor_idx on public.contact_log (counselor_id, date desc);
create index contact_log_followup_idx on public.contact_log (follow_up)
  where follow_up is not null and not follow_up_done;
create trigger contact_log_updated_at before update on public.contact_log
  for each row execute function public.set_updated_at();

create table public.hours_requests (
  id            uuid primary key default gen_random_uuid(),
  auth_id       uuid references public.authorizations(id) on delete cascade,
  counselor_id  uuid references public.counselors(id) on delete set null,
  date          date not null default current_date,
  hours         numeric(6,2),
  reason        text not null default '',
  response      text not null default 'Pending' check (response in ('Pending','Approved','Denied')),
  approved      numeric(6,2),
  approved_date date,
  staff_id      uuid references public.staff(id) on delete set null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index hours_requests_auth_idx on public.hours_requests (auth_id);
create trigger hours_requests_updated_at before update on public.hours_requests
  for each row execute function public.set_updated_at();

-- ─────────────────────────────────────────────────────────────
-- SOPs
-- ─────────────────────────────────────────────────────────────
create table public.sops (
  id          uuid primary key default gen_random_uuid(),
  legacy_id   text unique,
  title       text not null,
  roles       text[] not null default array['Admin','Job Search','Reports','Billing'],
  body        text not null default '',
  screen      text,                                   -- links an SOP to the screen it describes
  sort_order  integer not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create trigger sops_updated_at before update on public.sops
  for each row execute function public.set_updated_at();
