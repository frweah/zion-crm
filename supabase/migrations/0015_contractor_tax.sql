-- Zion Vocational Rehab CRM — 0015 contractor profiles, payments, 1099 groundwork
--
-- Phase 6 B2a. Everything a 1099-NEC run needs, and the settings that make the
-- January workflow buildable before the CPA has confirmed the figures: the
-- federal threshold is a value Admin enters each year, and the Utah state copy
-- is a switch. Neither is hardcoded, because both change and neither is ours
-- to decide.

-- ─────────────────────────────────────────────────────────────
-- Owner as an employment type
--
-- An owner is neither an employee nor a contractor of their own company, and
-- calling them either in the record would be wrong in a file an auditor reads.
-- ─────────────────────────────────────────────────────────────
alter table public.staff_employment drop constraint if exists staff_employment_employment_type_check;
alter table public.staff_employment add constraint staff_employment_employment_type_check
  check (employment_type in ('Owner', 'Employee', 'Contractor'));

update public.staff_employment
   set employment_type = 'Owner'
 where staff_id in (select id from public.staff where role = 'Admin' and legacy_id = 's1');

-- ─────────────────────────────────────────────────────────────
-- A contractor may see their own rate
--
-- They agreed it and they invoice against it. What stays private is everybody
-- else's.
-- ─────────────────────────────────────────────────────────────
drop policy if exists staff_pay_admin on public.staff_pay;

create policy staff_pay_read on public.staff_pay
  for select to authenticated
  using (public.is_admin() or staff_id = public.current_staff_id());

