-- Zion Vocational Rehab CRM — several numbers, and the people around a client
--
-- The owner's order of 9 November 2026, part A.
--
-- ── the numbers ──────────────────────────────────────────────
--
-- A client has one number on their record and most of them have two or three.
-- `clients.phone` stays what it has always been: **the number texts go to**.
-- Every other number a client has is a row in `client_phones`, labelled, and
-- `client_numbers` is the two of them read as one list.
--
-- Done that way round on purpose. The texting number is asked for in a dozen
-- places and enforced in a trigger; making it a flag on a row in another
-- table would have put the one fact the practice cannot get wrong behind a
-- join, and left two places able to disagree about which number a text goes
-- to. There is no such disagreement here: the texting number is a column, and
-- a number in the list cannot be the same as it.
--
-- ── and the people around them ───────────────────────────────
--
-- A client's daughter-in-law rings about appointments; a client's partner is
-- the one who answers. The practice has been keeping them as clients - there
-- is a record in the list today called "Jay (Robert Ess' Partner)", Inactive,
-- stage Intake, with a phone number and a caseload - which is how somebody
-- who is not a client comes to be counted as one.
--
-- **A contact is never a client and never becomes one.** The row has nowhere
-- to put a caseload, a stage, a counselor, a funding source or an
-- authorization, so there is nothing to promote: it is not a client record
-- with a flag off. And a text from a contact's number files on the **client**,
-- labelled with who sent it, because what the practice needs to read later is
-- one thread about one client.
--
-- ── consent, per number ──────────────────────────────────────
--
-- Consent has always been per number - `sms_consent_events` carries the phone
-- it was given for - and only the client record had room for one number. So
-- this is less of a change than it looks: the events stay as they are, a
-- `contact_id` is added so a contact's consent says whose it is, and
-- `sms_consent_numbers` answers "may this number be texted" for every number
-- the practice holds. Nothing is flipped: Francis records them one by one.

begin;

-- ── the label on the number texts go to ──────────────────────

alter table public.clients
  add column if not exists phone_label text not null default 'Mobile';

alter table public.clients drop constraint if exists clients_phone_label_known;
alter table public.clients add constraint clients_phone_label_known
  check (phone_label in ('Mobile', 'Home', 'Work', 'Other'));

comment on column public.clients.phone is
  'The number texts go to. Every other number this client has is a row in '
  'client_phones; client_numbers reads the two as one list.';

-- ── the other numbers ────────────────────────────────────────

create table if not exists public.client_phones (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.clients(id) on delete cascade,
  label text not null default 'Mobile',
  phone text not null,
  note text not null default '',
  added_by uuid references public.staff(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint client_phones_label_known check (label in ('Mobile', 'Home', 'Work', 'Other')),
  -- Kept in the one form the whole practice matches on, so an inbound text
  -- from (801) 555-0101 finds +18015550101.
  constraint client_phones_normalized check (phone = public.normalize_phone(phone)),
  constraint client_phones_once unique (client_id, phone)
);

comment on table public.client_phones is
  'The numbers a client has besides the one texts go to. Labelled, because '
  '"do not ring the work one after five" is the sort of thing a person needs '
  'to see before they dial.';

create index if not exists client_phones_by_number on public.client_phones (phone);

-- ── the people around them ───────────────────────────────────

create table if not exists public.client_contacts (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.clients(id) on delete cascade,
  name text not null,
  relationship text not null,
  phone text,
  phone_label text not null default 'Mobile',
  email text not null default '',
  receives_updates boolean not null default false,
  may_speak_for boolean not null default false,
  note text not null default '',
  active boolean not null default true,
  added_by uuid references public.staff(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint client_contacts_has_a_name check (btrim(name) <> ''),
  constraint client_contacts_has_a_relationship check (btrim(relationship) <> ''),
  constraint client_contacts_label_known check (phone_label in ('Mobile', 'Home', 'Work', 'Other')),
  constraint client_contacts_normalized
    check (phone is null or phone = public.normalize_phone(phone)),
  constraint client_contacts_once unique (client_id, phone)
);

comment on table public.client_contacts is
  'A person around a client: who they are, how they are related, and whether '
  'they get the weekly update or may speak for the client. Never a client — '
  'there is nowhere on this row to put a caseload, a stage, a counselor or an '
  'authorization, which is what makes that structural rather than a promise.';

create index if not exists client_contacts_by_number on public.client_contacts (phone)
  where phone is not null;
create index if not exists client_contacts_for_updates on public.client_contacts (client_id)
  where receives_updates and active;

-- A contact's number is not one of the client's own. An inbound text matches
-- the client's numbers first, so a number on both would always read as the
-- client and the contact's label would never be seen - and a reply would be
-- filed as though the client had sent it.
create or replace function public.contact_number_is_not_the_clients()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if new.phone is null then
    return new;
  end if;
  if exists (select 1 from public.clients c
              where c.id = new.client_id and public.normalize_phone(c.phone) = new.phone) then
    raise exception 'That is the number this client is texted at, so it cannot be a contact as well.'
      using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.client_phones p
              where p.client_id = new.client_id and p.phone = new.phone) then
    raise exception 'That number is already on this client''s own record.'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

drop trigger if exists client_contacts_own_number on public.client_contacts;
create trigger client_contacts_own_number
  before insert or update of phone, client_id on public.client_contacts
  for each row execute function public.contact_number_is_not_the_clients();

-- And the other way round: a number added to the client's own record cannot
-- be one their contact is reached on.
create or replace function public.client_number_is_not_a_contacts()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if exists (select 1 from public.client_contacts t
              where t.client_id = new.client_id and t.phone = new.phone and t.active) then
    raise exception 'That number belongs to one of this client''s contacts.'
      using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.clients c
              where c.id = new.client_id and public.normalize_phone(c.phone) = new.phone) then
    raise exception 'That is already the number this client is texted at.'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

