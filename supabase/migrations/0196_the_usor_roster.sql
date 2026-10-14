-- Zion Vocational Rehab CRM — the USOR roster, imported
-- (owner, 14 Oct 2026, from the published offices-and-counselors list)
--
-- Twenty-two offices and a hundred counselors, from Logan to St. George. The
-- directory held six offices and nineteen counselors, all of them places and
-- people the practice already deals with; this is the rest of the state, so
-- that a referral from an office nobody has billed yet arrives at a record
-- that already exists.
--
-- The data is written out here rather than read from the CSV at run time, so
-- what was imported is in git and can be read line by line. Generated, not
-- typed: a typo in one of a hundred rows is a counselor nobody can email.
--
-- ── the rules this follows, which are the owner's ───────────
--
-- Matched on email first and then on name. The email match is exact and
-- case-insensitive, which is what catches Josh Madsen against the Joshua
-- Madsen on file - they share an address. The name match uses
-- directory_name_key() from 0195, which collapses the short forms this roster
-- gives evidence for and nothing else.
--
-- A stored email or phone is never replaced by a blank. Thirty-four of the
-- hundred rows say "No email published", and five of those are people already
-- on file with a working address - so those five rows add nothing but the
-- office, exactly as asked.
--
-- A stored email is not replaced by a different one either. One row disagrees
-- with what is on file (Sherida Burge: the roster says slhicks@utah.gov, the
-- record says sburge@utah.gov) and it is left alone and reported, because the
-- stored one matches her current surname and a billing packet sent to the
-- wrong address is not recoverable by trying again.
--
-- No counselor's phone number is touched at all. The roster's phone column is
-- the office main line, repeated on every row of that office - it is the
-- office's number and it is stored on the office. Several counselors already
-- have their own direct lines on file and overwriting one of those with a
-- switchboard would be a loss dressed up as an update.
--
-- Vacant posts are skipped: nine of them, listed in the report.
--
-- USOR Administration is not an office full of counselors, it is the
-- accounts-payable department. Its eight people go in billing_office_contacts
-- (0195), not in the counselor directory.
--
-- ── and what it leaves for a person ────────────────────────
--
-- Sixteen new offices have no billing office. That column decides where an
-- authorization packet is emailed, so it is left null and every one of them is
-- named in the report rather than mapped to whichever CRP looks closest.

set local client_min_messages = notice;

-- The reason the change log will carry for all of this, so a hundred new
-- entries explain themselves to whoever reads them next week.
select set_config('zion.directory_reason',
  'Imported from the USOR published offices-and-counselors roster, 14 Oct 2026', true);

-- ── what the roster says ────────────────────────────────────
create temp table usor_office (
  city text primary key, district text not null, address text not null,
  phone text not null, note text not null
);

