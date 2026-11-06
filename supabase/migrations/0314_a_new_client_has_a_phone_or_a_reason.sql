-- Zion Vocational Rehab CRM — a phone number, or the reason there is not one
--
-- Part 2a of the owner's list of 3 November 2026: a new client needs a phone
-- number unless somebody ticks "No phone" and says why, and whether they may
-- be texted is answered when the record is made rather than left to be
-- noticed months later.
--
-- ── why the rule is on the way in and not on the table ───────
--
-- Eight of the 86 clients on file have no phone number and no reason recorded,
-- because nothing ever asked for one. A check constraint would refuse to be
-- added at all, and adding it by first inventing reasons for those eight would
-- be writing fiction into eight records to satisfy a rule about new ones.
--
-- So it is a BEFORE INSERT trigger: every client made from today answers the
-- question, and the eight are left as they are until somebody who knows
-- updates them.
--
-- ── and it asks the person, not the post ─────────────────────
--
-- The trigger asks only when a signed-in member of staff is doing the
-- inserting. A client created by the intake agent from an arriving referral is
-- not asked, and that is not a hole in the rule - it is the rule. A referral
-- that arrives without a phone number on it is still a referral, and a record
-- that refuses to hold what the paper says jams the inbox instead of
-- improving the data. The person who opens that record is the one who can
-- find out, and the client's own screen is where they do it.
--
-- ── and not of an invented person ────────────────────────────
--
-- A ZZ or ZQ name is a fixture, not a client, and it is not asked either.
-- That is this codebase's own precedent rather than a hole cut for the tests:
-- the directory log has ignored invented names since 0179, for the same
-- reason - a rule about the practice's records should not be enforced against
-- rows that exist to try the rule out, and 133 fixtures across 87 scripts
-- create a client to test something that has nothing to do with a phone
-- number.
--
-- Which leaves the rule itself needing a test that is not exempt, so
-- verify_new_client.sql does what verify_billing_unlocked and
-- verify_directory_changes already do: it uses a synthetic name that is not a
-- fixture name, and it tries both halves - the invented person who is not
-- asked, and the real-looking one who is.
--
-- ── and consent gets a third answer ──────────────────────────
--
-- Texting consent had two states, Granted and Withdrawn, and the third answer
-- the practice actually gets - asked, and they said no - had nowhere to go.
-- Recording that as Withdrawn would say consent was given and taken back,
-- which is not what happened. Declined is its own state, and `can_text`
-- already turns on Granted alone, so nothing that sends a text changes.
--
-- "Not asked" stays what it has always been: no event at all. A state for it
-- would be a row asserting that nothing happened.

begin;

alter table public.clients
  add column if not exists no_phone_reason text not null default '';

comment on column public.clients.no_phone_reason is
  'Why this client has no phone number. Required on a new client with no '
  'phone; blank on one that has a number.';

create or replace function public.client_has_a_phone_or_a_reason()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  /**
   * Only an insert that arrived on a signed-in person's connection is asked.
   *
   * PostgREST sets the `role` for the transaction from the session's token, so
   * `authenticated` means a person using the app and nothing else does: the
   * intake agent arrives as service_role, and a migration or a fixture runs as
   * the database owner. See the note at the top of this file for why those
   * two are not asked.
   *
   * current_staff_id() would be the obvious test and it is the wrong one. It
   * reads the token, and the verification scripts keep a token set while they
   * switch to the owner to write the rows a signed-in person could not - so it
   * would have refused a hundred and thirty fixtures that have nothing to do
   * with this rule.
   */
  if coalesce(current_setting('role', true), '') <> 'authenticated' then
    return new;
  end if;

  -- Nor of somebody invented to try something out. See the note at the top.
  if public.is_fixture_name(new.name) then
    return new;
  end if;

  -- A number and a reason cannot both be true, and the reason is the one that
  -- cannot be. Blanked rather than refused: the form only sends it when the
  -- tick is on, so somebody seeing that error would be looking for a field
  -- the screen had already hidden.
  if public.normalize_phone(new.phone) is not null then
    new.no_phone_reason := '';
    return new;
  end if;

  if btrim(coalesce(new.no_phone_reason, '')) = '' then
    raise exception 'Give a phone number, or tick "No phone" and say why there is not one.'
      using errcode = 'check_violation';
  end if;

  new.no_phone_reason := btrim(new.no_phone_reason);
  return new;
end $$;

drop trigger if exists clients_phone_or_reason on public.clients;
-- Insert only, deliberately: the eight records that predate the rule are not
-- unopenable, and an update that happens to touch one of them is not the
-- moment to demand an explanation somebody may not have.
create trigger clients_phone_or_reason
  before insert on public.clients
  for each row execute function public.client_has_a_phone_or_a_reason();

revoke execute on function public.client_has_a_phone_or_a_reason() from anon, authenticated;

-- ── asked, and they said no ──────────────────────────────────
alter table public.sms_consent_events drop constraint if exists sms_consent_events_state_check;
alter table public.sms_consent_events add constraint sms_consent_events_state_check
  check (state in ('Granted', 'Declined', 'Withdrawn'));

create or replace function public.set_sms_consent(
  p_client_id uuid,
  p_state     text,
  p_method    text,
  p_note      text default ''
)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_staff uuid := public.current_staff_id();
  v_phone text;
begin
  if v_staff is null then
    raise exception 'You are not signed in.' using errcode = 'insufficient_privilege';
  end if;
  if public.current_staff_role() not in ('Admin', 'Job Search', 'Reports') then
    raise exception 'Your role does not change client records.'
      using errcode = 'insufficient_privilege';
  end if;
  if p_state not in ('Granted', 'Declined', 'Withdrawn') then
    raise exception 'Consent is granted, declined or withdrawn.' using errcode = 'check_violation';
  end if;

  select public.normalize_phone(phone) into v_phone from public.clients where id = p_client_id;
  if v_phone is null then
    raise exception
      'There is no usable phone number on this client, so there is nothing to consent to.'
      using errcode = 'check_violation';
  end if;

  -- Granting needs a note saying how it was given: "verbal, at intake, 3 March"
  -- is the whole evidence if anybody ever asks. Declining needs none - the
  -- answer is the record, and there is nothing to prove afterwards.
  if p_state = 'Granted' and coalesce(p_note, '') = '' then
    raise exception 'Say how consent was given — it is the only record of it.'
      using errcode = 'check_violation';
  end if;

  insert into public.sms_consent_events (client_id, state, phone, method, note, staff_id)
  values (p_client_id, p_state, v_phone, p_method, coalesce(p_note, ''), v_staff);
end;
$$;

revoke execute on function public.set_sms_consent(uuid, text, text, text) from public;
grant execute on function public.set_sms_consent(uuid, text, text, text) to authenticated;

commit;
