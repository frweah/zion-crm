-- Zion Vocational Rehab CRM — billing offices
--
-- USOR does not pay from the counselor's desk. Each counselor office bills
-- through a CRP billing office, and that office is who an unpaid invoice has
-- to be chased with: a billing address, and usually a named person behind it.
-- Until now the CRM knew the counselor and, loosely, their office - a free-text
-- field, one of which held a street address - and nothing past it.
--
-- So: billing offices are a record of their own, every counselor office
-- belongs to exactly one, and every client, authorization and invoice inherits
-- theirs through the counselor. Owner's mapping, confirmed 18 Sept 2026:
--
--   Downtown CRP      Salt Lake City
--   Valley West CRP   Taylorsville, and Tooele (a satellite of Taylorsville)
--   South Valley CRP  South Jordan (the office at 926 West Baxter Drive)
--   Davis CRP         Centerville
--   Spanish Fork      Spanish Fork - no group address yet, so the billing
--                     contact's own address is the To
--
-- Numbered 0091: the live database already holds 0087-0090 from the paused
-- client portal (branch `portal`), which main does not have yet.

-- ── billing offices ─────────────────────────────────────────
create table if not exists public.billing_offices (
  id                uuid primary key default gen_random_uuid(),
  name              text not null unique,
  -- Where a billing email goes. The office's group address where it has one;
  -- otherwise the billing contact's, and has_group_address says so.
  billing_email     text not null
                      check (billing_email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  has_group_address boolean not null default true,
  contact_name      text not null default '',
  contact_title     text not null default '',
  contact_email     text not null default ''
                      check (contact_email = '' or contact_email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  notes             text not null default '',
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

drop trigger if exists billing_offices_updated_at on public.billing_offices;
create trigger billing_offices_updated_at before update on public.billing_offices
  for each row execute function public.set_updated_at();

insert into public.billing_offices (name, billing_email, has_group_address, contact_name, contact_title, contact_email, notes)
values
  ('Downtown CRP', 'downtown-crp@utah.gov', true, 'Raynee Hill', 'Office specialist and primary billing contact', 'rlhill@utah.gov', ''),
  ('Valley West CRP', 'valleywest-crp@utah.gov', true, 'Cristy Furgeson', 'Office admin', 'cfurgeson@utah.gov', ''),
  ('South Valley CRP', 'southvalley-crp@utah.gov', true, 'Makenna Grubb', 'Office specialist', 'mgrubb@utah.gov', ''),
  ('Davis CRP', 'davis-crp@utah.gov', true, '', '', '', 'No named contact yet.'),
  ('Spanish Fork', 'heatherd1@utah.gov', false, 'Heather Davis', 'Billing contact', 'heatherd1@utah.gov',
   'No group billing address yet, so Heather''s own address is the To. She is also the Spanish Fork counselor on file.')
on conflict (name) do nothing;

-- ── offices belong to one ───────────────────────────────────
alter table public.offices add column if not exists billing_office_id uuid references public.billing_offices(id) on delete restrict;
alter table public.offices add column if not exists address text not null default '';
alter table public.offices add column if not exists note text not null default '';

insert into public.offices (name) values ('Tooele') on conflict (name) do nothing;

update public.offices o set billing_office_id = b.id
  from public.billing_offices b
 where o.billing_office_id is null
   and (o.name, b.name) in (
     ('Salt Lake City', 'Downtown CRP'),
     ('Taylorsville', 'Valley West CRP'),
     ('Tooele', 'Valley West CRP'),
     ('South Jordan', 'South Valley CRP'),
     ('Centerville', 'Davis CRP'),
     ('Spanish Fork', 'Spanish Fork'));

update public.offices set address = '926 West Baxter Drive, South Jordan, UT 84095'
 where name = 'South Jordan' and address = '';
update public.offices set note = 'Satellite of the Taylorsville office; bills through Valley West CRP.'
 where name = 'Tooele' and note = '';

do $$
begin
  if exists (select 1 from public.offices where billing_office_id is null) then
    raise exception 'An office has no billing office: %',
      (select string_agg(name, ', ') from public.offices where billing_office_id is null);
  end if;
end $$;

-- An office added later has to say where it bills.
alter table public.offices alter column billing_office_id set not null;

-- ── the counselors, as the owner confirmed them ─────────────
-- Each change names the row it expects, and refuses to guess if it is not
-- there - unless the change has already been made, so this can run twice.
do $$
declare
  v_n integer;
begin
  -- Joshua Madsen's office field held the South Jordan office's street address.
  update public.counselors
     set office = 'South Jordan', email = coalesce(nullif(email, ''), 'joshuamadsen@utah.gov')
   where name = 'Joshua Madsen' and office is distinct from 'South Jordan';
  get diagnostics v_n = row_count;
  if v_n = 0 and not exists (select 1 from public.counselors where name = 'Joshua Madsen' and office = 'South Jordan') then
    raise exception 'Joshua Madsen is not on file as expected';
  end if;

  -- Melani Morale on file; the owner confirms Melanie Fabre Morales, now downtown.
  update public.counselors
     set name = 'Melanie Fabre Morales', email = 'melaniefabre@utah.gov', office = 'Salt Lake City'
   where name = 'Melani Morale';
  get diagnostics v_n = row_count;
  if v_n = 0 and not exists (select 1 from public.counselors where name = 'Melanie Fabre Morales') then
    raise exception 'Melani Morale is not on file as expected';
  end if;

  update public.counselors set email = 'dinanielsen@utah.gov'
   where name = 'Dina Nielsen' and coalesce(email, '') = '';
  update public.counselors set email = 'matthewc@utah.gov'
   where name = 'Matt Christensen' and coalesce(email, '') = '';
end $$;

-- A counselor's office is one on file, so it always leads to a billing office.
-- Renaming an office carries its counselors with it.
do $$
begin
  if exists (select 1 from public.counselors k
              where k.office is not null and not exists (select 1 from public.offices o where o.name = k.office)) then
    raise exception 'Counselors with an office that is not on file: %',
      (select string_agg(k.name || ' (' || k.office || ')', ', ') from public.counselors k
        where k.office is not null and not exists (select 1 from public.offices o where o.name = k.office));
  end if;
end $$;

alter table public.counselors drop constraint if exists counselors_office_fkey;
alter table public.counselors add constraint counselors_office_fkey
  foreign key (office) references public.offices(name) on update cascade on delete restrict;

-- ── who each client bills through ───────────────────────────
-- The counselor's office decides: that is the USOR office that issued the
-- authorization, and so the one that pays it. A client with no counselor falls
-- back to their referring office. A client with neither has no billing office,
-- and says so rather than being guessed into one.
create or replace view public.client_billing_office with (security_invoker = true) as
select c.id                                           as client_id,
       coalesce(ko.name, ro.name)                     as office,
       b.id                                           as billing_office_id,
       b.name                                         as billing_office,
       case when ko.name is not null then 'Counselor''s office'
            when ro.name is not null then 'Referring office'
       end                                            as basis
  from public.clients c
  left join public.counselors k on k.id = c.counselor_id
  left join public.offices ko on ko.name = k.office
  left join public.offices ro on ro.name = nullif(c.referring_office, '')
  left join public.billing_offices b on b.id = coalesce(ko.billing_office_id, ro.billing_office_id);

comment on view public.client_billing_office is
  'Each client''s billing office: their counselor''s office''s, else their referring office''s, else none. Authorizations and invoices inherit their client''s.';

-- ── what to reconcile with one office ───────────────────────
-- Everything an office's billing team would want to see in one email: every
-- invoice sent to them and not yet paid, and every open authorization ending
-- within the window that still has value nobody has invoiced. Security invoker,
-- so it shows exactly what the person asking may see.
create or replace function public.billing_office_reconciliation(p_billing_office uuid, p_within_days integer default 30)
returns table (
  kind              text,
  client_id         uuid,
  client_name       text,
  counselor_id      uuid,
  counselor_name    text,
  counselor_email   text,
  auth_id           uuid,
  auth_number       text,
  service           text,
  invoice_number    text,
  amount            numeric,
  sent_on           date,
  days_outstanding  integer,
  end_date          date,
  unbilled          numeric
)
language sql stable security invoker set search_path = public as $$
  select 'Unpaid invoice'::text, c.id, c.name, k.id, k.name, nullif(trim(k.email), ''),
         a.id, a.number, coalesce(nullif(i.service_type, ''), a.service_type), i.number,
         i.amount, coalesce(i.sent_date, i.date),
         (public.practice_today() - coalesce(i.sent_date, i.date))::integer,
         a.end_date, null::numeric
    from public.invoices i
    join public.authorizations a on a.id = i.auth_id
    join public.clients c on c.id = a.client_id
    join public.client_billing_office cbo on cbo.client_id = c.id
    left join public.counselors k on k.id = c.counselor_id
   where i.status = 'Sent'
     and cbo.billing_office_id = p_billing_office
  union all
  select 'Ending soon, not fully invoiced'::text, c.id, c.name, k.id, k.name, nullif(trim(k.email), ''),
         a.id, a.number, a.service_type, null::text,
         null::numeric, null::date, null::integer,
         a.end_date, bp.not_yet_invoiced
    from public.billing_position bp
    join public.authorizations a on a.id = bp.auth_id
    join public.clients c on c.id = a.client_id
    join public.client_billing_office cbo on cbo.client_id = c.id
    left join public.counselors k on k.id = c.counselor_id
   where a.status = 'Open'
     and a.end_date between public.practice_today() and public.practice_today() + greatest(coalesce(p_within_days, 30), 0)
     and bp.not_yet_invoiced > 0
     and cbo.billing_office_id = p_billing_office
$$;

-- ── the contact log can name the office ─────────────────────
-- A reconciliation is written once per case it lists, so each client's history
-- shows it; this is what lets the office's own history be read back.
alter table public.contact_log add column if not exists billing_office_id uuid
  references public.billing_offices(id) on delete set null;
create index if not exists contact_log_billing_office_idx on public.contact_log (billing_office_id, date desc)
  where billing_office_id is not null;

-- ── rules ───────────────────────────────────────────────────
alter table public.billing_offices enable row level security;

drop policy if exists billing_offices_read on public.billing_offices;
create policy billing_offices_read on public.billing_offices for select to authenticated
  using (public.is_active_staff());

drop policy if exists billing_offices_admin_write on public.billing_offices;
create policy billing_offices_admin_write on public.billing_offices for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

revoke all on public.billing_offices from anon;
grant select, insert, update, delete on public.billing_offices to authenticated;
grant all on public.billing_offices to service_role;

revoke all on public.client_billing_office from anon;
grant select on public.client_billing_office to authenticated;

revoke execute on function public.billing_office_reconciliation(uuid, integer) from public, anon;
grant execute on function public.billing_office_reconciliation(uuid, integer) to authenticated, service_role;