insert into usor_office (city, district, address, phone, note) values
  ('Blanding', 'Blanding Office', '544 N 100 E, Blanding, UT 84511', '(435) 678-3200', 'Counselor position vacant; office listing also shows (435) 625-0005'),
  ('Brigham City', 'Brigham City Office', '275 W 1100 S, Brigham City, UT 84302-3116', '(435) 734-9408', ''),
  ('Cedar City', 'Cedar City Office', '176 E 200 N, Cedar City, UT 84720-3726', '(435) 586-9995', ''),
  ('Center of the Deaf and Hard of Hearing', 'Center of the Deaf and Hard of Hearing', '5709 S 1500 W, Taylorsville, UT 84123-5217', '(801) 657-5200', ''),
  ('Centerville', 'Davis District (25)', '520 N Marketplace Dr Ste 130, Centerville, UT 84014', '(385) 489-6015', ''),
  ('Delta', 'Delta Office', '44 S 350 E, Delta, UT 84624', '(435) 864-2509', ''),
  ('Heber City', 'Heber City Office', '2 S Main Ste 2E, Heber City, UT 84032', '(435) 657-0629', ''),
  ('Logan', 'Northern Utah District (10)', '180 N 100 W, Logan, UT 84321-5915', '(435) 787-3480', ''),
  ('Manti', 'Manti Office', '55 S Main #3, Manti, UT 84642', '(435) 283-6501', ''),
  ('Moab', 'Moab Office', '457 Kane Creek Blvd, Moab, UT 84532-2595', '(435) 259-4635', ''),
  ('Ogden', 'Ogden District (15)', '950 E 25th Street #200, Ogden, UT 84401', '(801) 395-7020', ''),
  ('Price', 'Price Office', '475 W Price River Drive Ste C, Price, UT 84501-2839', '(435) 636-2820', ''),
  ('Provo', 'Provo District (50)', '150 E Center Street Ste 3300, Provo, UT 84606-3106', '(801) 806-0950', ''),
  ('Richfield', 'Richfield Office', '250 N Main St Ste B3, Richfield, UT 84701', '(435) 896-1470', ''),
  ('Roosevelt', 'Roosevelt Office', '140 W 425 S #330, Roosevelt, UT 84066', '(435) 722-2129', ''),
  ('Salt Lake City', 'Salt Lake Downtown District (20)', '150 N 1950 W, Salt Lake City, UT 84116', '(801) 238-4560', ''),
  ('South Jordan', 'South Valley District (40)', '926 W Baxter Drive (10600 S), South Jordan, UT 84095-8687', '(801) 446-2560', ''),
  ('Spanish Fork', 'Central Utah District (45)', '1185 N Canyon Creek Parkway, Spanish Fork, UT 84660', '(801) 465-8384', ''),
  ('St. George', 'Southern Utah District (60)', '965 E 700 S #202, St. George, UT 84790-4085', '(435) 673-5091', ''),
  ('Taylorsville', 'Valley West District (30)', '5522 S 3200 W, Taylorsville, UT 84129', '(801) 957-8200', ''),
  ('Tooele', 'Tooele Office', '305 N Main Street Ste 100, Tooele, UT 84074', '(435) 882-1086', ''),
  ('Vernal', 'Eastern Utah District (55)', '320 N Aggie Blvd Ste 105, Vernal, UT 84078', '(435) 789-0273', '');

create temp table usor_counselor (
  name text not null, email text not null, city text not null,
  note text not null, role text not null,
  name_key text generated always as (public.directory_name_key(name)) stored
);

