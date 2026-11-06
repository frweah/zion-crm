-- Zion Vocational Rehab CRM — "To file"
--
-- Item E of the owner's list: one inbox per member of staff on My day. Each
-- item is something the system noticed - an appointment in somebody's Outlook
-- calendar, an email mentioning a client, later a recording - with a guess at
-- which client it belongs to, and three things a person can do with it:
-- assign it to a client, confirm it, or discard it.
--
-- ── the rule the whole design turns on ───────────────────────
--
-- "Unconfirmed never appears in a report." Not "is filtered out of reports" -
-- never appears. So an unconfirmed item is not a row on the client's record
-- at all: it lives here, in this table, keyed to the person whose inbox it is,
-- and confirming is the act that writes the contact-log entry. A report
-- cannot leave out what was never there, and nobody has to remember to.
--
-- That was not the obvious design. The obvious one is to write the
-- appointment onto the client as an unconfirmed calendar event and have the
-- report skip it - and a report draft reads this client's calendar events, so
-- the day somebody adds a section or writes a new report template, the
-- unconfirmed appointment is in it. The brief says "never", and never is
-- structural or it is a convention.
--
-- ── and the second rule ─────────────────────────────────────
--
-- "Never auto-file from here." Nothing in this table reaches a client's
-- record except through to_file_confirm, which a person calls. The sweeps can
-- only offer: to_file_offer is the service role's and writes nothing but a
-- row in this inbox.
--
-- ── a category on a contact ─────────────────────────────────
--
-- "Confirmed items become contact-log entries (with category)." The contact
-- log had no category, so it gets one, from the same list the notes use - and
-- Personal is left out of a report the way it already is for a note.

begin;

create table if not exists public.to_file (
  id          uuid primary key default gen_random_uuid(),
  -- Whose inbox. One per member of staff, which is what makes the thing a
  -- person can clear rather than a queue everybody looks at and nobody owns.
  staff_id    uuid not null references public.staff(id) on delete cascade,

  source      text not null,
  -- What it is in the place it came from: the Outlook event id, the message
  -- id, the recording's attachment. Unique per person and source, so a sweep
  -- that runs twice - or looks back sixty days and then looks again - offers
  -- the same thing once.
  source_key  text not null,

  -- The guess, and why. Null is an honest answer and the screen says so.
  client_id   uuid references public.clients(id) on delete set null,
  guess_why   text not null default '',

  -- When the thing happened, which is not when it was noticed.
  happened_at timestamptz,
  title       text not null default '',
  detail      text not null default '',

  state       text not null default 'Waiting',
  -- What the person said when they confirmed it. For an appointment: it
  -- happened, it did not, or it was the wrong client - and the third of those
  -- is not an answer about the client, it is a correction to the guess, so it
  -- puts the item back in the inbox with the guess removed.
  outcome     text not null default '',
  category    text,
  note        text not null default '',

  -- What confirming it made, so the screen can show where it went and
  -- verify_to_file can prove discarding made nothing.
  contact_id  uuid references public.contact_log(id) on delete set null,

  decided_by      uuid references public.staff(id) on delete set null,
  decided_by_name text not null default '',
  decided_at      timestamptz,
  created_at      timestamptz not null default now(),

  constraint to_file_source_check
    check (source in ('Calendar', 'Email', 'Recording')),
  constraint to_file_state_check
    check (state in ('Waiting', 'Confirmed', 'Discarded')),
  constraint to_file_outcome_check
    check (outcome in ('', 'happened', 'did not happen', 'wrong client')),
  constraint to_file_category_check
    check (category is null or category in (
      'Job development', 'Job placement', 'Job coaching', 'Job search',
      'Assessment', 'Life skills', 'General progress', 'Personal')),
  -- A confirmed item says what was decided and who decided it. A waiting one
  -- says neither, so a half-written decision cannot sit there looking final.
  constraint to_file_decided_says_so
    check ((state = 'Waiting' and decided_at is null)
           or (state <> 'Waiting' and decided_at is not null and decided_by is not null)),
  constraint to_file_confirmed_has_an_outcome
    check (state <> 'Confirmed' or outcome <> '')
);

create unique index if not exists to_file_one_per_thing
  on public.to_file (staff_id, source, source_key);
create index if not exists to_file_waiting_idx
  on public.to_file (staff_id, state, happened_at desc);
create index if not exists to_file_client_idx on public.to_file (client_id);

