-- Zion Vocational Rehab CRM — one door to a number, a contact, and consent
--
-- The second half of part A. The tables are in 0330; this is who may write to
-- them and what happens when a text arrives.
--
-- Every write goes through a function. Not for ceremony: a number has to be
-- normalised to the one form the whole practice matches on, a contact's
-- number must not be one the client is already reached on, and the number
-- texts go to has to be swapped rather than set — three rules that a screen
-- doing its own INSERT would each have to remember.
--
-- ── and consent is asked about a number ──────────────────────
--
-- `set_sms_consent` took a client and recorded whatever number was on their
-- record. It now takes the number, because the number is what consent is
-- about and a client may have three. The old four-argument version is dropped
-- rather than left beside it: a defaulted parameter makes a second function,
-- and a second function is a second door with its own rules (0322 cost a day
-- to that).
--
-- ── a text from a contact files on the client ────────────────
--
-- Labelled with who sent it. One thread per number, all of them on the
-- client's record, so "what did we say to this family" is one screen and not
-- three. An inbound text matches the client's own numbers first and their
-- contacts' second, which is the order the owner asked for and also the only
-- order that cannot mislabel a client as their own daughter-in-law.

begin;

-- ── who may read, and nobody writes directly ─────────────────

drop policy if exists client_phones_read on public.client_phones;
create policy client_phones_read on public.client_phones
  for select using ((select public.is_active_staff()));
select public.apply_system_read_only('public.client_phones');

drop policy if exists client_contacts_read on public.client_contacts;
create policy client_contacts_read on public.client_contacts
  for select using ((select public.is_active_staff()));
select public.apply_system_read_only('public.client_contacts');

revoke all on public.client_phones from public, anon;
revoke all on public.client_contacts from public, anon;
grant select on public.client_phones to authenticated;
grant select on public.client_contacts to authenticated;
grant all on public.client_phones to service_role;
grant all on public.client_contacts to service_role;

-- There is no insert, update or delete policy for a signed-in person on
-- either table, which is the point: the functions below are definers and they
-- are the only way in.

create or replace function public.keeps_client_records()
returns boolean
language sql
stable
set search_path to 'public'
as $$
  select public.current_staff_role() in ('Admin', 'Job Search', 'Reports');
$$;

comment on function public.keeps_client_records is
  'The three roles that keep client records, which is the same gate the '
  'clients table itself uses for an insert.';

revoke all on function public.keeps_client_records() from public, anon;
grant execute on function public.keeps_client_records() to authenticated, service_role;

-- ── which number texts go to ─────────────────────────────────

create or replace function public.client_texting_number(p_client uuid)
returns text
language sql
stable
set search_path to 'public'
as $$
  select public.normalize_phone(c.phone) from public.clients c where c.id = p_client;
$$;

comment on function public.client_texting_number is
  'The number texts go to for a client, in the one form the practice matches '
  'on. Asked rather than remembered: the number can be swapped for another on '
  'the record, and a caller holding one from earlier is holding a stale one.';

revoke all on function public.client_texting_number(uuid) from public, anon;
grant execute on function public.client_texting_number(uuid) to authenticated, service_role;

-- ── a number ─────────────────────────────────────────────────

create or replace function public.add_client_phone(
  p_client uuid, p_label text, p_phone text, p_note text
) returns uuid
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_phone text := public.normalize_phone(p_phone);
  v_id    uuid;
begin
  if not public.keeps_client_records() then
    raise exception 'Your role does not change client records.' using errcode = 'insufficient_privilege';
  end if;
  if v_phone is null then
    raise exception 'That is not a phone number we can use: %', coalesce(p_phone, 'nothing')
      using errcode = 'check_violation';
  end if;
  if not exists (select 1 from public.clients where id = p_client) then
    raise exception 'That client does not exist.' using errcode = 'no_data_found';
  end if;

  -- The client has no number at all yet, so this is the one texts go to
  -- rather than a second one. The no_phone_reason goes with it: a client with
  -- a number no longer needs a reason for having none (0314).
  if (select public.normalize_phone(phone) from public.clients where id = p_client) is null then
    update public.clients
       set phone = v_phone, phone_label = coalesce(nullif(btrim(p_label), ''), 'Mobile'),
           no_phone_reason = ''
     where id = p_client;
    return null;
  end if;

  insert into public.client_phones (client_id, label, phone, note, added_by)
  values (p_client, coalesce(nullif(btrim(p_label), ''), 'Mobile'), v_phone,
          btrim(coalesce(p_note, '')), public.current_staff_id())
  returning id into v_id;
  return v_id;
end;
$$;

comment on function public.add_client_phone is
  'Another number for a client, labelled. The first number a client has is '
  'the one texts go to, because there is nothing to choose between.';