insert into usor_counselor (name, email, city, note, role) values
  ('Daren Orme', 'dorme@utah.gov', 'Logan', '', ''),
  ('Lauren Cook', '', 'Logan', '', ''),
  ('Phil Redlinger', '', 'Logan', '', ''),
  ('Darci Ostergar', 'dostergar@utah.gov', 'Logan', '', ''),
  ('Kami McNeil', '', 'Logan', '', ''),
  ('Maria Koontz', '', 'Brigham City', '', ''),
  ('Lisa Smith', 'lsmith1@utah.gov', 'Brigham City', '', ''),
  ('Jenny Shurtleff', 'jmeredith@utah.gov', 'Ogden', 'Email list shows Shurtleff, Jennifer', ''),
  ('Emily Easton', '', 'Ogden', '', ''),
  ('James Bowen', 'jtbowen@utah.gov', 'Ogden', '', ''),
  ('Jamie Shepherd', 'jamieshepherd@utah.gov', 'Ogden', '', ''),
  ('Roxanne Holbrook', '', 'Ogden', '', 'BVI counselor'),
  ('Laura Andersen', '', 'Ogden', '', ''),
  ('Jayden Draper', 'jaydendraper@utah.gov', 'Ogden', '', ''),
  ('Ayneesha Taylor', 'ayneeshataylor@utah.gov', 'Ogden', '', ''),
  ('Cole Hamblin', '', 'Ogden', '', ''),
  ('Mark Gardner', 'mgardner@utah.gov', 'Centerville', '', ''),
  ('Bill Gropp', 'bgropp@utah.gov', 'Centerville', '', ''),
  ('Jeffrey Furlong', '', 'Centerville', '', ''),
  ('Lloyd Phelps', 'lphelps@utah.gov', 'Centerville', '', ''),
  ('Colby Majors', '', 'Centerville', '', ''),
  ('Cheyanne Bradshaw', '', 'Centerville', '', 'Transition counselor'),
  ('Natalie Seely', '', 'Centerville', '', ''),
  ('Sherida Burge', 'slhicks@utah.gov', 'Centerville', '', ''),
  ('Melinda Watson', '', 'Centerville', '', ''),
  ('Dawn Oughton', 'doughton@utah.gov', 'Salt Lake City', '', ''),
  ('Jeff Kenyon', 'jeffkenyon@utah.gov', 'Salt Lake City', '', ''),
  ('Nuur Haji', 'shaji@utah.gov', 'Salt Lake City', 'Email list shows Haji, Noor', ''),
  ('Albert Farley', 'afarley@utah.gov', 'Salt Lake City', '', ''),
  ('Victor Villarreal', '', 'Salt Lake City', '', ''),
  ('Rosalys Rivera', 'rmrivera@utah.gov', 'Salt Lake City', '', ''),
  ('Melanie Fabre Morales', '', 'Salt Lake City', '', ''),
  ('Denise Francis-Montaño', '', 'Salt Lake City', '', 'BVI counselor'),
  ('Chris Condit', 'ccondit@utah.gov', 'Salt Lake City', '', ''),
  ('Teri Bird', 'tkbird@utah.gov', 'Salt Lake City', '', ''),
  ('Tim Daynes', 'tdaynes@utah.gov', 'Salt Lake City', '', 'BVI counselor'),
  ('Debi Giles', 'debigiles@utah.gov', 'Salt Lake City', '', 'Transition counselor'),
  ('Camie Vuyk', 'cvuyk@utah.gov', 'Taylorsville', '', ''),
  ('Rachana Keo', 'rkeo@utah.gov', 'Taylorsville', '', ''),
  ('Jennifer Hysing', '', 'Taylorsville', '', ''),
  ('Clara So', '', 'Taylorsville', '', 'Transition counselor'),
  ('Cheree Zoellner', 'czoellner@utah.gov', 'Taylorsville', '', ''),
  ('Paden Carter', '', 'Taylorsville', '', ''),
  ('Fa''a Apelu', 'fapelu@utah.gov', 'Taylorsville', '', ''),
  ('Carly Pichler', 'cpichler@utah.gov', 'Taylorsville', '', ''),
  ('Rebekah Berg', 'rberg@utah.gov', 'Taylorsville', '', ''),
  ('Carmen Bento', '', 'Tooele', '', ''),
  ('Barbie Cederlof', 'bcederlof@utah.gov', 'Tooele', '', ''),
  ('Keira Shae', '', 'Center of the Deaf and Hard of Hearing', '', 'DHH counselor'),
  ('Laura Mico-Monaco', '', 'South Jordan', '', ''),
  ('Josh Madsen', 'Joshuamadsen@utah.gov', 'South Jordan', '', ''),
  ('Joseph Shields', 'jshields@utah.gov', 'South Jordan', '', ''),
  ('Rachel Blackhurst', '', 'South Jordan', '', ''),
  ('Heather Farnsworth', 'hfarnsworth@utah.gov', 'South Jordan', '', ''),
  ('Necia Leasoon', '', 'South Jordan', '', ''),
  ('John Trenton', 'jtrenton@utah.gov', 'South Jordan', '', ''),
  ('Bruce Tatum', 'btatum@utah.gov', 'South Jordan', '', ''),
  ('Coy Einfeldt', '', 'South Jordan', '', ''),
  ('Robert Loving', 'rloving@utah.gov', 'South Jordan', '', ''),
  ('Gwendolyn Topliss', '', 'South Jordan', '', ''),
  ('Starr Stoddard', 'sstoddard@utah.gov', 'Spanish Fork', '', ''),
  ('John Kauer', '', 'Spanish Fork', '', 'BVI counselor'),
  ('Brad Bowen', 'bradbowen@utah.gov', 'Spanish Fork', '', ''),
  ('Vicky Peterson', 'vickypeterson@utah.gov', 'Spanish Fork', '', ''),
  ('Cristiane Lundgreen', 'alundgren@utah.gov', 'Spanish Fork', '', ''),
  ('Heather Davis', '', 'Spanish Fork', '', 'Transition counselor'),
  ('Kayla Dutson', 'kaylamassa@utah.gov', 'Delta', '', ''),
  ('Aaron Matthews', 'ammatthews@utah.gov', 'Manti', '', ''),
  ('Linda Hapsmith', 'lhapsmith@utah.gov', 'Richfield', '', ''),
  ('David Teeples', 'dteeples@utah.gov', 'Richfield', '', ''),
  ('JoAnne Leilua', 'joanneleiua@utah.gov', 'Provo', '', ''),
  ('Delfina Mejia', 'demejia@utah.gov', 'Provo', '', ''),
  ('Danae (Coral) Moses', 'cmoses@utah.gov', 'Provo', '', ''),
  ('Mary Vasquez', 'mavasquez@utah.gov', 'Provo', '', 'DHH counselor'),
  ('Jaden Albrecht', '', 'Provo', '', ''),
  ('Bill Miller', 'billmiller@utah.gov', 'Provo', '', 'BVI counselor'),
  ('Trevor Buit', 'trevorbuit@utah.gov', 'Provo', '', ''),
  ('Trent Bowen', 'trentbowen@utah.gov', 'Provo', '', ''),
  ('Danielle Lambert', 'daniellelambert@utah.gov', 'Provo', '', ''),
  ('Indira Peralta', 'iperalta@utah.gov', 'Provo', '', ''),
  ('Kylee Powell', 'kyleepowell@utah.gov', 'Provo', '', ''),
  ('Lee Bingham', 'leebingham@utah.gov', 'Provo', '', ''),
  ('Tausha Hewlett', 'tahewlett@utah.gov', 'Heber City', '', ''),
  ('Ryan Miller', 'ryanmiller@utah.gov', 'Vernal', '', ''),
  ('Danni Powell', 'dannipowell@utah.gov', 'Vernal', '', ''),
  ('Heather Odendahl', '', 'Price', '', ''),
  ('Maygun Axelsen Hales', '', 'Price', '', ''),
  ('Jennifer McGarry', '', 'Price', '', 'BVI counselor'),
  ('Arcadio Madrigal', 'arcadiomadrigal@utah.gov', 'Roosevelt', '', ''),
  ('Brandon Luce', 'bluce@utah.gov', 'St. George', '', 'BVI counselor'),
  ('Holly Nelson', '', 'St. George', '', ''),
  ('Kellie Larsen', 'kellielarsen@utah.gov', 'St. George', '', ''),
  ('Joanie Weatherly', 'jweatherly@utah.gov', 'St. George', '', ''),
  ('Sallie Muir', '', 'St. George', 'Spelled as printed in roster; The roster prints the email as smuir@utan.gov, which is not a utah.gov address. Not imported - ask USOR for the right one.', ''),
  ('Sheree Meyer', '', 'St. George', '', ''),
  ('Javiera Morales Saavada', 'javieramorales@utah.gov', 'St. George', '', ''),
  ('Ben (William) Powers', 'wpowers@utah.gov', 'Cedar City', '', ''),
  ('Christine Manning', 'cmanning@utah.gov', 'Cedar City', '', ''),
  ('Mason Peterson', 'masonpeterson@utah.gov', 'Cedar City', '', ''),
  ('David Armenta', 'djarmenta@utah.gov', 'Cedar City', '', '');

