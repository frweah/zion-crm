-- ─────────────────────────────────────────────────────────────
-- 13.1 — what people are qualified to do, and until when
--
-- Five things to keep track of, and they are not the same shape:
--
--   ACRE            a certificate, earned once, no expiry
--   CPR/First Aid   expires, usually two years
--   Background check  expires, and until it is clear nobody works alone
--   Driver's licence  expires, and is only required of some people
--   Insurance         expires, same
--   CE hours          not a certificate at all — a running total against a
--                     yearly target
--
-- So the catalogue is data with a shape flag rather than a list of five
-- columns. The practice will add a credential nobody has thought of yet, and
-- that should be a row, not a deploy.
--
-- The other decision worth stating: a renewal is a new row, not an edit. A
-- CPR card that expired in March and was renewed in April is two facts, and
-- the question "were they covered on the day of that incident" needs both.
-- ─────────────────────────────────────────────────────────────

create table if not exists public.credential_types (
  key           text primary key,
  label         text not null,
  detail        text not null default '',

  -- 'certificate' is held or not held; 'hours' accumulates towards a target.
  kind          text not null default 'certificate'
                  check (kind in ('certificate', 'hours')),

  expires       boolean not null default true,
  -- Typical validity, offered as a default when recording one. Not enforced:
  -- the card says what it says.
  months_valid  integer,

  -- Who has to hold it. 'everyone' or 'drivers' — the second is anybody who
  -- transports clients, which is a property of the person and not the role.
  applies_to    text not null default 'everyone'
                  check (applies_to in ('everyone', 'drivers')),

  -- Hours per year, for the 'hours' kind.
  hours_target  numeric(6,2),

  -- How long before expiry to start saying so.
  warn_days     integer not null default 60,

  sort_order    integer not null default 100,
  active        boolean not null default true
);

alter table public.credential_types enable row level security;

drop policy if exists credential_types_read on public.credential_types;
drop policy if exists credential_types_write on public.credential_types;

create policy credential_types_read on public.credential_types
  for select to authenticated using (public.is_active_staff());
create policy credential_types_write on public.credential_types
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

insert into public.credential_types
  (key, label, detail, kind, expires, months_valid, applies_to, hours_target, warn_days, sort_order)
values
  ('acre', 'ACRE certificate',
   'Association of Community Rehabilitation Educators — the employment-services training USOR expects of a job coach.',
   'certificate', false, null, 'everyone', null, 60, 10),

  ('cpr', 'CPR and First Aid',
   'Current certification. Two years is the usual term.',
   'certificate', true, 24, 'everyone', null, 60, 20),

  ('background', 'Background check clearance',
   'BCI and FBI clearance. Nobody works unsupervised with a client without it.',
   'certificate', true, 24, 'everyone', null, 90, 30),

  ('licence', 'Driver''s licence',
   'Only for people who transport clients.',
   'certificate', true, null, 'drivers', null, 45, 40),

  ('insurance', 'Vehicle insurance',
   'Proof of cover, for anybody transporting clients in their own vehicle.',
   'certificate', true, 12, 'drivers', null, 45, 50),

  ('ce', 'Continuing education',
   'Hours towards the yearly requirement. Logged as they are done, with the provider and the topic.',
   'hours', false, null, 'everyone', 20, 60, 60)
on conflict (key) do update set
  label = excluded.label, detail = excluded.detail, kind = excluded.kind,
  expires = excluded.expires, months_valid = excluded.months_valid,
  applies_to = excluded.applies_to, hours_target = excluded.hours_target,
  warn_days = excluded.warn_days, sort_order = excluded.sort_order;

-- ─────────────────────────────────────────────────────────────
-- Who transports clients
--
-- A property of the person, not of their role: a job coach who does not drive
-- should not be chased for insurance, and an administrator who does should be.
-- ─────────────────────────────────────────────────────────────
alter table public.staff_employment
  add column if not exists transports_clients boolean not null default false;

comment on column public.staff_employment.transports_clients is
  'Whether this person carries clients in a vehicle. Decides whether a licence and insurance are required of them.';

-- ─────────────────────────────────────────────────────────────
-- The credentials themselves
-- ─────────────────────────────────────────────────────────────
create table if not exists public.staff_credentials (
  id           uuid primary key default gen_random_uuid(),
  staff_id     uuid not null references public.staff(id) on delete cascade,
  type_key     text not null references public.credential_types(key),

  -- What is on the card. Never a full licence number — see the check below.
  reference    text not null default '',
  issued_on    date,
  expires_on   date,

  -- The scan or photograph, if one was kept. staff_files is Admin-only, which
  -- is where a copy of somebody's licence belongs.
  file_id      uuid references public.staff_files(id) on delete set null,

  note         text not null default '',

  -- Who checked it, and when they had it in their hand. A credential nobody
  -- verified is somebody's word.
  verified_by  uuid references public.staff(id) on delete set null,
  verified_at  timestamptz,

  created_at   timestamptz not null default now(),
  created_by   uuid references public.staff(id) on delete set null,

  constraint staff_credentials_dates
    check (expires_on is null or issued_on is null or expires_on >= issued_on)
);

create index if not exists staff_credentials_staff_idx
  on public.staff_credentials (staff_id, type_key, expires_on desc nulls last);

alter table public.staff_credentials enable row level security;

drop policy if exists staff_credentials_read on public.staff_credentials;
drop policy if exists staff_credentials_write on public.staff_credentials;

-- Your own, or everybody's if you are Admin. A colleague's CPR card is not
-- something the rest of the practice needs to see.
create policy staff_credentials_read on public.staff_credentials
  for select to authenticated
  using (public.is_admin() or staff_id = public.current_staff_id());

