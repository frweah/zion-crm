-- Zion Vocational Rehab CRM — vendors on the 1099 run (ERP brief, E3)
--
-- "Vendor 1099s join the existing 1099 pipeline where applicable." They do,
-- rather than getting a second pipeline of their own: one run, one threshold,
-- one list of what is not ready to file, and one tie-out at the end of the
-- year. Two pipelines would mean two places to discover in February that a
-- W-9 was missing.
--
-- A recipient was a staff member. It is now a staff member or a vendor,
-- exactly one of the two, which is the smallest change that makes the
-- existing run work for both: everything a 1099 needs - the legal name, the
-- address as it stood, the last four digits of the tax number, the total
-- paid - is snapshotted on the recipient row already and does not care which
-- kind of payee it came from.
--
-- One thing found on the way, and worth the owner knowing: the migration
-- history's copy of generate_1099_run (0023) names a column the database no
-- longer has - contractor_profiles.e_delivery_consent, renamed to
-- e_delivery_consent_on. The live function worked, so it had been changed in
-- the database without a migration, and the history alone could not have
-- rebuilt it. The body below is reconstructed and held to verify_1099.sql,
-- which pins the threshold rules, the not-ready list, the freezing and the
-- foreign-person rule.

alter table public.form_1099_recipients
  alter column staff_id drop not null,
  add column if not exists vendor_id uuid references public.vendors(id) on delete restrict;

alter table public.form_1099_recipients
  drop constraint if exists form_1099_recipients_one_payee;
alter table public.form_1099_recipients
  add constraint form_1099_recipients_one_payee
  check ((staff_id is not null) <> (vendor_id is not null));

comment on column public.form_1099_recipients.vendor_id is
  'The vendor this 1099 is for, where it is not a contractor (0149). Exactly one of staff_id and vendor_id is set.';

-- A filed row is frozen, the payee included whichever kind it is.
create or replace function public.freeze_1099_recipient()
returns trigger language plpgsql as $$
begin
  if new.legal_name is distinct from old.legal_name
     or new.business_name is distinct from old.business_name
     or new.address_snapshot is distinct from old.address_snapshot
     or new.tin_type is distinct from old.tin_type
     or new.tin_last4 is distinct from old.tin_last4
     or new.nonemployee_comp is distinct from old.nonemployee_comp
     or new.staff_id is distinct from old.staff_id
     or new.vendor_id is distinct from old.vendor_id
     or new.run_id is distinct from old.run_id then
    raise exception
      'What is on a 1099 run is what was filed. Issue a corrected return instead of editing it.'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

-- The foreign-person rule is about contractors; a row with no staff_id has
-- no contractor profile to read and is left alone by it.
create or replace function public.reject_foreign_1099()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_status text;
  v_name   text;
begin
  if new.staff_id is null then
    return new;
  end if;

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

-- ─────────────────────────────────────────────────────────────
-- Which vendors are candidates
--
-- Paid in the year means paid: a bill marked paid on a day in that year.
-- What the ledger posted is checked against this by the tie-out, which is
-- the point of having both.
-- ─────────────────────────────────────────────────────────────
create or replace function public.vendor_1099_candidates(p_year integer)
returns table (
  vendor_id uuid,
  vendor_name text,
  legal_name text,
  business_name text,
  address_snapshot text,
  tin_type text,
  tin_last4 text,
  total_paid numeric,
  w9_received_on date,
  ready boolean,
  problem text
) language sql stable security invoker set search_path = public as $$
  with paid as (
    select b.vendor_id, sum(b.amount) as total
      from public.vendor_bills b
     where b.status = 'Paid' and extract(year from b.paid_on) = p_year
     group by b.vendor_id
  )
  select v.id, v.name,
         v.name, '', v.address,
         v.tin_type, v.tin_last4,
         p.total, v.w9_received_on,
         v.w9_on_file and v.tin_type is not null and v.tin_last4 is not null
           and coalesce(btrim(v.address), '') <> '',
         btrim(concat_ws('; ',
           case when not v.w9_on_file then 'no W-9 on file' end,
           case when v.tin_last4 is null then 'no tax number recorded' end,
           case when coalesce(btrim(v.address), '') = '' then 'no address' end))
    from public.vendors v
    join paid p on p.vendor_id = v.id
   where v.gets_1099
     and p.total >= coalesce(
       (select t.federal_threshold from public.tax_years t where t.year = p_year), 600)
   order by v.name;
$$;

comment on function public.vendor_1099_candidates is
  'Vendors the practice marked as getting a 1099, paid at or over the year''s threshold, and what is missing (0149).';

revoke all on function public.vendor_1099_candidates(integer) from anon, authenticated;
grant execute on function public.vendor_1099_candidates(integer) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- One run, both kinds of payee
--
-- Recreated whole, as a function body must be. verify_1099.sql holds every
-- rule this had - the unconfirmed threshold, the nobody-over-it case, the
-- not-ready list - so a rule lost here fails a script.
-- ─────────────────────────────────────────────────────────────
create or replace function public.generate_1099_run(p_year integer)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_run       uuid;
  v_year      record;
  v_problems  text;
  v_count     int;