-- Which offices the directory already had, so the report can say which it
-- gained rather than guessing from a count.
create temp table office_before as select name from public.offices;

/**
 * Two roster rows must not name one person.
 *
 * The match picks one row per counselor on file; a second row that keys to
 * the same person would then look new and be inserted beside them, which is
 * the duplicate this whole matching exercise exists to avoid. Checked rather
 * than assumed, because the roster is a hundred rows typed by somebody else.
 */
do $$
declare
  v_dupes text;
begin
  select string_agg(format('%s (%s rows)', name_key, n), ', ')
    into v_dupes
    from (select name_key, count(*) as n from usor_counselor group by name_key having count(*) > 1) d;
  if v_dupes is not null then
    raise exception 'The roster names the same person twice: %', v_dupes
      using hint = 'Two rows reduce to one name key. Reconcile them in the CSV first.';
  end if;

  select string_agg(format('%s (%s rows)', lower(email), n), ', ')
    into v_dupes
    from (select email, count(*) as n from usor_counselor
           where email <> '' group by lower(email), email having count(*) > 1) d;
  if v_dupes is not null then
    raise exception 'The roster uses one email for two people: %', v_dupes;
  end if;
end $$;

-- ── offices: added, or filled in ───────────────────────────
--
-- The six already there keep their billing office and their note; what they
-- gain is the address, the main line and the district label, none of which
-- the directory had anywhere.
update public.offices o
   set address       = case when o.address = '' then u.address else o.address end,
       phone         = case when o.phone   = '' then u.phone   else o.phone   end,
       usor_district = case when o.usor_district = '' then u.district else o.usor_district end
  from usor_office u
 where o.name = u.city;