-- Recording one is Admin's job: it is a check somebody performed, and a
-- person confirming their own credential is not a check.
create policy staff_credentials_write on public.staff_credentials
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- ─────────────────────────────────────────────────────────────
-- Continuing education, which is hours rather than a card
-- ─────────────────────────────────────────────────────────────
create table if not exists public.ce_entries (
  id          uuid primary key default gen_random_uuid(),
  staff_id    uuid not null references public.staff(id) on delete cascade,
  on_date     date not null,
  hours       numeric(5,2) not null check (hours > 0 and hours <= 40),
  topic       text not null,
  provider    text not null default '',
  file_id     uuid references public.staff_files(id) on delete set null,
  created_at  timestamptz not null default now(),
  created_by  uuid references public.staff(id) on delete set null
);

create index if not exists ce_entries_staff_idx on public.ce_entries (staff_id, on_date desc);

alter table public.ce_entries enable row level security;

drop policy if exists ce_entries_read on public.ce_entries;
drop policy if exists ce_entries_write on public.ce_entries;

create policy ce_entries_read on public.ce_entries
  for select to authenticated
  using (public.is_admin() or staff_id = public.current_staff_id());

-- Unlike a certificate, people log their own hours — they are the ones who
-- sat through the training. Admin can log them for somebody else.
create policy ce_entries_write on public.ce_entries
  for all to authenticated
  using (public.is_admin() or staff_id = public.current_staff_id())
  with check (public.is_admin() or staff_id = public.current_staff_id());

-- ─────────────────────────────────────────────────────────────
-- Where each person stands
--
-- One row per active staff member per credential they are required to hold,
-- plus any they hold that nobody requires — somebody with an extra
-- qualification should not have it disappear from their record.
--
-- The state is worked out here rather than on a screen, so the Staff list,
-- a person's own page and anything added later cannot disagree about whether
-- somebody's CPR card has run out.
-- ─────────────────────────────────────────────────────────────
create or replace view public.staff_credential_status as
with required as (
  select s.id as staff_id, t.key as type_key, t.label, t.kind, t.expires,
         t.warn_days, t.hours_target, t.applies_to, t.sort_order,
         -- Required of this person, as opposed to merely held by them.
         (t.applies_to = 'everyone'
          or coalesce(e.transports_clients, false))              as required
    from public.staff s
    cross join public.credential_types t
    left join public.staff_employment e on e.staff_id = s.id
   where s.active and t.active
),
latest as (
  -- The one that matters is the one that runs out last: a renewal recorded
  -- before the old card expired must not be shadowed by the old one.
  select distinct on (c.staff_id, c.type_key)
         c.staff_id, c.type_key, c.id as credential_id,
         c.issued_on, c.expires_on, c.reference, c.file_id,
         c.verified_at, c.verified_by
    from public.staff_credentials c
   order by c.staff_id, c.type_key, c.expires_on desc nulls first, c.created_at desc
),
ce as (
  select staff_id,
         sum(hours) filter (
           where on_date >= date_trunc('year', public.practice_today())::date
         ) as hours_this_year,
         max(on_date) as last_entry_on
    from public.ce_entries
   group by staff_id
)
select r.staff_id,
       r.type_key,
       r.label,
       r.kind,
       r.required,
       r.sort_order,
       l.credential_id,
       l.reference,
       l.issued_on,
       l.expires_on,
       l.file_id,
       l.verified_at,
       coalesce(c.hours_this_year, 0)                            as hours_this_year,
       r.hours_target,
       c.last_entry_on,

       case
         -- Hours are never "expired"; they are ahead or behind for the year.
         when r.kind = 'hours' then
           case
             when not r.required then 'Not required'
             when coalesce(c.hours_this_year, 0) >= coalesce(r.hours_target, 0) then 'Met'
             else 'Outstanding'
           end
         when l.credential_id is null then
           case when r.required then 'Missing' else 'Not held' end
         when not r.expires or l.expires_on is null then 'Valid'
         when l.expires_on < public.practice_today() then 'Expired'
         when l.expires_on <= public.practice_today() + r.warn_days then 'Expiring'
         else 'Valid'
       end                                                       as state,

       case when l.expires_on is null then null
            else l.expires_on - public.practice_today() end       as days_left

  from required r
  left join latest l on l.staff_id = r.staff_id and l.type_key = r.type_key
  left join ce c on c.staff_id = r.staff_id and r.kind = 'hours'
 where r.required or l.credential_id is not null;

alter view public.staff_credential_status set (security_invoker = true);
grant select on public.staff_credential_status to authenticated;

comment on view public.staff_credential_status is
  'Where each active staff member stands on each credential they must hold, plus any they hold without being required to. Missing, Expired, Expiring, Valid — or for continuing education, Met and Outstanding.';

-- ─────────────────────────────────────────────────────────────
-- What is wrong, across everybody
--
-- The list Admin actually needs: anything missing, expired, or about to be.
-- Ordered by how urgent it is rather than by name, because that is the order
-- somebody would work through it.
-- ─────────────────────────────────────────────────────────────
create or replace view public.credential_attention as
select s.staff_id,
       st.name        as staff_name,
       st.role        as staff_role,
       s.type_key,
       s.label,
       s.state,
       s.expires_on,
       s.days_left,
       s.hours_this_year,
       s.hours_target,
       case s.state
         when 'Expired'     then 1
         when 'Missing'     then 2
         when 'Expiring'    then 3
         when 'Outstanding' then 4
         else 9
       end            as urgency
  from public.staff_credential_status s
  join public.staff st on st.id = s.staff_id
 where s.state in ('Expired', 'Missing', 'Expiring', 'Outstanding');

alter view public.credential_attention set (security_invoker = true);
grant select on public.credential_attention to authenticated;
