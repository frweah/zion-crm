-- Zion Vocational Rehab CRM — the shape a meeting note takes
--
-- The owner's 29 October shape, given on 14 November. Item F was built on my
-- reading of it - four fields - and this is the real one:
--
--   the date and type of contact (job site visit, planning meeting, phone),
--   who was present, what was discussed, decisions, next steps with dates
--   where they were said, and one follow-up question.
--
-- With three rules over it:
--
--   **Minimum necessary.** No health, legal, benefits or family detail in a
--   machine draft, unless the staff member puts it there themselves.
--
--   **About 120 words.** A note somebody reads before a meeting, not a
--   transcript with the gaps taken out.
--
--   **Never guess a date.** Next steps carry a date when one was said, in
--   words. The contact log's follow-up column stays empty: it is a date
--   somebody is chased on, and a machine reading of "Thursday" is not it.
--
-- ── where each rule is kept ──────────────────────────────────
--
-- The prompt asks for all three. This is the door that holds them, because a
-- prompt is a request and a model is a thing that sometimes does not listen.
-- `recording_drafted` reads the draft before it records it, and a draft that
-- carries what it should not, or runs past the cap, is **not kept at all**:
-- the recording stays Read, with the reason on it, and the person writes the
-- six parts themselves. Nothing is retried, so nothing is paid for twice, and
-- the words the recording was read into are untouched either way.
--
-- The guard is deliberately **precise rather than broad**. It is the second
-- line, and a word list wide enough to catch everything would refuse drafts
-- about ordinary work: this practice places people in hospitals, clinics and
-- care homes, "disability" is its subject, "vocational rehab" is its name,
-- "warrant" is how it gets paid, and "benefits" is a thing an employer
-- offers. None of those are in the list. What is in it is detail that can
-- only be about somebody's own life.
--
-- ── and the transcript stays where it was read ───────────────
--
-- Confirming writes a note made of the six parts and a contact log entry made
-- of two of them. It does not copy the transcript into either, and nothing
-- else in the practice reads that column: not a report, not an export, not a
-- message to a counselor. `verify_recordings` asserts both ends of that -
-- that the words do not reach the record, and that what does reach it is what
-- the person confirmed.

begin;

-- ── what a machine draft may not carry ───────────────────────