begin
  if not public.is_admin() then
    raise exception 'Only Admin can generate a 1099 run.' using errcode = 'insufficient_privilege';
  end if;

  select * into v_year from public.tax_years where year = p_year;
  if v_year is null or v_year.federal_threshold is null then
    raise exception 'The % federal threshold has not been set.', p_year
      using errcode = 'check_violation';
  end if;
  if v_year.confirmed_on is null then
    raise exception 'The % threshold has not been confirmed. Nothing is filed on an unconfirmed figure.', p_year
      using errcode = 'check_violation';
  end if;

  select (select count(*) from public.form_1099_candidates(p_year))
       + (select count(*) from public.vendor_1099_candidates(p_year))
    into v_count;
  if v_count = 0 then
    raise exception 'Nobody was paid % or more in %.', v_year.federal_threshold, p_year
      using errcode = 'check_violation';
  end if;

  select string_agg(line, '; ' order by line) into v_problems
    from (
      select format('%s (%s)', staff_name, problem) as line
        from public.form_1099_candidates(p_year) where not ready
      union all
      select format('%s (%s)', vendor_name, problem) as line
        from public.vendor_1099_candidates(p_year) where not ready
    ) t;

  if v_problems is not null then
    raise exception 'These are not ready to file: %', v_problems
      using errcode = 'check_violation';
  end if;

  insert into public.form_1099_runs (year, threshold, state_copy, generated_by)
  values (p_year, v_year.federal_threshold, v_year.utah_state_copy, public.current_staff_id())
  returning id into v_run;

  insert into public.form_1099_recipients (
    run_id, staff_id, legal_name, business_name, address_snapshot,
    tin_type, tin_last4, nonemployee_comp, consent_recorded
  )
  select v_run, c.staff_id, c.legal_name, c.business_name, c.address_snapshot,
         c.tin_type, c.tin_last4, c.total_paid,
         -- Consent is a day it was given, not a flag (0075 renamed it).
         coalesce((select p.e_delivery_consent_on is not null from public.contractor_profiles p
                    where p.staff_id = c.staff_id), false)
    from public.form_1099_candidates(p_year) c;

  insert into public.form_1099_recipients (
    run_id, vendor_id, legal_name, business_name, address_snapshot,
    tin_type, tin_last4, nonemployee_comp, consent_recorded
  )
  select v_run, c.vendor_id, c.legal_name, c.business_name, c.address_snapshot,
         c.tin_type, c.tin_last4, c.total_paid, false
    from public.vendor_1099_candidates(p_year) c;

  return v_run;
end;
$$;

revoke execute on function public.generate_1099_run(integer) from public, anon;
grant execute on function public.generate_1099_run(integer) to authenticated;

comment on function public.generate_1099_run is
  'One run for the year, covering contractors and 1099 vendors alike (0149). Refuses while anything is not ready to file.';

-- ─────────────────────────────────────────────────────────────
-- And the tie-out covers both
-- ─────────────────────────────────────────────────────────────
create or replace function public.ledger_1099_tie_out(p_year integer)
returns table (
  staff_id uuid, person text,
  recorded numeric, posted numeric, on_the_1099 numeric, difference numeric
) language sql stable set search_path = public as $$
  with recorded as (
    select p.staff_id as payee, null::uuid as vendor, sum(p.amount) as amount
      from public.contractor_payments p
     where extract(year from p.paid_on) = p_year
     group by p.staff_id
    union all
    select null::uuid, b.vendor_id, sum(b.amount)
      from public.vendor_bills b
     where b.status = 'Paid' and extract(year from b.paid_on) = p_year
     group by b.vendor_id
  ),
  posted as (
    select l.staff_id as payee, l.vendor_id as vendor, sum(l.debit) - sum(l.credit) as amount
      from public.journals j
      join public.journal_lines l on l.journal_id = j.id
      join public.ledger_accounts a on a.id = l.account_id
       and a.role in ('contractor_payable', 'ap')
     where extract(year from j.entry_date) = p_year
       and j.source_kind in ('Contractor payment', 'Vendor bill')
       and j.source_event like 'Paid%'
     group by l.staff_id, l.vendor_id
  ),
  filed as (
    select r.staff_id as payee, r.vendor_id as vendor, r.nonemployee_comp as amount
      from public.form_1099_recipients r
      join public.form_1099_runs u on u.id = r.run_id
     where u.year = p_year
       and r.id = (
         select r2.id from public.form_1099_recipients r2
           join public.form_1099_runs u2 on u2.id = r2.run_id
          where u2.year = p_year
            and r2.staff_id is not distinct from r.staff_id
            and r2.vendor_id is not distinct from r.vendor_id
          order by r2.created_at desc limit 1)
  ),
  everybody as (
    select payee, vendor from recorded
    union select payee, vendor from posted
    union select payee, vendor from filed
  )
  select e.payee,
         coalesce(s.name, v.name, 'Unknown'),
         coalesce((select amount from recorded r where r.payee is not distinct from e.payee
                                                  and r.vendor is not distinct from e.vendor), 0),
         coalesce((select amount from posted p where p.payee is not distinct from e.payee
                                                 and p.vendor is not distinct from e.vendor), 0),
         coalesce((select amount from filed f where f.payee is not distinct from e.payee
                                                and f.vendor is not distinct from e.vendor), 0),
         coalesce((select amount from recorded r where r.payee is not distinct from e.payee
                                                  and r.vendor is not distinct from e.vendor), 0)
           - coalesce((select amount from posted p where p.payee is not distinct from e.payee
                                                     and p.vendor is not distinct from e.vendor), 0)
    from everybody e
    left join public.staff s on s.id = e.payee
    left join public.vendors v on v.id = e.vendor
   order by 2;
$$;

comment on function public.ledger_1099_tie_out is
  'What was recorded paid, what the ledger posted, and what the 1099 said, for every contractor and 1099 vendor (0149).';

revoke all on function public.ledger_1099_tie_out(integer) from anon, authenticated;
grant execute on function public.ledger_1099_tie_out(integer) to authenticated;
