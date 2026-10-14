-- Zion Vocational Rehab CRM — room for the whole USOR directory
-- (owner, 14 Oct 2026: import the published offices-and-counselors roster)
--
-- The directory held six offices, all of them places the practice already
-- bills into. The roster has twenty-two, and it is the whole state: Logan to
-- St. George, with the counselor at each. Four things had to change before it
-- would fit, and each of them is a fact the old shape could not hold rather
-- than a convenience.
--
-- ── an office has a phone number ────────────────────────────
--
-- There was nowhere to put one. The roster gives a main line per office and
-- that is the number staff actually dial - the counselors' own numbers are a
-- different thing and several of them are already on file.
--
-- ── and a district name as well as a city ───────────────────
--
-- The directory names offices by city, and 63 clients and 19 counselors point
-- at those names. USOR names them by district: "Davis District (25)" is the
-- Centerville office. Both are needed - the city because it is what the
-- records already say, the district because it is what USOR calls it on
-- paperwork and what the caseload codes count from. So the district goes in a
-- column of its own rather than into the note, where it would be prose.
--
-- Renaming the offices to USOR's labels was the alternative, and it would have
-- orphaned every one of those 63 clients.
--
-- ── an office may not know its billing office yet ───────────
--
-- billing_office_id was NOT NULL, which was true of six offices that were only
-- ever added because the practice bills into them. Sixteen new ones bill
-- through a CRP nobody has told us about. The owner was explicit: leave it
-- empty and flag it, do not guess - and the guess is not harmless, because
-- this column decides where an authorization packet is emailed.
--
-- So it is nullable, and the app already copes: readBillingOffices() maps an
-- office with no billing office to null, and "clients with no billing office"
-- is a filter that already exists.
--
-- ── a central billing office has more than one contact ──────
--
-- billing_offices carries one contact, which is right for a CRP office with
-- one specialist. USOR Administration is an accounts-payable department: a
-- grant manager, two financial managers, an AP supervisor, two purchasing
-- agents and two accounting techs, and which one you want depends on whether
-- you are chasing a warrant or questioning a purchase order. Eight of them do
-- not fit in one row, and putting seven into a notes field would mean nobody
-- can look one up.
--
-- The existing single contact column is left alone rather than folded into the
-- new table. Two homes for one fact is a real cost and it is written down
-- here, but the alternative was restructuring the column that decides where
-- billing mail goes, the day after a billing deploy, for an import.