create policy staff_pay_write on public.staff_pay
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- ─────────────────────────────────────────────────────────────
-- Tax settings, per year
--
-- The threshold is entered each January once the CPA confirms the figure in
-- force. Until it is confirmed the year is unusable for a run, which is the
-- correct behaviour: a 1099 generated against a guessed threshold is worse
-- than one not yet generated.
-- ─────────────────────────────────────────────────────────────
create table public.tax_years (
  year              integer primary key check (year between 2020 and 2100),
  federal_threshold numeric(10,2),
  utah_state_copy   boolean not null default false,
  confirmed_by      uuid references public.staff(id) on delete set null,
  confirmed_on      date,
  notes             text not null default '',
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
create trigger tax_years_updated_at before update on public.tax_years
  for each row execute function public.set_updated_at();

alter table public.tax_years enable row level security;
create policy tax_years_read on public.tax_years
  for select to authenticated using (public.is_active_staff());
create policy tax_years_write on public.tax_years
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- Seeded unconfirmed on purpose — the figure is the CPA's to give.
insert into public.tax_years (year) values (extract(year from current_date)::int - 1)
on conflict (year) do nothing;
insert into public.tax_years (year) values (extract(year from current_date)::int)
on conflict (year) do nothing;

-- ─────────────────────────────────────────────────────────────
-- Contractor profiles
--
-- The TIN is the one field here that would matter most if this database were
-- ever copied. It is encrypted with a key held in Supabase Vault, never stored
-- in a readable column, and reachable only through a function that checks the
-- caller is Admin. What is stored in the clear is the last four digits, which
-- is what a person needs to confirm they are looking at the right record.
-- ─────────────────────────────────────────────────────────────
create table public.contractor_profiles (
  staff_id       uuid primary key references public.staff(id) on delete cascade,
  legal_name     text not null default '',
  business_name  text not null default '',
  address_line1  text not null default '',
  address_line2  text not null default '',
  city           text not null default '',
  state          text not null default '',
  postal_code    text not null default '',
  tin_type       text check (tin_type in ('SSN', 'EIN')),
  tin_encrypted  bytea,
  tin_last4      text,
  w9_received_on date,
  notes          text not null default '',
  updated_at     timestamptz not null default now()
);
create trigger contractor_profiles_updated_at before update on public.contractor_profiles
  for each row execute function public.set_updated_at();

alter table public.contractor_profiles enable row level security;

-- A contractor may see their own profile — their address and whether their W-9
-- is on file is theirs to check. tin_encrypted is unreadable regardless.
create policy contractor_profiles_read on public.contractor_profiles
  for select to authenticated
  using (public.is_admin() or staff_id = public.current_staff_id());

create policy contractor_profiles_write on public.contractor_profiles
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- The key lives in Vault, not in this file and not in the table.
do $$
begin
  if not exists (select 1 from vault.secrets where name = 'zion_tin_key') then
    perform vault.create_secret(
      encode(gen_random_bytes(32), 'base64'),
      'zion_tin_key',
      'Encrypts contractor TINs at rest (migration 0015)'
    );
  end if;
end $$;

create or replace function public.set_contractor_tin(p_staff_id uuid, p_tin text, p_tin_type text)
returns void
language plpgsql security definer set search_path = public, vault
as $$
declare
  k      text;
  digits text := regexp_replace(coalesce(p_tin, ''), '\D', '', 'g');
begin
  if not public.is_admin() then
    raise exception 'Only Admin can record a TIN.' using errcode = 'insufficient_privilege';
  end if;
  if length(digits) <> 9 then
    raise exception 'A TIN is nine digits.' using errcode = 'check_violation';
  end if;
  if p_tin_type not in ('SSN', 'EIN') then
    raise exception 'TIN type must be SSN or EIN.' using errcode = 'check_violation';
  end if;

  select decrypted_secret into k from vault.decrypted_secrets where name = 'zion_tin_key';
  if k is null then
    raise exception 'The TIN encryption key is missing from Vault.';
  end if;

  insert into public.contractor_profiles (staff_id, tin_type, tin_encrypted, tin_last4)
  values (p_staff_id, p_tin_type, pgp_sym_encrypt(digits, k), right(digits, 4))
  on conflict (staff_id) do update set
    tin_type = excluded.tin_type,
    tin_encrypted = excluded.tin_encrypted,
    tin_last4 = excluded.tin_last4;
end;
$$;

create or replace function public.get_contractor_tin(p_staff_id uuid)
returns text
language plpgsql security definer set search_path = public, vault
as $$
declare
  k text;
  e bytea;
begin
  if not public.is_admin() then
    raise exception 'Only Admin can read a TIN.' using errcode = 'insufficient_privilege';
  end if;

  select tin_encrypted into e from public.contractor_profiles where staff_id = p_staff_id;
  if e is null then return null; end if;

  select decrypted_secret into k from vault.decrypted_secrets where name = 'zion_tin_key';
  return pgp_sym_decrypt(e, k);
end;
$$;

revoke execute on function public.set_contractor_tin(uuid, text, text) from public;
revoke execute on function public.get_contractor_tin(uuid) from public;
grant execute on function public.set_contractor_tin(uuid, text, text) to authenticated;
grant execute on function public.get_contractor_tin(uuid) to authenticated;

-- Nobody reads the ciphertext column directly, including Admin.
revoke select (tin_encrypted) on public.contractor_profiles from authenticated;

-- ─────────────────────────────────────────────────────────────
-- Staff documents — W-9s, signed policies, onboarding paperwork
-- ─────────────────────────────────────────────────────────────
create table public.staff_files (
  id            uuid primary key default gen_random_uuid(),
  staff_id      uuid not null references public.staff(id) on delete cascade,
  storage_path  text not null unique,
  filename      text not null,
  mime_type     text not null default '',
  size_bytes    bigint not null default 0,
  category      text not null default 'Other' check (category in
                  ('W-9', 'W-4', 'I-9', 'Signed policy', 'Direct deposit', 'Agreement', 'Other')),
  note          text not null default '',
  uploaded_by   uuid references public.staff(id) on delete set null,
  created_at    timestamptz not null default now()
);
create index staff_files_staff_idx on public.staff_files (staff_id, created_at desc);

alter table public.staff_files enable row level security;

create policy staff_files_read on public.staff_files
  for select to authenticated
  using (public.is_admin() or staff_id = public.current_staff_id());
create policy staff_files_insert on public.staff_files
  for insert to authenticated
  with check (public.is_admin() and uploaded_by is not distinct from public.current_staff_id());
create policy staff_files_delete on public.staff_files
  for delete to authenticated using (public.is_admin());

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('staff-files', 'staff-files', false, 26214400,
        array['application/pdf', 'image/jpeg', 'image/png', 'image/heic', 'image/webp',
              'application/msword',
              'application/vnd.openxmlformats-officedocument.wordprocessingml.document'])
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "zion read staff files" on storage.objects;
create policy "zion read staff files" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'staff-files'
    and exists (
      select 1 from public.staff_files f
       where f.storage_path = storage.objects.name
         and (public.is_admin() or f.staff_id = public.current_staff_id())
    )
  );

drop policy if exists "zion write staff files" on storage.objects;
create policy "zion write staff files" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'staff-files' and public.is_admin());