drop trigger if exists client_phones_not_a_contacts on public.client_phones;
create trigger client_phones_not_a_contacts
  before insert or update of phone, client_id on public.client_phones
  for each row execute function public.client_number_is_not_a_contacts();

-- ── the two lists read as one ────────────────────────────────

create or replace view public.client_numbers as
  select c.id as client_id,
         null::uuid as phone_id,
         null::uuid as contact_id,
         public.normalize_phone(c.phone) as phone,
         c.phone_label as label,
         true as texts_here,
         'Client'::text as whose,
         c.name as whose_name,
         ''::text as relationship,
         ''::text as note
    from public.clients c
   where public.normalize_phone(c.phone) is not null
  union all
  select p.client_id, p.id, null::uuid, p.phone, p.label, false,
         'Client'::text, c.name, ''::text, p.note
    from public.client_phones p
    join public.clients c on c.id = p.client_id
  union all
  select t.client_id, null::uuid, t.id, t.phone, t.phone_label, false,
         'Contact'::text, t.name, t.relationship, t.note
    from public.client_contacts t
   where t.phone is not null and t.active;

alter view public.client_numbers set (security_invoker = on);
comment on view public.client_numbers is
  'Every number the practice holds for a client: their own, the others on '
  'their record, and their contacts. One of them is the number texts go to.';
-- Supabase grants a new view every privilege to `authenticated`, so a view
-- meant to be read arrives writable. Revoked from the role as well as from
-- public and anon: verify_view_grants asks the question that found this.
revoke all on public.client_numbers from public, anon, authenticated;
grant select on public.client_numbers to authenticated;
grant select on public.client_numbers to service_role;

-- ── consent, per number ──────────────────────────────────────

alter table public.sms_consent_events
  add column if not exists contact_id uuid references public.client_contacts(id) on delete set null;

comment on column public.sms_consent_events.contact_id is
  'The contact this consent is for, where the number is a contact''s rather '
  'than the client''s own. The client is on the row either way, because the '
  'conversation files on the client.';

create or replace view public.sms_consent_numbers as
  select n.client_id,
         n.contact_id,
         n.phone,
         n.label,
         n.whose,
         n.whose_name,
         n.relationship,
         n.texts_here,
         e.state,
         e.at as since,
         e.method,
         e.note,
         coalesce(e.state, '') = 'Granted' as can_text
    from public.client_numbers n
    left join lateral (
      select x.state, x.at, x.method, x.note
        from public.sms_consent_events x
       where x.client_id = n.client_id and x.phone = n.phone
       order by x.at desc, x.seq desc
       limit 1
    ) e on true;

alter view public.sms_consent_numbers set (security_invoker = on);
comment on view public.sms_consent_numbers is
  'Whether each number the practice holds may be texted, and what was '
  'recorded about it. Consent is per number and always has been.';
revoke all on public.sms_consent_numbers from public, anon, authenticated;
grant select on public.sms_consent_numbers to authenticated;
grant select on public.sms_consent_numbers to service_role;

/*
 * The client's own consent, read from the number texts go to.
 *
 * This took the client's latest consent event whatever number it was for.
 * With contacts on the record that is wrong in a way that would have been
 * quiet and bad: recording consent for a client's daughter-in-law would have
 * been the client's latest event, its phone would not match the client's, and
 * the client would have stopped being textable with nothing on screen saying
 * why. The lateral now asks about the one number this view is about.
 */
create or replace view public.client_sms_consent as
  select c.id as client_id,
         public.normalize_phone(c.phone) as client_phone,
         e.state,
         e.phone as consented_phone,
         e.method,
         e.at as since,
         e.staff_id,
         e.state = 'Granted'
           and e.phone = public.normalize_phone(c.phone)
           and public.normalize_phone(c.phone) is not null as can_text
    from public.clients c
    left join lateral (
      select x.id, x.seq, x.client_id, x.state, x.phone, x.method, x.note, x.at, x.staff_id
        from public.sms_consent_events x
       where x.client_id = c.id
         and x.phone = public.normalize_phone(c.phone)
       order by x.at desc, x.seq desc
       limit 1
    ) e on true;

alter view public.client_sms_consent set (security_invoker = on);

commit;