-- ─────────────────────────────────────────────────────────────
-- A billing office may publish no group address
--
-- billing_email had to look like an email, which was true of the five CRP
-- offices: each exists because the practice sends packets to it. USOR
-- Administration publishes no group address at all - the roster gives eight
-- named people and no shared inbox - and the table already has a column for
-- exactly that distinction, has_group_address.
--
-- So blank is now allowed, on the same terms contact_email has always had:
-- empty, or a real address, and nothing in between. Nothing downstream
-- assumes otherwise - submitAuthorization already refuses to send and says
-- "there is no billing office address for X" rather than mailing nowhere,
-- which is the behaviour this wants anyway.
-- ─────────────────────────────────────────────────────────────
alter table public.billing_offices drop constraint if exists billing_offices_billing_email_check;
alter table public.billing_offices add constraint billing_offices_billing_email_check
  check (billing_email = '' or billing_email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$');

comment on column public.billing_offices.billing_email is
  'Where packets for this billing office go, or empty when none is published - a central billing office may have named people and no shared inbox. Submission refuses rather than sending nowhere.';

-- ── the office columns ──────────────────────────────────────
alter table public.offices add column if not exists phone text not null default '';
alter table public.offices add column if not exists usor_district text not null default '';
alter table public.offices alter column billing_office_id drop not null;

comment on column public.offices.phone is
  'The office main line, as USOR publishes it. A counselor''s own number lives on the counselor.';
comment on column public.offices.usor_district is
  'What USOR calls this office - "Davis District (25)" for Centerville. The name column stays the city, because that is what the client and counselor records point at.';
comment on column public.offices.billing_office_id is
  'The CRP billing office this office bills through, or null when nobody has told us yet. Null is deliberate: this column decides where an authorization packet is emailed, so a guess sends paperwork to the wrong district.';

-- ─────────────────────────────────────────────────────────────
-- Two spellings of the same person
--
-- Needed to import the roster without making a second Joshua Madsen out of a
-- row that says Josh, and useful afterwards for the same reason: a referral
-- names a counselor the way whoever typed it knew them.
--
-- It is deliberately not clever. It strips accents and anything in brackets
-- ("Ben (William) Powers" is Ben Powers), drops punctuation, and maps the
-- short forms that actually appear in this roster to their long ones. It does
-- not do initials, it does not do surnames-first, and it does not guess at
-- anything it has not been taught - because a name match that is wrong merges
-- two counselors, and the whole point of matching is to not create duplicates.
-- ─────────────────────────────────────────────────────────────
create or replace function public.directory_name_key(p_name text)
returns text language sql immutable set search_path = public as $$
  with parts as (
    select string_to_array(
             btrim(regexp_replace(                          -- and collapse the gaps
               regexp_replace(
                 regexp_replace(
                   lower(translate(coalesce(p_name, ''),
                     'áàâäãéèêëíìîïóòôöõúùûüñçÁÀÂÄÃÉÈÊËÍÌÎÏÓÒÔÖÕÚÙÛÜÑÇ',
                     'aaaaaeeeeiiiiooooouuuuncAAAAAEEEEIIIIOOOOOUUUUNC')),
                   '\([^)]*\)', ' ', 'g'),                  -- Ben (William) Powers
                 '[^a-z\s]', ' ', 'g'),                      -- hyphens, apostrophes
               '\s+', ' ', 'g')),
             ' ') as w
  ),
  /**
   * Only the pairs this roster gives evidence for.
   *
   * Every one of these is two spellings the data itself shows are one person:
   * Josh Madsen and Joshua Madsen share joshuamadsen@utah.gov; the roster
   * annotates Jenny Shurtleff with "Email list shows Shurtleff, Jennifer";
   * Matt Christensen on file is matthewc@utah.gov. Bill and William appear in
   * both directions across the roster.
   *
   * Nothing speculative. Kami, Debi, Ben and the rest were in an earlier draft
   * of this list and came out: Kami could be Kamille or Kameron or Kimberly,
   * and the roster's only Ben is "Ben (William) Powers" at wpowers@utah.gov -
   * so mapping ben to benjamin would have been confidently wrong about a real
   * person. A wrong match merges two counselors and there is no undoing it,
   * which makes a guess here worse than no guess at all.
   */
  nicks(short, long) as (values
    ('josh','joshua'), ('jenny','jennifer'),
    ('matt','matthew'), ('bill','william')
  )
  select case
           when (select array_length(w, 1) from parts) is null then ''
           else btrim(
             coalesce((select long from nicks where short = (select w[1] from parts)),
                      (select w[1] from parts))
             || ' ' ||
             coalesce((select array_to_string(w[2:], ' ') from parts), ''))
         end;
$$;

comment on function public.directory_name_key is
  'A counselor name reduced to what two spellings of the same person share: accents stripped, brackets dropped, gaps collapsed, and the four short forms this roster gives evidence for mapped to their long ones. Josh Madsen and Joshua Madsen give the same key. It guesses at nothing, because a wrong match merges two people.';

revoke all on function public.directory_name_key(text) from anon, authenticated;
grant execute on function public.directory_name_key(text) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- The people at a billing office
-- ─────────────────────────────────────────────────────────────
create table if not exists public.billing_office_contacts (
  id                uuid primary key default gen_random_uuid(),
  billing_office_id uuid not null references public.billing_offices(id) on delete cascade,
  name              text not null,
  title             text not null default '',
  email             text not null default '',
  phone             text not null default '',
  notes             text not null default '',
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint billing_office_contacts_name_check check (btrim(name) <> '')
);

create index if not exists billing_office_contacts_office
  on public.billing_office_contacts (billing_office_id, name);

comment on table public.billing_office_contacts is
  'The named people at a billing office, for one that has several - USOR Administration has eight, and which one you want depends on whether you are chasing a warrant or questioning a purchase order.';

alter table public.billing_office_contacts enable row level security;

-- Read by any member of staff, like the rest of the directory; changed by
-- whoever may change a billing office.
drop policy if exists billing_office_contacts_read on public.billing_office_contacts;
create policy billing_office_contacts_read on public.billing_office_contacts
  for select using ((select public.is_active_staff()));

drop policy if exists billing_office_contacts_write on public.billing_office_contacts;
create policy billing_office_contacts_write on public.billing_office_contacts
  for all using ((select public.staff_has_area('billing', 'edit')))
  with check ((select public.staff_has_area('billing', 'edit')));

revoke all on public.billing_office_contacts from anon, authenticated;
grant select, insert, update, delete on public.billing_office_contacts to authenticated;

-- The agent account reads; it never writes a directory record. Applied by the
-- same function every other table uses, so there is one definition of what
-- "the system may not write this" means (verify_system_account.sql checks
-- every table for it, and found this one missing).
select public.apply_system_read_only('billing_office_contacts');

-- ── and a change to one is written down, like the rest ──────
alter table public.directory_changes drop constraint if exists directory_changes_entity_check;
alter table public.directory_changes add constraint directory_changes_entity_check
  check (entity in ('Counselor', 'Billing office', 'Office', 'Client', 'Billing contact'));

create or replace function public.directory_change_log()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_old     jsonb := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) else '{}'::jsonb end;
  v_new     jsonb := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) else '{}'::jsonb end;
  v_changes jsonb := '{}'::jsonb;
  v_key     text;
  v_entity  text;
  v_id      text;
  v_name    text;
  v_action  text;
  v_staff   public.staff%rowtype;