insert into public.offices (name, address, phone, usor_district, note, billing_office_id)
select u.city, u.address, u.phone, u.district, u.note, null
  from usor_office u
 where not exists (select 1 from public.offices o where o.name = u.city);

-- ── the counselors already on file ─────────────────────────
--
-- Matched by email, else by name key. Written to a temp table first because
-- the report counts what was matched and an update cannot say so afterwards.
create temp table matched as
select distinct on (c.id) c.id as counselor_id, c.name as stored_name, c.email as stored_email,
       c.office as stored_office, c.notes as stored_notes,
       u.name as roster_name, u.email as roster_email, u.city as roster_city,
       u.note as roster_note, u.role as roster_role,
       case when lower(nullif(c.email, '')) = lower(nullif(u.email, '')) then 'email'
            else 'name' end as matched_by
  from public.counselors c
  join usor_counselor u
    on (nullif(c.email, '') is not null and lower(c.email) = lower(nullif(u.email, '')))
    or public.directory_name_key(c.name) = u.name_key
 order by c.id, (case when lower(nullif(c.email, '')) = lower(nullif(u.email, '')) then 0 else 1 end);

/**
 * The office a matched counselor sits in had better already be right.
 *
 * Moving a counselor between offices moves the billing office their clients
 * bill through, which is why it has its own function and asks for a reason
 * (move_counselor_office, 0099). An import must not do that quietly. All
 * eleven matches are already in the office the roster puts them in, so this
 * raises rather than choosing - if a future roster disagrees, somebody moves
 * them on purpose.
 */
do $$
declare
  v_moves text;
begin
  select string_agg(format('%s: on file at %s, roster says %s',
                           stored_name, coalesce(nullif(stored_office, ''), 'no office'), roster_city),
                    E'\n       ')
    into v_moves
    from matched
   where coalesce(stored_office, '') <> roster_city
     and coalesce(stored_office, '') <> '';
  if v_moves is not null then
    raise exception E'The roster puts these counselors in a different office:\n       %', v_moves
      using hint = 'Moving one moves the billing office their clients bill through. Use move_counselor_office, with a reason.';
  end if;
end $$;

-- An office for somebody who had none is not a move, it is a gap being filled.
update public.counselors c
   set office = m.roster_city
  from matched m
 where c.id = m.counselor_id and coalesce(c.office, '') = '';

-- An email only where there was none. Never over the top of one, blank or not.
update public.counselors c
   set email = m.roster_email
  from matched m
 where c.id = m.counselor_id
   and coalesce(c.email, '') = ''
   and coalesce(m.roster_email, '') <> '';

-- The role the roster names - BVI, DHH, transition - which is the thing staff
-- most often want to know about a counselor they have not met.
update public.counselors c
   set notes = btrim(case when coalesce(c.notes, '') = '' then m.roster_role
                          else c.notes || '; ' || m.roster_role end, '; ')
  from matched m
 where c.id = m.counselor_id
   and m.roster_role <> ''
   and position(lower(m.roster_role) in lower(coalesce(c.notes, ''))) = 0;

