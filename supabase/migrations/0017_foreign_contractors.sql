-- Zion Vocational Rehab CRM — 0017 foreign contractors, W-8BEN, tax alerts
--
-- Rei and Margaret are foreign persons working outside the United States. That
-- changes the paperwork entirely: a W-8BEN rather than a W-9, and no 1099-NEC
-- at all. Payments to a foreign person for services performed outside the US
-- are not US-source income and are not reported on a 1099.
--
-- The exclusion is enforced in the database rather than left to whichever
-- query builds the run, because putting a foreign contractor on a 1099 is the
-- kind of mistake that is discovered by the IRS rather than by us.

-- ─────────────────────────────────────────────────────────────
-- Tax status and the W-8BEN
-- ─────────────────────────────────────────────────────────────
alter table public.contractor_profiles
  add column if not exists tax_status text not null default 'US person'
    check (tax_status in ('US person', 'Foreign person')),
  add column if not exists country text not null default '',
  add column if not exists w8ben_received_on date;

/**
 * A W-8BEN is valid from the day it is signed through the last day of the
 * third succeeding calendar year — not three years to the day. One signed in
 * March 2026 runs to 31 December 2029, and treating it as March 2029 would
 * retire a form that is still good for nine months.
 */
alter table public.contractor_profiles
  add column if not exists w8ben_expires_on date
    generated always as (
      case when w8ben_received_on is null then null
           else make_date(extract(year from w8ben_received_on)::int + 3, 12, 31)
      end
    ) stored;

-- A US person files a W-9; a foreign person files a W-8BEN. Neither field
-- should be sitting filled in on the wrong kind of record.
alter table public.contractor_profiles drop constraint if exists contractor_profiles_paperwork;
alter table public.contractor_profiles add constraint contractor_profiles_paperwork
  check (
    (tax_status = 'US person'      and w8ben_received_on is null)
    or (tax_status = 'Foreign person' and w9_received_on is null)
  );

update public.contractor_profiles set tax_status = 'US person' where tax_status is null;

-- The current roster.
insert into public.contractor_profiles (staff_id, tax_status)
select s.id, 'Foreign person'
  from public.staff s
 where s.legacy_id in ('s2', 's3')
on conflict (staff_id) do update set tax_status = 'Foreign person';

-- ─────────────────────────────────────────────────────────────
-- W-8BEN is a document category too
-- ─────────────────────────────────────────────────────────────
alter table public.staff_files drop constraint if exists staff_files_category_check;
alter table public.staff_files add constraint staff_files_category_check
  check (category in ('W-9', 'W-8BEN', 'W-4', 'I-9', 'Signed policy',
                      'Direct deposit', 'Agreement', 'Other'));

-- ─────────────────────────────────────────────────────────────
-- The paperwork bucket is Admin-only at the object level
--
-- These files carry TINs and foreign tax identification numbers. The metadata
-- row stays visible to the person it belongs to, so they can see that their
-- W-8BEN is on file and when it expires — but the bytes are Admin's alone.
-- ─────────────────────────────────────────────────────────────
drop policy if exists "zion read staff files" on storage.objects;
create policy "zion read staff files" on storage.objects
  for select to authenticated
  using (bucket_id = 'staff-files' and public.is_admin());

-- ─────────────────────────────────────────────────────────────
-- Foreign persons are never on a 1099 run
-- ─────────────────────────────────────────────────────────────
create or replace function public.reject_foreign_1099()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_status text;
  v_name   text;
begin
  select p.tax_status, s.name into v_status, v_name
    from public.staff s
    left join public.contractor_profiles p on p.staff_id = s.id
   where s.id = new.staff_id;

  if v_status = 'Foreign person' then
    raise exception
      '% is a foreign person and cannot appear on a 1099-NEC. Payments for services performed outside the United States are not reported on this form.',
      coalesce(v_name, 'That contractor')
      using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

drop trigger if exists form_1099_no_foreign on public.form_1099_recipients;
create trigger form_1099_no_foreign
  before insert or update of staff_id on public.form_1099_recipients
  for each row execute function public.reject_foreign_1099();

/**
 * Who a run should actually cover: US persons, paid at or above the confirmed
 * threshold in that calendar year. Foreign persons are excluded here as well
 * as by the trigger — one keeps them off the list, the other makes sure they
 * cannot be put back on it by hand.
 */
create or replace function public.form_1099_candidates(p_year integer)
returns table (
  staff_id         uuid,
  staff_name       text,
  legal_name       text,
  business_name    text,
  address_snapshot text,
  tin_type         text,
  tin_last4        text,
  total_paid       numeric,
  w9_received_on   date,
  ready            boolean,
  problem          text
)
language sql stable security invoker as $$
  select s.id,
         s.name,
         coalesce(nullif(p.legal_name, ''), s.name),
         coalesce(p.business_name, ''),
         trim(both ', ' from concat_ws(', ', nullif(p.address_line1, ''), nullif(p.address_line2, ''),
                                        nullif(p.city, ''), nullif(p.state, ''), nullif(p.postal_code, ''))),
         p.tin_type,
         p.tin_last4,
         t.total_paid,
         p.w9_received_on,
         (p.tin_last4 is not null and p.w9_received_on is not null
            and coalesce(nullif(p.legal_name, ''), s.name) <> ''
            and nullif(p.address_line1, '') is not null),
         nullif(concat_ws('; ',
           case when p.tin_last4 is null then 'no TIN on file' end,
           case when p.w9_received_on is null then 'no W-9 on file' end,
           case when nullif(p.address_line1, '') is null then 'no address' end), '')
    from public.contractor_year_totals t
    join public.staff s on s.id = t.staff_id
    left join public.contractor_profiles p on p.staff_id = s.id
    join public.tax_years y on y.year = p_year
   where t.year = p_year
     and coalesce(p.tax_status, 'US person') = 'US person'
     and y.federal_threshold is not null
     and t.total_paid >= y.federal_threshold;
$$;

grant execute on function public.form_1099_candidates(integer) to authenticated;
