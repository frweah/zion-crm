-- Zion Vocational Rehab CRM — a recording is read, and then confirmed
--
-- Item F, switched on 14 November 2026 once the Azure keys were in Vercel.
--
-- A recording is uploaded from a client's record or from the phone, read by
-- Azure Speech with diarization, drafted into a summary by Azure OpenAI, and
-- then **a person confirms it before any of it is on the record.** Until they
-- do, the transcript and the draft are a proposal: nothing is in the contact
-- log, nothing is a note, nothing reaches a counselor or a report.
--
-- That last part is the whole design, and it is the same one the document
-- inbox and "To file" are built on. A machine reading of a conversation about
-- somebody's disability, their benefits and their employer is the last thing
-- that should write itself onto a client's record.
--
-- ── restricted, by the category and by a rule ────────────────
--
-- Recordings are their own file category, restricted by default — which is
-- what the phone already reads when it uploads one. A default can be turned
-- off on a form, so there is a rule as well: **an audio attachment is
-- restricted, whatever category somebody chose.** Only the people who may
-- see a client's restricted documents can hear a recording or read what it
-- said.
--
-- ── and the cost guard ───────────────────────────────────────
--
-- Twenty hours a person a month, from `org_settings` so Admin can change it
-- without a deploy. It is checked **before the audio is sent to Azure**,
-- because that is the moment the money is spent: a recording over the limit
-- is held with the reason on it, and Admin → Money says who is near it.
--
-- Held rather than refused. The recording is already on the client's record
-- and the practice has it; what the limit stops is paying to transcribe it,
-- and somebody can raise the limit and let it through.

begin;

-- ── the file category ────────────────────────────────────────

insert into public.client_file_categories (key, label, restricted_by_default)
values ('Recording', 'Recording', true)
on conflict (key) do update set restricted_by_default = true;

-- ── restricted whatever the form said ────────────────────────

create or replace function public.audio_is_restricted()
returns trigger
language plpgsql
set search_path to 'public'
as $$
begin
  /*
   * A recording of a conversation is restricted, always.
   *
   * The category defaults to restricted and a default can be turned off on a
   * form. This is the rule underneath it: the mime type says what the file
   * is, and an audio file of a meeting with a client is not a document the
   * whole practice reads.
   */
  if coalesce(new.mime_type, '') like 'audio/%' or new.category = 'Recording' then
    new.restricted := true;
  end if;
  return new;
end;
$$;

drop trigger if exists attachments_audio_is_restricted on public.attachments;
create trigger attachments_audio_is_restricted
  before insert or update of mime_type, category, restricted on public.attachments
  for each row execute function public.audio_is_restricted();

-- ── how many hours a person may have read ────────────────────

alter table public.org_settings
  add column if not exists recording_hours_per_person integer not null default 20;

comment on column public.org_settings.recording_hours_per_person is
  'How many hours of recording the practice will pay to transcribe per person '
  'per month. Checked before the audio is sent to Azure, which is when the '
  'money is spent. Twenty, until Admin changes it.';

-- ── the recordings ───────────────────────────────────────────

create table if not exists public.recordings (
  id uuid primary key default gen_random_uuid(),
  attachment_id uuid not null unique references public.attachments(id) on delete cascade,
  client_id uuid not null references public.clients(id) on delete cascade,
  -- Whoever uploaded it, which is whose monthly hours it counts against.
  staff_id uuid references public.staff(id) on delete set null,
  state text not null default 'Waiting',
  -- Minutes of audio, as Azure reports it once the job is done. Null until
  -- then: the practice does not know how long a file is from its size.
  minutes numeric,
  /*
   * The job at Azure, and the reading it came back with.
   *
   * `turns` is the diarized transcript - one row per speaker turn, with the
   * speaker number, the offset and the words. `transcript` is the same thing
   * as plain text, which is what the draft is written from and what a person
   * reads.
   */
  job_url text not null default '',
  turns jsonb,
  transcript text,
  /*
   * The draft summary, in the fixed shape: what it was about, what was
   * agreed, what happens next, and the note for the record. Four fields that
   * are the four things the practice already keeps about a meeting - the
   * contact log's topic, outcome and follow-up, and a note - so confirming
   * one writes records the practice already has rather than a new kind of
   * thing nobody reads.
   */
  summary jsonb,
  -- What a person made of it. Nothing below is on the client's record until
  -- `confirmed_at` is set, and these say what it became when it was.
  confirmed_at timestamptz,
  confirmed_by uuid references public.staff(id) on delete set null,
  contact_log_id uuid references public.contact_log(id) on delete set null,
  note_id uuid references public.notes(id) on delete set null,
  reason text not null default '',
  attempts integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint recordings_state_known check (state in (
    'Waiting',      -- uploaded, not yet sent to Azure
    'Held',         -- over the month's hours; the reason says so
    'Reading',      -- a batch job is running at Azure
    'Read',         -- the transcript is back, no draft yet
    'Drafted',      -- the draft summary is ready for somebody to read
    'Confirmed',    -- a person confirmed it, and it is on the record
    'Not used',     -- a person read it and decided it does not go on the record
    'Failed'        -- Azure could not read it; the reason says what it said
  )),
  constraint recordings_confirmed_says_so
    check (state <> 'Confirmed' or (confirmed_at is not null and confirmed_by is not null)),
  constraint recordings_not_used_says_why
    check (state <> 'Not used' or btrim(reason) <> ''),
  constraint recordings_held_says_why
    check (state <> 'Held' or btrim(reason) <> '')
);

comment on table public.recordings is
  'A recording of a meeting, what Azure made of it, and what a person made of '
  'that. Nothing here is on the client''s record until somebody confirms it.';

create index if not exists recordings_waiting on public.recordings (created_at)
  where state in ('Waiting', 'Reading');
create index if not exists recordings_for_client on public.recordings (client_id, created_at desc);
create index if not exists recordings_by_person on public.recordings (staff_id, created_at desc);

alter table public.recordings enable row level security;

/*
 * Who may read one.
 *
 * The same people who may open the client's restricted documents, because a
 * recording is one. `can_see_restricted` is that rule, and asking it here
 * means the transcript cannot be read by somebody who cannot hear the file it
 * came from.
 */
drop policy if exists recordings_read on public.recordings;
create policy recordings_read on public.recordings
  for select using (public.can_see_restricted(client_id));
select public.apply_system_read_only('public.recordings');

revoke all on public.recordings from public, anon, authenticated;
grant select on public.recordings to authenticated;
grant all on public.recordings to service_role;

commit;