drop policy if exists "zion delete staff files" on storage.objects;
create policy "zion delete staff files" on storage.objects
  for delete to authenticated
  using (bucket_id = 'staff-files' and public.is_admin());

create or replace function public.delete_staff_file_object()
returns trigger language plpgsql security definer set search_path = public, storage as $$
begin
  delete from storage.objects where bucket_id = 'staff-files' and name = old.storage_path;
  return old;
end;
$$;
create trigger staff_files_delete_object after delete on public.staff_files
  for each row execute function public.delete_staff_file_object();

-- ─────────────────────────────────────────────────────────────
-- Payments
--
-- What was actually paid, and when. This is what a 1099-NEC reports, so it is
-- recorded per payment rather than inferred from statements: the IRS form
-- reports money that changed hands in the calendar year, not hours worked in it.
-- ─────────────────────────────────────────────────────────────
create table public.contractor_payments (
  id           uuid primary key default gen_random_uuid(),
  staff_id     uuid not null references public.staff(id) on delete cascade,
  statement_id uuid references public.contractor_statements(id) on delete set null,
  paid_on      date not null,
  amount       numeric(10,2) not null check (amount > 0),
  method       text not null default 'Check'
                 check (method in ('Check', 'ACH', 'Cash', 'Zelle', 'Other')),
  reference    text not null default '',
  note         text not null default '',
  created_by   uuid references public.staff(id) on delete set null,
  created_at   timestamptz not null default now()
);
create index contractor_payments_staff_idx on public.contractor_payments (staff_id, paid_on desc);
create index contractor_payments_year_idx on public.contractor_payments (extract(year from paid_on));

alter table public.contractor_payments enable row level security;

create policy contractor_payments_read on public.contractor_payments
  for select to authenticated
  using (public.is_admin() or staff_id = public.current_staff_id());
create policy contractor_payments_write on public.contractor_payments
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- Calendar-year totals, which is the figure that goes in box 1.
create or replace view public.contractor_year_totals as
select staff_id,
       extract(year from paid_on)::int as year,
       sum(amount)                     as total_paid,
       count(*)                        as payment_count,
       max(paid_on)                    as last_paid_on
  from public.contractor_payments
 group by staff_id, extract(year from paid_on);

alter view public.contractor_year_totals set (security_invoker = true);
grant select on public.contractor_year_totals to authenticated;

-- ─────────────────────────────────────────────────────────────
-- 1099-NEC runs
--
-- A run is a generation event for a year. Recipients are frozen into it, so a
-- form that was delivered can still be reproduced exactly, and a correction is
-- a new recipient row that points at the one it corrects.
-- ─────────────────────────────────────────────────────────────
create table public.form_1099_runs (
  id           uuid primary key default gen_random_uuid(),
  year         integer not null references public.tax_years(year),
  threshold    numeric(10,2) not null,
  state_copy   boolean not null default false,
  generated_at timestamptz not null default now(),
  generated_by uuid references public.staff(id) on delete set null,
  filed_on     date,
  iris_receipt text not null default '',
  notes        text not null default ''
);
create index form_1099_runs_year_idx on public.form_1099_runs (year, generated_at desc);

create table public.form_1099_recipients (
  id                uuid primary key default gen_random_uuid(),
  run_id            uuid not null references public.form_1099_runs(id) on delete cascade,
  staff_id          uuid not null references public.staff(id) on delete cascade,
  legal_name        text not null,
  business_name     text not null default '',
  address_snapshot  text not null default '',
  tin_type          text,
  tin_last4         text,
  nonemployee_comp  numeric(12,2) not null,
  corrected         boolean not null default false,
  corrects_id       uuid references public.form_1099_recipients(id) on delete set null,
  delivered_on      date,
  delivery_method   text check (delivery_method in ('Secure download', 'Email', 'Post', 'In person')),
  consent_recorded  boolean not null default false,
  created_at        timestamptz not null default now()
);
create index form_1099_recipients_run_idx on public.form_1099_recipients (run_id);
create index form_1099_recipients_staff_idx on public.form_1099_recipients (staff_id);

alter table public.form_1099_runs enable row level security;
alter table public.form_1099_recipients enable row level security;

create policy form_1099_runs_admin on public.form_1099_runs
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- A contractor may see their own 1099 — it is their tax document.
create policy form_1099_recipients_read on public.form_1099_recipients
  for select to authenticated
  using (public.is_admin() or staff_id = public.current_staff_id());
create policy form_1099_recipients_write on public.form_1099_recipients
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
