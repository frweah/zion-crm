-- Zion Vocational Rehab CRM — the weekly update
--
-- Part B of the owner's order of 9 November 2026. Every Friday afternoon, a
-- text per active client and per contact who receives updates, drafted from
-- the week, approved by a person, and sent one at a time.
--
-- ── what the draft is made of, and what it is not ────────────
--
-- **Not the weekly report.** The practice already assembles a week per client
-- for the counselor, and the first one looked at while writing this contained
-- two other people's first names, an internal financial review, and a note
-- marked as held back from the counselor. Quoting staff prose at a client
-- cannot be made safe by rules about what not to write, because the rules
-- would have to be applied by whoever wrote the note six days earlier.
--
-- So a draft is assembled from **facts with a shape**: how many jobs were
-- applied for, whether there was an interview, whether a job started, when
-- the next appointment is. Counts and dates. There is no path from a note, a
-- contact log entry, a report or an authorization into the body of a text,
-- which is what makes "no health, benefits, legal or employer-internal
-- detail" a property of the design rather than a promise.
--
-- The facts are kept on the draft as they were read, so a text somebody
-- queries in March can be read against what the record said in November.
--
-- ── and what happens to it ───────────────────────────────────
--
-- Drafted, then approved, then sent, each by a click. Nothing in here sends
-- anything: `send_weekly_update` is called by a person and writes the text
-- the ordinary way, through `sms_messages`, where the consent rule, the
-- 8am-9pm rule and the STOP rule all already live. A number with no consent
-- is not a draft that fails on sending - the screen says it cannot be sent
-- and why, before anybody clicks.
--
-- An unsent draft is logged as not sent after the Sunday night it belongs to.
-- A week-old update sent on a Monday is worse than no update: it tells
-- somebody about a week that is over as though it were news.

begin;

-- ── the language a client reads ──────────────────────────────
-- Asked for by the owner as "client's language if set". The field is here and
-- the draft carries it; what is **not** here is a translation, because this
-- practice has no translations and a machine translation of a sentence about
-- somebody's job search is not a thing to send unread. A draft for a client
-- whose language is set is drafted in English and flagged, and the screen it
-- is approved on is the screen it can be rewritten on.
alter table public.clients
  add column if not exists language text not null default '';

comment on column public.clients.language is
  'The language this client reads, where it is not English. The weekly update '
  'is drafted in English whatever it says and flagged for rewriting: there '
  'are no translations in this practice, and an unread machine translation is '
  'not something to send.';

-- ── the drafts ───────────────────────────────────────────────

create table if not exists public.weekly_updates (
  id uuid primary key default gen_random_uuid(),
  -- The Monday of the week being reported on.
  week_start date not null,
  client_id uuid not null references public.clients(id) on delete cascade,
  -- Null means the client themselves; otherwise the contact it is for.
  contact_id uuid references public.client_contacts(id) on delete cascade,
  -- The number it would go to, as it was when the draft was made. Kept so a
  -- draft can say what it was going to do even after a number changes.
  phone text,
  language text not null default '',
  body text not null,
  facts jsonb not null default '{}'::jsonb,
  state text not null default 'Draft',
  reason text not null default '',
  drafted_at timestamptz not null default now(),
  edited_by uuid references public.staff(id) on delete set null,
  edited_at timestamptz,
  decided_by uuid references public.staff(id) on delete set null,
  decided_at timestamptz,
  sent_at timestamptz,
  sms_id uuid references public.sms_messages(id) on delete set null,
  constraint weekly_updates_state_known
    check (state in ('Draft', 'Approved', 'Sent', 'Not sent')),
  constraint weekly_updates_week_is_a_monday
    check (extract(isodow from week_start) = 1),
  constraint weekly_updates_sent_says_so
    check (state <> 'Sent' or (sent_at is not null and sms_id is not null)),
  constraint weekly_updates_not_sent_says_why
    check (state <> 'Not sent' or btrim(reason) <> '')
);

comment on table public.weekly_updates is
  'One drafted text per client, and per contact who receives updates, for one '
  'week. Drafted by the Friday sweep, approved and sent by a person, and '
  'logged as not sent if the week goes by without either.';

-- One draft per person per week, counting the client themselves as one of
-- them. Two indexes because a null contact_id is distinct from every other
-- null, so a single unique constraint would let a client have two.
create unique index if not exists weekly_updates_one_per_client
  on public.weekly_updates (week_start, client_id) where contact_id is null;
create unique index if not exists weekly_updates_one_per_contact
  on public.weekly_updates (week_start, contact_id) where contact_id is not null;
create index if not exists weekly_updates_by_state
  on public.weekly_updates (state, week_start desc);

alter table public.weekly_updates enable row level security;

drop policy if exists weekly_updates_read on public.weekly_updates;
create policy weekly_updates_read on public.weekly_updates
  for select using ((select public.is_active_staff()));
select public.apply_system_read_only('public.weekly_updates');

revoke all on public.weekly_updates from public, anon, authenticated;
grant select on public.weekly_updates to authenticated;
grant all on public.weekly_updates to service_role;

-- A text kind of its own, so the texts screen and the client's record can say
-- what a message was.
alter table public.sms_messages drop constraint if exists sms_messages_kind_check;
alter table public.sms_messages add constraint sms_messages_kind_check
  check (kind in ('Reminder', 'Manual', 'System', 'Reply', 'Weekly update'));

commit;