revoke all on function public.add_client_phone(uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.add_client_phone(uuid, text, text, text) to authenticated;

create or replace function public.remove_client_phone(p_phone uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if not public.keeps_client_records() then
    raise exception 'Your role does not change client records.' using errcode = 'insufficient_privilege';
  end if;
  delete from public.client_phones where id = p_phone;
  if not found then
    raise exception 'That number is not on the record.' using errcode = 'no_data_found';
  end if;
end;
$$;

revoke all on function public.remove_client_phone(uuid) from public, anon, authenticated;
grant execute on function public.remove_client_phone(uuid) to authenticated;

/*
 * The number texts go to, swapped rather than set.
 *
 * Both numbers stay on the record: the one that was being texted becomes an
 * ordinary labelled number, and the chosen one is lifted out of the list. A
 * version that simply wrote clients.phone would have lost the old number
 * altogether, which is how a practice ends up ringing a disconnected line
 * because the good one was overwritten.
 *
 * Consent does not move with it. Consent is about a number, and the number
 * this client agreed to be texted at is the number they agreed to - changing
 * which one the practice prefers says nothing about what they agreed. The
 * consent screen lists every number with its own answer.
 */
create or replace function public.set_texting_number(p_client uuid, p_phone text)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_phone text := public.normalize_phone(p_phone);
  v_was   text;
  v_label text;
  v_new   record;
begin
  if not public.keeps_client_records() then
    raise exception 'Your role does not change client records.' using errcode = 'insufficient_privilege';
  end if;
  if v_phone is null then
    raise exception 'That is not a phone number we can use.' using errcode = 'check_violation';
  end if;

  select public.normalize_phone(c.phone), c.phone_label into v_was, v_label
    from public.clients c where c.id = p_client;
  if v_was is not distinct from v_phone then
    return;
  end if;

  select * into v_new from public.client_phones p
   where p.client_id = p_client and p.phone = v_phone;
  if not found then
    raise exception 'That number is not on this client''s record.' using errcode = 'no_data_found';
  end if;

  -- The chosen one comes out of the list first, so the old one can go in
  -- without meeting the rule that a listed number is not the texting number.
  delete from public.client_phones where id = v_new.id;
  update public.clients
     set phone = v_phone, phone_label = v_new.label
   where id = p_client;
  if v_was is not null then
    insert into public.client_phones (client_id, label, phone, note, added_by)
    values (p_client, coalesce(nullif(v_label, ''), 'Mobile'), v_was, '', public.current_staff_id())
    on conflict (client_id, phone) do nothing;
  end if;
end;
$$;

comment on function public.set_texting_number is
  'Which of a client''s numbers texts go to. The other one stays on the '
  'record as an ordinary labelled number.';

revoke all on function public.set_texting_number(uuid, text) from public, anon, authenticated;
grant execute on function public.set_texting_number(uuid, text) to authenticated;

-- ── a contact ────────────────────────────────────────────────

create or replace function public.add_client_contact(
  p_client uuid,
  p_name text,
  p_relationship text,
  p_phone text,
  p_label text,
  p_email text,
  p_receives_updates boolean,
  p_may_speak_for boolean
) returns uuid
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_phone text := public.normalize_phone(p_phone);
  v_id    uuid;
begin
  if not public.keeps_client_records() then
    raise exception 'Your role does not change client records.' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(btrim(p_name), '') = '' then
    raise exception 'Who is it?' using errcode = 'check_violation';
  end if;
  if coalesce(btrim(p_relationship), '') = '' then
    raise exception 'Say how they are related — it goes on every text they send.'
      using errcode = 'check_violation';
  end if;
  if coalesce(btrim(p_phone), '') <> '' and v_phone is null then
    raise exception 'That is not a phone number we can use: %', p_phone
      using errcode = 'check_violation';
  end if;
  if not exists (select 1 from public.clients where id = p_client) then
    raise exception 'That client does not exist.' using errcode = 'no_data_found';
  end if;

  insert into public.client_contacts
    (client_id, name, relationship, phone, phone_label, email,
     receives_updates, may_speak_for, added_by)
  values
    (p_client, btrim(p_name), btrim(p_relationship), v_phone,
     coalesce(nullif(btrim(p_label), ''), 'Mobile'), btrim(coalesce(p_email, '')),
     coalesce(p_receives_updates, false), coalesce(p_may_speak_for, false),
     public.current_staff_id())
  returning id into v_id;
  return v_id;
end;
$$;

comment on function public.add_client_contact is
  'A person around a client. Never a client: this row has nowhere to put a '
  'caseload, and nothing in the practice makes one from it.';

revoke all on function public.add_client_contact(uuid, text, text, text, text, text, boolean, boolean)
  from public, anon, authenticated;
grant execute on function public.add_client_contact(uuid, text, text, text, text, text, boolean, boolean)
  to authenticated;

create or replace function public.edit_client_contact(
  p_contact uuid,
  p_name text,
  p_relationship text,
  p_phone text,
  p_label text,
  p_email text,
  p_receives_updates boolean,
  p_may_speak_for boolean,
  p_note text
) returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_phone text := public.normalize_phone(p_phone);
begin
  if not public.keeps_client_records() then
    raise exception 'Your role does not change client records.' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(btrim(p_name), '') = '' then
    raise exception 'Who is it?' using errcode = 'check_violation';
  end if;
  if coalesce(btrim(p_relationship), '') = '' then
    raise exception 'Say how they are related — it goes on every text they send.'
      using errcode = 'check_violation';
  end if;
  if coalesce(btrim(p_phone), '') <> '' and v_phone is null then
    raise exception 'That is not a phone number we can use: %', p_phone
      using errcode = 'check_violation';
  end if;

  update public.client_contacts
     set name = btrim(p_name),
         relationship = btrim(p_relationship),
         phone = v_phone,
         phone_label = coalesce(nullif(btrim(p_label), ''), 'Mobile'),
         email = btrim(coalesce(p_email, '')),
         receives_updates = coalesce(p_receives_updates, false),
         may_speak_for = coalesce(p_may_speak_for, false),
         note = btrim(coalesce(p_note, '')),
         updated_at = now()
   where id = p_contact;
  if not found then
    raise exception 'That contact is not on the record.' using errcode = 'no_data_found';
  end if;
end;
$$;

revoke all on function public.edit_client_contact(uuid, text, text, text, text, text, boolean, boolean, text)
  from public, anon, authenticated;
grant execute on function public.edit_client_contact(uuid, text, text, text, text, text, boolean, boolean, text)
  to authenticated;

/*
 * A contact who is no longer one.
 *
 * Marked inactive rather than deleted. A text from them is on the client's
 * record with their name and relationship on it, and deleting the row would
 * leave those texts labelled by nothing. The reason goes on the row, because
 * "stopped getting the weekly update in November" is the sort of thing
 * somebody asks about in March.
 */
create or replace function public.remove_client_contact(p_contact uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if not public.keeps_client_records() then
    raise exception 'Your role does not change client records.' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'Say why they are coming off the record.' using errcode = 'check_violation';
  end if;

  update public.client_contacts
     set active = false,
         receives_updates = false,
         note = btrim(btrim(coalesce(note, '')) || ' Off the record: ' || btrim(p_reason)),
         updated_at = now()
   where id = p_contact and active;
  if not found then
    raise exception 'That contact is not on the record.' using errcode = 'no_data_found';
  end if;
end;
$$;

revoke all on function public.remove_client_contact(uuid, text) from public, anon, authenticated;
grant execute on function public.remove_client_contact(uuid, text) to authenticated;

-- ── consent, about a number ──────────────────────────────────

-- Both signatures: the four-argument version this replaces, and the new one,
-- so the file can be run again without "already exists".
drop function if exists public.set_sms_consent(uuid, text, text, text);
drop function if exists public.set_sms_consent(uuid, text, text, text, text);

create function public.set_sms_consent(
  p_client_id uuid, p_phone text, p_state text, p_method text, p_note text
) returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_staff   uuid := public.current_staff_id();
  v_phone   text := public.normalize_phone(p_phone);
  v_contact uuid;
  v_whose   text;
begin
  if v_staff is null then
    raise exception 'You are not signed in.' using errcode = 'insufficient_privilege';
  end if;
  if not public.keeps_client_records() then
    raise exception 'Your role does not change client records.' using errcode = 'insufficient_privilege';
  end if;
  if p_state not in ('Granted', 'Declined', 'Withdrawn') then
    raise exception 'Consent is granted, declined or withdrawn.' using errcode = 'check_violation';
  end if;
  if v_phone is null then
    raise exception 'Which number is this consent for?' using errcode = 'check_violation';
  end if;

  -- The number has to be one the practice holds for this client, their own or
  -- a contact's. Consent recorded against a number nobody can reach is a
  -- record of nothing, and it would sit on the list for ever.
  select n.contact_id, n.whose into v_contact, v_whose
    from public.client_numbers n
   where n.client_id = p_client_id and n.phone = v_phone
   limit 1;
  if v_whose is null then
    raise exception 'That number is not on this client''s record.'
      using errcode = 'check_violation',
            hint = 'Add the number first, or the contact it belongs to.';
  end if;

  -- Granting needs a note saying how it was given: "verbal, at intake, 3 March"
  -- is the whole evidence if anybody ever asks. Declining needs none - the
  -- answer is the record, and there is nothing to prove afterwards.
  if p_state = 'Granted' and coalesce(btrim(p_note), '') = '' then
    raise exception 'Say how consent was given — it is the only record of it.'
      using errcode = 'check_violation';
  end if;

  insert into public.sms_consent_events (client_id, contact_id, state, phone, method, note, staff_id)
  values (p_client_id, v_contact, p_state, v_phone, p_method, coalesce(btrim(p_note), ''), v_staff);
end;
$$;

comment on function public.set_sms_consent is
  'Consent to text one number, which may be the client''s or a contact''s. '
  'Append-only: the latest event for a number is the answer for that number.';

revoke all on function public.set_sms_consent(uuid, text, text, text, text) from public, anon, authenticated;
grant execute on function public.set_sms_consent(uuid, text, text, text, text) to authenticated;

commit;