-- ── and the ones who are new ───────────────────────────────
insert into public.counselors (name, agency, office, email, notes)
select u.name, 'Utah State Office of Rehabilitation', u.city,
       nullif(u.email, ''),
       btrim(concat_ws('; ', nullif(u.role, ''), nullif(u.note, '')), '; ')
  from usor_counselor u
 where not exists (select 1 from matched m where m.roster_name = u.name)
 order by u.city, u.name;

-- ── USOR Administration, as a billing office with contacts ─
insert into public.billing_offices (name, billing_email, has_group_address, notes)
select 'USOR Administration (central billing)', '', false,

       'USOR''s accounts-payable department, 140 E 300 S, Salt Lake City, UT 84111. Main line (801) 526-9675. Accounting main line (801) 526-4345. also (801) 535-3890, (801) 526-9234, (801) 526-9222, (801) 526-9237 No group billing address is published; the named people are listed as contacts. No counselor office bills through this - it is here so the people who pay the warrants can be looked up.'

 where not exists (select 1 from public.billing_offices
                    where name = 'USOR Administration (central billing)');

create temp table usor_contact (name text not null, title text not null, email text not null, phone text not null, notes text not null);

insert into usor_contact (name, title, email, phone, notes) values
  ('Jennifer Roth', 'Financial Manager II / Grant Manager', 'jenroth@utah.gov', '801-535-3883', ''),
  ('Jessica Staker', 'Financial Manager I', 'jestaker@utah.gov', '385-277-3990', ''),
  ('Dallen Remund', 'Financial Manager I', '', '435-265-2545', 'no email published'),
  ('Kelly Anderson', 'Financial Analyst III / Accounts Payable Supervisor', 'kkay@utah.gov', '801-633-4214', 'email as printed'),
  ('Marian Midgley', 'Case Service Purchasing Agent', 'mmidgley@utah.gov', '385-630-9950', ''),
  ('Shalie Ripley', 'Case Service Purchasing Agent', 'shalieripley@utah.gov', '385-418-9989', ''),
  ('Lisa Poole', 'Accounting Tech II', 'loverby@utah.gov', '385-539-8870', ''),
  ('Audra Butterfield', 'Accounting Tech II', 'audrabutterfield@utah.gov', '385-602-8463', '');

create temp table usor_vacant (office text not null, note text not null);
insert into usor_vacant (office, note) values
  ('Ogden District (15)', 'Vacant position 15-03'),
  ('Salt Lake Downtown District (20)', 'Vacant position 20-10'),
  ('Salt Lake Downtown District (20)', 'Vacant position 20-14'),
  ('Valley West District (30)', 'Vacant position 30-15'),
  ('South Valley District (40)', 'Vacant position 40-06'),
  ('Provo District (50)', 'Vacant position 50-15 Transition'),
  ('Blanding Office', 'Counselor position vacant; office listing also shows (435) 625-0005'),
  ('Moab Office', 'Counselor position vacant'),
  ('Southern Utah District (60)', 'Vacant position 60-06');

insert into public.billing_office_contacts (billing_office_id, name, title, email, phone, notes)
select b.id, u.name, u.title, u.email, u.phone, u.notes
  from usor_contact u
  cross join (select id from public.billing_offices
               where name = 'USOR Administration (central billing)') b
 where not exists (
   select 1 from public.billing_office_contacts c
    where c.billing_office_id = b.id and c.name = u.name);

-- ── the report ─────────────────────────────────────────────
--
-- Counted from the database after the fact rather than asserted by whatever
-- generated this file, so the numbers are what actually landed.
do $$
declare
  v_line text;
  r      record;