begin
  -- This log is read by a person asking whether a record's details moved.
  -- Somebody invented for a test is not news, however the write arrived.
  if public.is_fixture_name(coalesce(v_new ->> 'name', v_old ->> 'name')) then
    return null;
  end if;

  -- Which fields moved, from what to what. Bookkeeping columns are not news.
  for v_key in
    select k from jsonb_object_keys(v_old || v_new) as k
     where k not in ('created_at', 'updated_at')
  loop
    if (v_old -> v_key) is distinct from (v_new -> v_key) then
      v_changes := v_changes || jsonb_build_object(v_key, jsonb_build_object('from', v_old -> v_key, 'to', v_new -> v_key));
    end if;
  end loop;
  if tg_op = 'UPDATE' and v_changes = '{}'::jsonb then
    return null;
  end if;

  /**
   * Every table that writes here is named.
   *
   * This used to end in `else 'Office'`. A default branch on a CASE like this
   * is a bug waiting for the next table: it does not fail, it mislabels, and
   * the log goes on looking fine while a client is filed as an office. Now an
   * unnamed table raises, which is a thing somebody notices on the deploy
   * that added it rather than a thing somebody finds in a year.
   */
  v_entity := case tg_table_name
    when 'counselors'              then 'Counselor'
    when 'billing_offices'         then 'Billing office'
    when 'offices'                 then 'Office'
    when 'clients'                 then 'Client'
    when 'billing_office_contacts' then 'Billing contact'
    else null end;
  if v_entity is null then
    raise exception 'The change log does not know what a row of % is', tg_table_name
      using hint = 'Name the table in directory_change_log and in the entity check.';
  end if;

  v_id := coalesce(v_new ->> 'id', v_old ->> 'id', v_new ->> 'name', v_old ->> 'name');
  v_name := coalesce(v_new ->> 'name', v_old ->> 'name', '');
  v_action := case tg_op
    when 'INSERT' then 'Added'
    when 'DELETE' then 'Removed'
    else coalesce(nullif(current_setting('zion.directory_action', true), ''), 'Edited') end;

  select * into v_staff from public.staff where id = public.current_staff_id();

  insert into public.directory_changes (entity, entity_key, entity_name, action, changes, reason, changed_by, changed_by_name)
  values (v_entity, v_id, v_name, v_action, v_changes,
          coalesce(nullif(current_setting('zion.directory_reason', true), ''), ''),
          v_staff.id, coalesce(v_staff.name, 'System'));
  return null;
end;
$$;

comment on function public.directory_change_log is
  'Records a real change to a counselor, billing office, billing contact, office or client: which fields moved, from what to what, by whom and why. A name following the fixture convention is not recorded — the log is read by a person, not by a machine. A table it does not know raises rather than guessing.';

drop trigger if exists billing_office_contacts_log on public.billing_office_contacts;
create trigger billing_office_contacts_log
  after insert or update or delete on public.billing_office_contacts
  for each row execute function public.directory_change_log();