create or replace function public.machine_draft_problem(p_text text)
returns text
language sql
immutable
set search_path to 'public'
as $$
  /*
   * The first thing in a machine draft that is nobody's business but the
   * person it is about, or '' when there is nothing.
   *
   * Four kinds, and the reason each is here: a client's health, their
   * dealings with courts and the law, the money the state pays them, and
   * their family. A note about a job search needs none of them to be useful,
   * and a machine that has read an hour of conversation will produce them
   * freely if nothing stops it.
   *
   * A staff member may write any of it, and this is never asked of what they
   * write. The judgement about what belongs on somebody's record is theirs;
   * what this refuses is a machine making that judgement on their behalf.
   */
  select coalesce(
    (select format('%s detail (%s)', w.kind,
              lower(substring(p_text from '\m(' || w.word || ')\M')))
       from (values
         -- health: their own, not a place of work
         ('health', 'diagnos\w*'), ('health', 'medication'), ('health', 'medications'),
         ('health', 'prescription'), ('health', 'prescribed'), ('health', 'psychiatr\w*'),
         ('health', 'psychologist'), ('health', 'depression'), ('health', 'depressive'),
         ('health', 'anxiety'), ('health', 'bipolar'), ('health', 'schizophreni\w*'),
         ('health', 'seizures?'), ('health', 'epilep\w*'), ('health', 'autis\w*'),
         ('health', 'ADHD'), ('health', 'PTSD'), ('health', 'relapse'),
         ('health', 'sobriety'), ('health', 'detox'), ('health', 'overdose'),
         ('health', 'suicid\w*'), ('health', 'self-harm'), ('health', 'chronic pain'),
         ('health', 'symptoms'), ('health', 'hospitali[sz]ed'), ('health', 'surgery'),
         ('health', 'chemotherapy'), ('health', 'insulin'), ('health', 'diabet\w*'),
         ('health', 'blood pressure'), ('health', 'mental health'),
         ('health', 'therapy session'), ('health', 'therapist'),
         ('health', 'treatment plan'), ('health', 'medical appointment'),
         ('health', 'medical condition'), ('health', 'medical records?'),
         -- legal
         ('legal', 'attorney'), ('legal', 'lawyer'), ('legal', 'courts?'),
         ('legal', 'lawsuit'), ('legal', 'subpoena'), ('legal', 'probation'),
         ('legal', 'parole'), ('legal', 'arrested'), ('legal', 'convict\w*'),
         ('legal', 'felony'), ('legal', 'misdemean\w*'), ('legal', 'restraining order'),
         ('legal', 'guardianship'), ('legal', 'criminal charges'), ('legal', 'jail'),
         ('legal', 'prison'), ('legal', 'incarcerat\w*'), ('legal', 'deportation'),
         ('legal', 'immigration status'),
         -- benefits the state pays, never an employer's
         ('benefits', 'SSI'), ('benefits', 'SSDI'), ('benefits', 'social security'),
         ('benefits', 'medicaid'), ('benefits', 'medicare'), ('benefits', 'food stamps'),
         ('benefits', 'SNAP benefits'), ('benefits', 'housing voucher'),
         ('benefits', 'section 8'), ('benefits', 'TANF'), ('benefits', 'disability benefits'),
         ('benefits', 'disability check'), ('benefits', 'welfare'),
         ('benefits', 'unemployment benefits'), ('benefits', 'cash assistance'),
         -- family
         ('family', 'mother'), ('family', 'father'), ('family', 'mom'), ('family', 'mum'),
         ('family', 'dad'), ('family', 'parents'), ('family', 'stepmother'),
         ('family', 'stepfather'), ('family', 'husband'), ('family', 'wife'),
         ('family', 'spouse'), ('family', 'fianc\w*'), ('family', 'boyfriend'),
         ('family', 'girlfriend'), ('family', 'son'), ('family', 'daughter'),
         ('family', 'children'), ('family', 'kids'), ('family', 'brother'),
         ('family', 'sister'), ('family', 'sibling'), ('family', 'grandmother'),
         ('family', 'grandfather'), ('family', 'grandparents'), ('family', 'aunt'),
         ('family', 'uncle'), ('family', 'cousin'), ('family', 'nephew'),
         ('family', 'niece'), ('family', 'divorce\w*'), ('family', 'custody'),
         ('family', 'pregnan\w*'), ('family', 'foster care')
       ) as w(kind, word)
      where coalesce(p_text, '') ~* ('\m(' || w.word || ')\M')
      order by w.kind, w.word
      limit 1),
    '');
$$;

revoke all on function public.machine_draft_problem(text) from public, anon, authenticated;
grant execute on function public.machine_draft_problem(text) to service_role;

-- ── the six parts, as words ──────────────────────────────────

create or replace function public.draft_text(p_summary jsonb)
returns text
language sql
immutable
set search_path to 'public'
as $$
  /*
   * The whole draft as one piece of prose, which is what both rules are
   * about: the cap is on the note a person reads, not on any one line of it,
   * and a piece of detail is no better for being in the follow-up question
   * than in what was discussed.
   */
  select btrim(concat_ws(' ',
    nullif(btrim(coalesce(p_summary ->> 'present', '')), ''),
    nullif(btrim(coalesce(p_summary ->> 'discussed', '')), ''),
    nullif(btrim(coalesce(p_summary ->> 'decisions', '')), ''),
    nullif(btrim(coalesce(p_summary ->> 'next', '')), ''),
    nullif(btrim(coalesce(p_summary ->> 'question', '')), '')));
$$;

revoke all on function public.draft_text(jsonb) from public, anon, authenticated;
grant execute on function public.draft_text(jsonb) to service_role;

-- ── the cap, as a number in one place ────────────────────────

alter table public.org_settings
  add column if not exists recording_draft_words integer not null default 120;

alter table public.org_settings
  drop constraint if exists org_settings_recording_draft_words_check;
alter table public.org_settings
  add constraint org_settings_recording_draft_words_check
  check (recording_draft_words between 40 and 400);

grant select (recording_draft_words) on public.org_settings to authenticated;

-- ── the door the draft comes through ─────────────────────────

drop function if exists public.recording_drafted(uuid, jsonb);