begin
  raise notice '';
  raise notice '=== THE USOR ROSTER, IMPORTED ===';
  raise notice '';

  raise notice 'COUNSELORS';
  raise notice '  on the roster: %', (select count(*) from usor_counselor);
  raise notice '  matched to somebody already on file: % (by email %, by name %)',
    (select count(*) from matched),
    (select count(*) from matched where matched_by = 'email'),
    (select count(*) from matched where matched_by = 'name');
  raise notice '  added: %',
    (select count(*) from usor_counselor u
      where not exists (select 1 from matched m where m.roster_name = u.name));
  raise notice '  roster rows with no email to import: % - % publish none, and 1 was flagged for a typo domain',
    (select count(*) from usor_counselor where email = ''),
    (select count(*) from usor_counselor where email = '' and note not ilike '%utah.gov address%');
  raise notice '  of those, % are people already on file, whose stored address was kept',
    (select count(*) from matched where coalesce(roster_email, '') = '');
  raise notice '  counselors in the directory now: %', (select count(*) from public.counselors);
  raise notice '';

  raise notice '  Matched, and what each one kept:';
  for r in select stored_name, matched_by, stored_email, roster_email, roster_role
             from matched order by stored_name loop
    v_line := format('    %s (by %s)', r.stored_name, r.matched_by);
    if coalesce(r.roster_email, '') = '' then
      v_line := v_line || ' - roster publishes no email, kept '
                       || coalesce(nullif(r.stored_email, ''), 'none');
    elsif lower(coalesce(r.stored_email, '')) <> lower(r.roster_email) then
      v_line := v_line || format(' - EMAIL CONFLICT: on file %s, roster %s; kept the one on file',
                                 r.stored_email, r.roster_email);
    end if;
    if r.roster_role <> '' then v_line := v_line || ' [' || r.roster_role || ']'; end if;
    raise notice '%', v_line;
  end loop;
  raise notice '';

  raise notice '  Flagged rather than imported:';
  for r in select name, notes from public.counselors
            where notes ilike '%not a utah.gov address%' order by name loop
    raise notice '    %: %', r.name, r.notes;
  end loop;
  raise notice '';

  raise notice 'OFFICES';
  raise notice '  on the roster: %', (select count(*) from usor_office);
  raise notice '  added: %', (select count(*) from usor_office u
    where not exists (select 1 from office_before b where b.name = u.city));
  raise notice '  already on file, given their address, main line and district: %',
    (select count(*) from usor_office u join office_before b on b.name = u.city);
  raise notice '  offices in the directory now: %', (select count(*) from public.offices);
  raise notice '';

  raise notice '  Added:';
  for r in select u.city, u.district, u.phone from usor_office u
            where not exists (select 1 from office_before b where b.name = u.city)
            order by u.city loop
    raise notice '    % (%) %', r.city, r.district, r.phone;
  end loop;
  raise notice '';

  raise notice '  NEEDING A BILLING OFFICE - nothing was guessed, because this is';
  raise notice '  the column that decides where an authorization packet is emailed:';
  for r in select name, usor_district from public.offices
            where billing_office_id is null order by name loop
    raise notice '    % (%)', r.name, r.usor_district;
  end loop;
  raise notice '';

  raise notice 'CENTRAL BILLING - USOR Administration';
  raise notice '  a billing office with % contacts, not counselors:',
    (select count(*) from public.billing_office_contacts c
      join public.billing_offices b on b.id = c.billing_office_id
     where b.name = 'USOR Administration (central billing)');
  for r in select c.name, c.title,
                  coalesce(nullif(c.email, ''), 'no email published') as email, c.phone
             from public.billing_office_contacts c
             join public.billing_offices b on b.id = c.billing_office_id
            where b.name = 'USOR Administration (central billing)'
            order by c.name loop
    raise notice '    %, % - % - %', r.name, r.title, r.email, r.phone;
  end loop;
  raise notice '';

  raise notice 'SKIPPED';
  raise notice '  vacant posts on the roster: %', (select count(*) from usor_vacant);
  for r in select office, note from usor_vacant order by office, note loop
    raise notice '    % - %', r.office, r.note;
  end loop;
  raise notice '';
  raise notice '=== END ===';
end $$;