comment on table public.to_file is
  'One inbox per member of staff of things the system noticed and nobody has '
  'filed: an appointment, an email, a recording. Nothing here is on a '
  'client''s record until somebody confirms it, which is what makes '
  '"unconfirmed never appears in a report" true rather than remembered.';

-- ── a contact has a category now ────────────────────────────
alter table public.contact_log
  add column if not exists category text;

alter table public.contact_log drop constraint if exists contact_log_category_check;
alter table public.contact_log add constraint contact_log_category_check
  check (category is null or category in (
    'Job development', 'Job placement', 'Job coaching', 'Job search',
    'Assessment', 'Life skills', 'General progress', 'Personal'));

comment on column public.contact_log.category is
  'Which part of the work this contact was about, from the same list the '
  'notes use. Personal is left out of a report, as it is for a note.';

-- ── whose item is it ────────────────────────────────────────
create or replace function public.to_file_is_mine(p_item uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select exists (
    select 1 from public.to_file f
     where f.id = p_item
       and (f.staff_id = public.current_staff_id()
            -- Admin answers for the practice and can clear somebody's inbox
            -- while they are away. Nobody else can: an item is a person's own
            -- judgment about their own day.
            or public.current_staff_role() = 'Admin')
  )
$$;

revoke all on function public.to_file_is_mine(uuid) from public, anon;
grant execute on function public.to_file_is_mine(uuid) to authenticated;

-- ── what the sweeps may do, which is offer ──────────────────
create or replace function public.to_file_offer(
  p_staff      uuid,
  p_source     text,
  p_source_key text,
  p_title      text,
  p_detail     text default '',
  p_happened   timestamptz default null,
  p_client     uuid default null,
  p_guess_why  text default '')
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_id uuid;
begin
  -- The sweeps run with nobody signed in, behind the cron secret, as the
  -- service role. A signed-in person has no business putting things in
  -- somebody's inbox: there are screens for that.
  if coalesce(auth.role(), '') <> 'service_role' then
    perform public.refuse_elevated('to_file_offer',
      'Only the nightly sweep offers something to file.');
  end if;

  if coalesce(btrim(p_source_key), '') = '' then
    raise exception 'Something to file has to say what it is, or it cannot be offered once.'
      using errcode = 'check_violation';
  end if;

  -- Offered once. A second sighting of the same event updates what it says
  -- about itself and leaves the decision alone - so a sweep that looks back
  -- sixty days on Monday and a day on Tuesday does not undo Monday's work.
  insert into public.to_file
    (staff_id, source, source_key, title, detail, happened_at, client_id, guess_why)
  values
    (p_staff, p_source, btrim(p_source_key), coalesce(p_title, ''), coalesce(p_detail, ''),
     p_happened, p_client, coalesce(p_guess_why, ''))
  on conflict (staff_id, source, source_key) do update
     set title = excluded.title,
         detail = excluded.detail,
         happened_at = coalesce(excluded.happened_at, public.to_file.happened_at),
         -- The guess is only improved where there was none. A person who
         -- assigned it to somebody keeps that.
         client_id = case when public.to_file.state = 'Waiting' and public.to_file.decided_at is null
                               and public.to_file.client_id is null
                          then excluded.client_id else public.to_file.client_id end,
         guess_why = case when public.to_file.client_id is null
                          then excluded.guess_why else public.to_file.guess_why end
   returning id into v_id;

  return v_id;
end $$;

revoke all on function public.to_file_offer(uuid, text, text, text, text, timestamptz, uuid, text)
  from public, anon, authenticated;

-- ── assign it to a client ───────────────────────────────────
create or replace function public.to_file_assign(p_item uuid, p_client uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if not public.to_file_is_mine(p_item) then
    raise exception 'That is not in your inbox.' using errcode = 'insufficient_privilege';
  end if;
  if not exists (select 1 from public.clients where id = p_client and merged_into is null) then
    raise exception 'That client is not on file.' using errcode = 'no_data_found';
  end if;
  if exists (select 1 from public.to_file where id = p_item and state <> 'Waiting') then
    raise exception 'That has been dealt with already.' using errcode = 'check_violation';
  end if;

  update public.to_file
     set client_id = p_client,
         guess_why = 'Assigned by hand',
         outcome = ''
   where id = p_item;
end $$;

revoke all on function public.to_file_assign(uuid, uuid) from public, anon, authenticated;
grant execute on function public.to_file_assign(uuid, uuid) to authenticated;

-- ── confirm it, which is the only way onto a record ─────────
create or replace function public.to_file_confirm(
  p_item     uuid,
  p_outcome  text,
  p_note     text default '',
  p_category text default null)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_item  public.to_file%rowtype;
  v_staff uuid := public.current_staff_id();
  v_name  text;
  v_id    uuid;
begin
  if not public.to_file_is_mine(p_item) then
    raise exception 'That is not in your inbox.' using errcode = 'insufficient_privilege';
  end if;

  select * into v_item from public.to_file where id = p_item for update;
  if v_item.state <> 'Waiting' then
    raise exception 'That has been dealt with already.' using errcode = 'check_violation';
  end if;
  if p_outcome not in ('happened', 'did not happen', 'wrong client') then
    raise exception 'Say whether it happened, did not happen, or was the wrong client.'
      using errcode = 'check_violation';
  end if;

  select name into v_name from public.staff where id = v_staff;

  /**
   * The wrong client is not a decision about the item.
   *
   * It says the guess was wrong, so the guess goes and the item waits for
   * somebody to say whose it is. Marking it Confirmed would file a judgment
   * about a client it turned out not to be about.
   */
  if p_outcome = 'wrong client' then
    update public.to_file
       set client_id = null, guess_why = 'The guess was wrong', outcome = ''
     where id = p_item;
    return null;
  end if;

  if v_item.client_id is null then
    raise exception 'Say which client it was about first.'
      using hint = 'Assign it to a client, then confirm it.', errcode = 'check_violation';
  end if;

  -- It happened: the contact log gets the entry, and that entry is what a
  -- report reads. Nothing was on the record before this line ran.
  if p_outcome = 'happened' then
    insert into public.contact_log
      (client_id, date, method, topic, outcome, category, staff_id)
    values
      (v_item.client_id,
       coalesce(v_item.happened_at::date, public.practice_today()),
       case v_item.source when 'Calendar' then 'Appointment'
                          when 'Email' then 'Email'
                          else 'Recording' end,
       coalesce(nullif(btrim(v_item.title), ''), v_item.source),
       coalesce(nullif(btrim(p_note), ''), 'Happened'),
       p_category,
       coalesce(v_staff, v_item.staff_id))
    returning id into v_id;
  end if;

  update public.to_file
     set state = 'Confirmed',
         outcome = p_outcome,
         note = btrim(coalesce(p_note, '')),
         category = p_category,
         contact_id = v_id,
         decided_by = v_staff,
         decided_by_name = coalesce(v_name, ''),
         decided_at = now()
   where id = p_item;

  return v_id;
end $$;

revoke all on function public.to_file_confirm(uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.to_file_confirm(uuid, text, text, text) to authenticated;

-- ── or discard it, which leaves no trace on anybody ─────────
create or replace function public.to_file_discard(p_item uuid, p_reason text default '')
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_staff uuid := public.current_staff_id();
  v_name  text;
begin
  if not public.to_file_is_mine(p_item) then
    raise exception 'That is not in your inbox.' using errcode = 'insufficient_privilege';
  end if;
  if exists (select 1 from public.to_file where id = p_item and state <> 'Waiting') then
    raise exception 'That has been dealt with already.' using errcode = 'check_violation';
  end if;

  select name into v_name from public.staff where id = v_staff;

  -- The row stays, discarded, so the sweep that offered it does not offer it
  -- again tomorrow. Nothing is written about the client, which is the whole
  -- point of discarding it.
  update public.to_file
     set state = 'Discarded',
         note = btrim(coalesce(p_reason, '')),
         decided_by = v_staff,
         decided_by_name = coalesce(v_name, ''),
         decided_at = now()
   where id = p_item;
end $$;

revoke all on function public.to_file_discard(uuid, text) from public, anon, authenticated;
grant execute on function public.to_file_discard(uuid, text) to authenticated;

-- ── who may read it ─────────────────────────────────────────
alter table public.to_file enable row level security;

drop policy if exists to_file_read on public.to_file;
create policy to_file_read on public.to_file
  for select using (
    (select public.is_active_staff())
    and (staff_id = (select public.current_staff_id())
         -- Admin and the intake desk see every inbox, because somebody has to
         -- be able to answer "has anybody filed this" for the practice.
         or (select public.current_staff_role()) in ('Admin', 'Reports')));

-- No write policy: every change goes through a function that says who made it
-- and what it did, the way payments and the invoice ledger do.
revoke all on public.to_file from anon, authenticated;
grant select on public.to_file to authenticated;

select public.apply_system_read_only('to_file');

commit;