create function public.recording_drafted(p_id uuid, p_summary jsonb)
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_problem text;
  v_words   integer;
  v_cap     integer;
  v_state   text;
begin
  -- The reader records a draft, and nobody else. This runs as its owner and
  -- writes to a client's record, so a signed-in person being able to call it
  -- would be a way to put words on a record without confirming them (0345,
  -- and verify_portal_rls asks it of every elevated function).
  if coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'Only the reader records a draft.' using errcode = 'insufficient_privilege';
  end if;

  /*
   * Records a machine draft against a recording that has been read, or says
   * why it was not kept.
   *
   * Returns '' when the draft is now on the recording and a sentence when it
   * is not. It does not raise, because a refused draft is not an error: the
   * recording was read, the words are safe, and the person writes the six
   * parts themselves from what was said. Raising would make the caller treat
   * a working refusal as a failure and count it against the three attempts
   * that stop the asking.
   */
  select state into v_state from public.recordings where id = p_id for update;
  if not found then
    raise exception 'That recording is not on file.' using errcode = 'no_data_found';
  end if;
  if v_state <> 'Read' then
    raise exception 'That recording is %, so there is nothing to draft from.', lower(v_state)
      using errcode = 'check_violation';
  end if;

  v_problem := public.machine_draft_problem(public.draft_text(p_summary));
  if v_problem <> '' then
    update public.recordings
       set reason = format(
             'The draft was not kept: it carried %s. Write the note from what was said.', v_problem),
           updated_at = now()
     where id = p_id;
    return format('it carried %s', v_problem);
  end if;

  select recording_draft_words into v_cap from public.org_settings limit 1;
  v_cap := coalesce(v_cap, 120);
  v_words := coalesce(array_length(
    regexp_split_to_array(btrim(public.draft_text(p_summary)), '\s+'), 1), 0);
  if v_words > v_cap then
    update public.recordings
       set reason = format(
             'The draft was not kept: it ran to %s words against a cap of %s. Write the note from what was said.',
             v_words, v_cap),
           updated_at = now()
     where id = p_id;
    return format('it ran to %s words against a cap of %s', v_words, v_cap);
  end if;

  update public.recordings
     set state = 'Drafted', summary = p_summary, reason = '', updated_at = now()
   where id = p_id;
  return '';
end $$;

