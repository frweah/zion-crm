-- Zion Vocational Rehab CRM — a billing office for each of the sixteen
-- (owner, 14 Oct 2026, having been asked rather than guessed at)
--
-- The USOR roster brought in sixteen offices with no CRP billing office, and
-- 0195 left the column null on purpose: it decides where an authorization
-- packet is emailed, and the five billing offices on file are all Salt Lake
-- area ones with no relationship to Logan or St. George.
--
-- The owner's answer was one billing office per district, with the billing
-- address left blank until USOR publishes one. That is worth saying plainly,
-- because at first glance it looks like it achieves nothing: a packet for a
-- client at one of these is still refused. The difference is *which* refusal.
--
--   Before: the office had no billing office at all, so there was nothing on
--   screen to fill in and nothing to tell a person what was missing.
--
--   Now: the office bills through a named district CRP whose address is not
--   yet known, which is a row somebody can type one address into - and until
--   they do, submitAuthorization says "there is no billing office address for
--   <client>" and sends nothing.
--
-- Neither state mails paperwork to the wrong district, which was the whole
-- point of not guessing. This one names the thing that is missing.
--
-- The names follow the five already on file - Downtown CRP, Valley West CRP,
-- South Valley CRP, Davis CRP - and are the district's, not the city's,
-- because that is what USOR calls the unit that does the billing.
--
-- Each carries its district office's own main line in the notes, so whoever
-- chases the address has the number to ring in front of them.

select set_config('zion.directory_reason',
  'One billing office per USOR district, address to follow (owner, 14 Oct 2026)', true);

create temp table district_crp (office text primary key, crp text not null);
insert into district_crp (office, crp) values
  ('Logan',                                  'Northern Utah CRP'),
  ('Brigham City',                           'Brigham City CRP'),
  ('Ogden',                                  'Ogden CRP'),
  ('Center of the Deaf and Hard of Hearing', 'Deaf and Hard of Hearing CRP'),
  ('Provo',                                  'Provo CRP'),
  ('Heber City',                             'Heber City CRP'),
  ('Delta',                                  'Delta CRP'),
  ('Manti',                                  'Manti CRP'),
  ('Richfield',                              'Richfield CRP'),
  ('Vernal',                                 'Eastern Utah CRP'),
  ('Price',                                  'Price CRP'),
  ('Roosevelt',                              'Roosevelt CRP'),
  ('Blanding',                               'Blanding CRP'),
  ('Moab',                                   'Moab CRP'),
  ('St. George',                             'Southern Utah CRP'),
  ('Cedar City',                             'Cedar City CRP');

/**
 * Every office named here has to be one that is actually waiting.
 *
 * If a later roster renames an office, or somebody sets one of these by hand
 * first, this migration should say so rather than quietly creating a billing
 * office nothing points at. Sixteen in, sixteen matched, or it stops.
 */
do $$
declare
  v_missing text;
  v_taken   text;
begin
  select string_agg(d.office, ', ' order by d.office) into v_missing
    from district_crp d
   where not exists (select 1 from public.offices o where o.name = d.office);
  if v_missing is not null then
    raise exception 'These offices are not on file: %', v_missing
      using hint = 'The roster may have renamed them. Check before creating billing offices nothing points at.';
  end if;

  select string_agg(format('%s -> %s', o.name, b.name), ', ' order by o.name) into v_taken
    from district_crp d
    join public.offices o on o.name = d.office
    join public.billing_offices b on b.id = o.billing_office_id;
  if v_taken is not null then
    raise exception 'These already bill somewhere: %', v_taken
      using hint = 'Somebody set them since the roster was imported. Leave their decision alone.';
  end if;
end $$;

-- ── the billing offices ─────────────────────────────────────
insert into public.billing_offices (name, billing_email, has_group_address, notes)
select d.crp, '', false,
       format('No billing address published yet. The %s main line is %s. Until USOR gives a '
              || 'billing address, a packet for a client here is refused rather than sent to the '
              || 'wrong district.', o.usor_district, nullif(o.phone, ''))
  from district_crp d
  join public.offices o on o.name = d.office
 where not exists (select 1 from public.billing_offices b where b.name = d.crp);

-- ── and the offices point at them ───────────────────────────
update public.offices o
   set billing_office_id = b.id
  from district_crp d
  join public.billing_offices b on b.name = d.crp
 where o.name = d.office
   and o.billing_office_id is null;

select set_config('zion.directory_reason', '', true);

-- ── what happened ───────────────────────────────────────────
do $$
declare
  r record;
begin
  raise notice '';
  raise notice '=== A BILLING OFFICE FOR EACH DISTRICT ===';
  raise notice '  billing offices now: %', (select count(*) from public.billing_offices);
  raise notice '  offices with none left: %',
    (select count(*) from public.offices where billing_office_id is null);
  raise notice '  billing offices with no address yet: %',
    (select count(*) from public.billing_offices where billing_email = '');
  raise notice '';
  for r in select o.name as office, o.usor_district, b.name as crp
             from public.offices o join public.billing_offices b on b.id = o.billing_office_id
             join district_crp d on d.office = o.name
            order by o.name loop
    raise notice '  % (%) -> %', r.office, r.usor_district, r.crp;
  end loop;
  raise notice '';
  raise notice '  Each needs one thing: the billing address USOR sends warrants from.';
  raise notice '  Counselors -> Billing offices is where it gets typed in.';
  raise notice '=== END ===';
end $$;