revoke all on function public.recording_drafted(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.recording_drafted(uuid, jsonb) to service_role;

-- ── confirming, in the shape ─────────────────────────────────
--
-- A new signature is a new function, so the old one goes rather than sitting
-- beside this one with nobody calling it (0309).

drop function if exists public.confirm_recording(uuid, text, text, text, text, text);

create or replace function public.confirm_recording(
  p_id uuid,
  p_kind text,
  p_on date,
  p_present text,
  p_discussed text,
  p_decisions text,
  p_next text,
  p_question text,
  p_category text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_rec   public.recordings%rowtype;
  v_staff uuid := public.current_staff_id();
  v_name  text;
  v_log   uuid;
  v_note  uuid;
  v_text  text;
  v_on    date;
begin
  if v_staff is null then
    raise exception 'You are not signed in.' using errcode = 'insufficient_privilege';
  end if;

  select * into v_rec from public.recordings where id = p_id for update;
  if not found then
    raise exception 'That recording is not on file.' using errcode = 'no_data_found';
  end if;

  /*
   * Only somebody who could have heard it.
   *
   * A recording is a restricted document, so the people who may confirm what
   * it said are the people who may open it. Anybody else would be confirming
   * a machine reading of a conversation they are not allowed to listen to.
   */
  if not public.can_see_restricted(v_rec.client_id) then
    raise exception 'This recording is restricted to the people who may open this client''s restricted documents.'
      using errcode = 'insufficient_privilege';
  end if;

  if v_rec.state not in ('Read', 'Drafted') then
    raise exception 'That recording is %, so there is nothing to confirm.', lower(v_rec.state)
      using errcode = 'check_violation';
  end if;

  if coalesce(btrim(p_kind), '') not in ('Job site visit', 'Planning meeting', 'Phone') then
    raise exception 'Choose the type of contact: job site visit, planning meeting or phone.'
      using errcode = 'check_violation';
  end if;
  if coalesce(btrim(p_present), '') = '' then
    raise exception 'Say who was present — it is what makes this a record of a meeting.'
      using errcode = 'check_violation';
  end if;
  if coalesce(btrim(p_discussed), '') = '' then
    raise exception 'Say what was discussed — it is the line the contact log shows.'
      using errcode = 'check_violation';
  end if;

  v_on := coalesce(
    p_on,
    (select a.document_date from public.attachments a where a.id = v_rec.attachment_id),
    public.practice_today());

  select name into v_name from public.staff where id = v_staff;

  /*
   * The note, in the shape: the day and what kind of contact it was, who was
   * there, what was said, what was decided, what happens next, and the one
   * thing to ask next time.
   *
   * Assembled here rather than in the browser so that a note written from a
   * recording reads the same whoever confirmed it and whatever screen they
   * were on. Nothing of the transcript is copied in: every line is something
   * a person read and agreed to.
   */
  v_text := concat_ws(chr(10),
    format('%s, %s.', btrim(p_kind), to_char(v_on, 'FMDD Mon YYYY')),
    'Present: ' || btrim(p_present),
    'Discussed: ' || btrim(p_discussed),
    case when coalesce(btrim(p_decisions), '') <> '' then 'Decisions: ' || btrim(p_decisions) end,
    case when coalesce(btrim(p_next), '') <> '' then 'Next steps: ' || btrim(p_next) end,
    case when coalesce(btrim(p_question), '') <> '' then 'Follow-up question: ' || btrim(p_question) end);

  /*
   * The contact log: what it was about, and what came of it.
   *
   * `follow_up` is a **date** on this table - the day somebody is to be
   * chased - and the next steps are words, which may name a day somebody
   * said. So the words go with the outcome and the follow-up date is left to
   * whoever sets one. Never guess a date.
   */
  insert into public.contact_log
    (client_id, date, method, topic, outcome, staff_id, category)
  values
    (v_rec.client_id, v_on, btrim(p_kind), btrim(p_discussed),
     btrim(concat_ws(' ',
       nullif(btrim(coalesce(p_decisions, '')), ''),
       case when coalesce(btrim(p_next), '') <> ''
            then 'Next: ' || btrim(p_next) end)),
     v_staff,
     nullif(btrim(coalesce(p_category, '')), ''))
  returning id into v_log;

  -- Attached to the recording, so anybody reading the note can see what it
  -- came from and go and listen to it.
  insert into public.notes
    (client_id, staff_id, staff_name, text, type, category, attachment_id, at)
  values
    (v_rec.client_id, v_staff, coalesce(v_name, ''), v_text, 'Meeting',
     nullif(btrim(coalesce(p_category, '')), ''), v_rec.attachment_id, v_on)
  returning id into v_note;

  update public.recordings
     set state = 'Confirmed',
         summary = jsonb_build_object(
           'kind', btrim(p_kind),
           'on', to_char(v_on, 'YYYY-MM-DD'),
           'present', btrim(p_present),
           'discussed', btrim(p_discussed),
           'decisions', btrim(coalesce(p_decisions, '')),
           'next', btrim(coalesce(p_next, '')),
           'question', btrim(coalesce(p_question, ''))),
         confirmed_at = now(), confirmed_by = v_staff,
         contact_log_id = v_log, note_id = v_note,
         reason = '', updated_at = now()
   where id = p_id;

  return jsonb_build_object('contact_log', v_log, 'note', v_note);
end $$;

revoke all on function public.confirm_recording(uuid, text, date, text, text, text, text, text, text)
  from public, anon, authenticated;
grant execute on function public.confirm_recording(uuid, text, date, text, text, text, text, text, text)
  to authenticated;

-- ── a draft in the old shape is not a draft ──────────────────
--
-- One recording was drafted in the four-field shape, on the fixture client,
-- during the test that found all this. A screen that met it would show six
-- empty boxes and no sign of why, so it goes back to Read with the reason: a
-- person can still confirm it by writing the six parts from the transcript,
-- which is what Read has always meant.

update public.recordings
   set state = 'Read',
       summary = null,
       reason = 'The draft was in the old shape. Write the note from what was said.',
       updated_at = now()
 where state = 'Drafted'
   and summary is not null
   and not (summary ? 'discussed');

commit;
