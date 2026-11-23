/**
 * Calls get a home, and the contacts chip counts contacts.
 * Communications board brief, Part 3 and ruling 5 (owner, 23 November 2026).
 *
 * A phone call has never been recordable in this practice. `contact_log` has
 * a `method` column and not one of its 369 rows says Phone: what is in there
 * is a list of *events* - "End of day report", "Stage change", "Appointment",
 * "Billing submitted" - written by code, because the only screen that ever
 * offered a person the choice is the counselor contact log and nobody has
 * used it. So the practice makes calls all day and the record says nothing
 * about them, which is also why the client dashboard lost its Calls chip.
 *
 * Two halves, and they are different columns on different tables, which is
 * worth saying plainly because they sound like one thing:
 *
 *   notes.method        how a contact happened: in person, phone, video, text.
 *                       The person's own answer, on the note they are writing.
 *   contact_log.method  what the line in the log *is*. Mostly events, and now
 *                       Call, Text and Email as well, so that filing a text or
 *                       a call onto the client's month has something true to
 *                       write in it.
 *
 * The chip is the second half of ruling 5. "11 contacts and calls" on the
 * reports board was counting 200 end-of-day roll-ups and 21 real contacts
 * this month, so the number said something about the practice's paperwork
 * rather than about the client's month. It counts the five methods the owner
 * named and nothing else.
 */

-- ── how this migration meets the live code ───────────────────
--
-- Needs the new code live first: `method`
-- The code that sends it: app/(app)/clients/[id]/actions.ts,
--   app/(app)/quick-add-actions.ts
--
-- The trigger below refuses a hand-written contact note that does not say how
-- the contact happened, and no screen before this commit had a field for it.
-- So it belongs on the far side of the push, and on 23 November 2026 it was
-- not: it went in at 19:20, the push failed its deploy check at 19:45 on a
-- fault in the check itself, and production rolled back to a commit whose
-- note form could not answer the question. For twenty minutes the database
-- held a rule the live code could not satisfy. Nobody wrote a Meeting note in
-- that window, so nobody met it.
--
-- That is the rule in CLAUDE.md now and `check-migrations` asks every
-- migration from this one onwards. The honest record of this one is that it
-- was applied the wrong way round, and the reason it was survivable is luck
-- rather than design.

-- ── how a contact happened ────────────────────────────────────
--
-- Four, the owner's. Not Email: an email to a counselor is already a row in
-- `mail_log` with the message behind it, and a fifth value here would be a
-- second place to look for the same thing.
alter table public.notes add column if not exists method text;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'notes_method_check') then
    alter table public.notes
      add constraint notes_method_check
      check (method is null or method = any (array['In person', 'Phone', 'Video', 'Text']));
  end if;
end $$;

comment on column public.notes.method is
  'How the contact happened: In person, Phone, Video or Text. Required on a hand-written contact note (notes_say_how).';

/**
 * Which notes are a record of talking to somebody.
 *
 * Four of the ten types, and the four are chosen by what a method can honestly
 * be asked about. The six left out are left out for a reason each:
 *
 *   General, Job search, Application submitted - a thing done, not a
 *   conversation. Nobody was spoken to.
 *   Employer contact, Interview - written automatically when a job
 *   application's status changes (log_lead_match), where nobody knows how the
 *   employer got in touch and a guess would be in a signed report by Friday.
 *   Counselor contact - written when a report is emailed out, and an email is
 *   not one of the four methods. The mail log already holds how it went.
 *
 * Immutable and in one place because four things ask it: the trigger below,
 * the note form, the Calls chip, and check-threads.
 */
create or replace function public.note_is_contact(p_type text)
returns boolean language sql immutable as $$
  select coalesce(btrim(p_type), '') = any (array[
    'Phone call',
    'Meeting',
    'Coaching session',
    'No-show / not responding'
  ]);
$$;

/**
 * A contact note says how it happened.
 *
 * Shaped like `notes_need_a_category`, which fills a category in rather than
 * refusing, because the two questions are not the same: the category can be
 * had from the client's stage and the method cannot be had from anywhere. So
 * this derives the one case where the type is itself the answer, excuses the
 * two cases where the row already carries its own record of how it happened,
 * and otherwise refuses in a sentence somebody can act on.
 *
 *   'Phone call' is a phone call. The type says the method, and a form that
 *   asked again would be asking the same question twice.
 *
 *   A note filed from a document (`source_document`) is the document's record
 *   and not a conversation somebody is writing up. USOR 92 and 94 arrive as
 *   Meeting notes and USOR 93 and 95 as Coaching sessions, off the documents
 *   folder, by a cron at twenty past six in the morning - there is nobody to
 *   ask, and the document is the evidence.
 *
 *   A note written before this migration keeps its empty method and stays
 *   editable. What cannot happen is a method being taken off a note that had
 *   one.
 */
create or replace function public.notes_say_how()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if new.method is not null then
    return new;
  end if;

  if btrim(coalesce(new.type, '')) = 'Phone call' then
    new.method := 'Phone';
    return new;
  end if;

  if new.source_document is not null then
    return new;
  end if;

  if not public.note_is_contact(new.type) then
    return new;
  end if;

  if tg_op = 'UPDATE' and old.method is null then
    return new;
  end if;

  raise exception 'Say how this contact happened: in person, phone, video or text.'
    using errcode = 'check_violation';
end $$;

drop trigger if exists notes_say_how on public.notes;
create trigger notes_say_how
  before insert or update of type, method on public.notes
  for each row execute function public.notes_say_how();

-- ── what a line in the contact log is ─────────────────────────
/**
 * Whether a contact-log line is a contact at all.
 *
 * The five the owner named, and the two older spellings of two of them. The
 * spellings are not tidiness: `logSentOnClient` has written "Email sent" for
 * every report emailed out of the CRM since September, and the counselor
 * contact log's form offered "Phone call" long before anything offered
 * "Call". Leaving them out would mean the chip counted a real email as
 * paperwork, which is the fault this function exists to fix, the other way up.
 *
 * Everything else is an event the system wrote about itself - End of day
 * report, Stage change, Reactivated, Closed, Off the board, Billing
 * submitted, Authorization received, Intake form, Report sent - and none of
 * them is somebody talking to a client.
 */
create or replace function public.is_real_contact(p_method text)
returns boolean language sql immutable as $$
  select coalesce(btrim(p_method), '') = any (array[
    'Call', 'Text', 'Email', 'Appointment', 'In person',
    -- the same five, as they were spelled before they were named
    'Phone call', 'Email sent'
  ]);
$$;

/**
 * Which message or call a log line came from.
 *
 * Two nullable columns rather than a table, because the question they answer
 * is small and belongs on the row: is this text already on the client's
 * month. Without it, "Add to report" cannot be pressed twice safely - and the
 * chip the owner is watching would say two where one thing happened - and the
 * thread cannot show which messages have already been collected.
 *
 * Unique across the practice, not per person: two people filing the same text
 * is one contact, unlike `to_file`, where the same email in two inboxes is
 * each person's own to decide about.
 */
alter table public.contact_log add column if not exists source text;
alter table public.contact_log add column if not exists source_key text;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'contact_log_source_check') then
    alter table public.contact_log
      add constraint contact_log_source_check
      check (source is null or source = any (array['Text', 'Call', 'Email']));
  end if;
end $$;

create unique index if not exists contact_log_one_per_thing
  on public.contact_log (source, source_key)
  where source is not null;

comment on column public.contact_log.source is
  'Where this line came from when it was collected off a thread: Text, Call or Email. Null for a line somebody wrote by hand.';

-- ── the recording already knows how it happened ───────────────
--
-- Re-stated from what the database holds, with the method added. Dumped
-- first: a replacement built from the migration that created a function is
-- a replacement built on the wrong thing.
CREATE OR REPLACE FUNCTION public.confirm_recording(p_id uuid, p_kind text, p_on date, p_present text, p_discussed text, p_decisions text, p_next text, p_question text, p_category text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    (client_id, staff_id, staff_name, text, type, method, category, attachment_id, at)
  values
    (v_rec.client_id, v_staff, coalesce(v_name, ''), v_text,
     -- A recorded phone call is a phone call. The note types are what a
     -- person filters by, and one of them is 'Phone call'.
     case when btrim(p_kind) = 'Phone' then 'Phone call' else 'Meeting' end,
     -- And how it happened (0378). The recording knows: the three kinds it
     -- is confirmed as are a phone call, a job site visit and a planning
     -- meeting, and the last two are somebody being in the room. A video
     -- call confirmed as a planning meeting is corrected afterwards, which
     -- is a correction somebody makes rather than a guess nobody can see.
     case when btrim(p_kind) = 'Phone' then 'Phone' else 'In person' end,
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
end $function$
;

-- ── the chip counts contacts (ruling 5) ───────────────────────
CREATE OR REPLACE FUNCTION public.report_board_rows(p_period date DEFAULT NULL::date)
 RETURNS TABLE(row_key text, client_id uuid, client_name text, client_no integer, counselor text, office text, period date, template text, report_id uuid, status text, writer_id uuid, writer text, due_on date, days_left integer, signed_at timestamp with time zone, sent_at timestamp with time zone, sent_to text, owed boolean, services text[], hourly boolean, notes integer, contacts integer, hours numeric, weeks_confirmed integer, weeks_total integer, first_unconfirmed_week date, applications integer, placements integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with asked as (
    select date_trunc('month',
             coalesce(p_period, public.practice_today())::timestamp)::date as period
  ),
  span as (
    select period,
           (period + interval '1 month' - interval '1 day')::date as last_day,
           public.practice_today() as today
      from asked
  ),
  -- Active or On hold, the same caseload the scheduler drafts for. Read
  -- behind is_active_staff() rather than behind a role: every active staff
  -- member may open any report (0377), and the board is how they open one.
  caseload as (
    select c.id, c.name, c.client_no, c.counselor_id, c.referring_office
      from public.clients c
     where public.is_active_staff()
       and c.status in ('Active', 'On hold')
       and c.merged_into is null
  ),
  /*
   * And whoever already has a report in the month, caseload or not.
   *
   * Three of October's nineteen drafts belong to clients who have since been
   * made Inactive. The first version of this joined the caseload at the end
   * and those three disappeared off the board - three drafts in somebody's
   * name, still unsent, that no screen showed. A client who is closed is owed
   * nothing further, so they get no Not-started row; what was already written
   * about them is still the practice's to finish.
   */
  named as (
    select id, name, client_no, counselor_id, referring_office from caseload
    union
    select c.id, c.name, c.client_no, c.counselor_id, c.referring_office
      from public.clients c
      join public.client_reports r on r.client_id = c.id
      cross join span
     where public.is_active_staff()
       and r.period = span.period
       and c.merged_into is null
  ),
  -- The services the client held in the month, by the same open-ended rule
  -- buildPeriodContent uses: a missing date is an end the record does not
  -- have, not a service that had finished.
  live as (
    select a.client_id, a.service_type, a.rate_type, a.id
      from public.authorizations a
      join named cl on cl.id = a.client_id
      cross join span
     where a.status <> 'Closed'
       and (a.start_date is null or a.start_date <= span.last_day)
       and (a.end_date is null or a.end_date >= span.period)
  ),
  served as (
    select l.client_id,
           array_agg(distinct l.service_type) as services,
           bool_or(l.rate_type = 'Hourly') as hourly
      from live l
     group by l.client_id
  ),
  families as (
    select distinct l.client_id, public.service_family(l.service_type) as family
      from live l
     where public.service_family(l.service_type) is not null
  ),
  -- One row per client per report the month could hold. The monthly client
  -- report is owed; a service's own report is offered.
  wanted as (
    select cl.id as client_id, 'Monthly client report'::text as template, true as owed
      from caseload cl
    union all
    select f.client_id, public.report_template_for_family(f.family), false
      from families f
     where public.report_template_for_family(f.family) is not null
  ),
  made as (
    select r.id, r.client_id, r.template, r.status, r.owner_id, r.due_on,
           r.signed_at, r.sent_at, r.sent_to
      from public.client_reports r
      join named cl on cl.id = r.client_id
      cross join span
     where r.period = span.period
  ),
  -- A full join, so a report somebody assembled that the board would not
  -- have offered - a job search report, a month after the client was closed -
  -- is a row rather than a thing that quietly is not there.
  lines as (
    select coalesce(m.client_id, w.client_id) as client_id,
           coalesce(m.template, w.template) as template,
           m.id as report_id,
           coalesce(m.status, 'Not started') as status,
           m.owner_id, m.due_on, m.signed_at, m.sent_at, m.sent_to,
           coalesce(w.owed, false) as owed
      from wanted w
      full join made m
        on m.client_id = w.client_id and m.template = w.template
  ),
  -- What the month holds, per client. The same five things the drafter reads
  -- and no others: a text is in a report once somebody logged it as a
  -- contact, and a recording once it was confirmed, so neither is counted
  -- here as a thing of its own (ruling 5).
  noted as (
    select n.client_id, count(*)::int as n
      from public.notes n
      join named cl on cl.id = n.client_id
      cross join span
     where n.at between span.period and span.last_day
       and coalesce(n.category, '') <> 'Personal'
     group by n.client_id
  ),
  spoke as (
    select g.client_id, count(*)::int as n
      from public.contact_log g
      join named cl on cl.id = g.client_id
      cross join span
     where g.date between span.period and span.last_day
       and coalesce(g.category, '') <> 'Personal'
       -- A contact, and not the practice's paperwork about itself
       -- (ruling 5, 23 November 2026). This chip said 11 for a month that
       -- held 200 end-of-day roll-ups and 21 real contacts.
       and public.is_real_contact(g.method)
     group by g.client_id
  ),
  logged as (
    select l.client_id, round(sum(e.hours), 2) as hours
      from public.service_entries e
      join live l on l.id = e.auth_id
      cross join span
     where e.date between span.period and span.last_day
       and not e.non_billable
     group by l.client_id
  ),
  -- Rei's weeks: the weeks whose Monday falls inside the month, which is how
  -- the board's chip counts them. A month is assembled from the weeks that
  -- overlap it, five times a year one more than this - the chip is about
  -- whose weeks are waiting to be confirmed, not about the month's arithmetic.
  weeks as (
    select w.client_id,
           count(*)::int as all_weeks,
           count(*) filter (where w.status = 'Confirmed')::int as sure,
           min(w.week_start) filter (where w.status <> 'Confirmed') as first_open
      from public.client_weekly_reports w
      join named cl on cl.id = w.client_id
      cross join span
     where w.week_start between span.period and span.last_day
     group by w.client_id
  ),
  applied as (
    select m.client_id, count(*)::int as n
      from public.lead_matches m
      join named cl on cl.id = m.client_id
      cross join span
     where m.applied_on between span.period and span.last_day
     group by m.client_id
  ),
  placed as (
    select p.client_id, count(*)::int as n
      from public.placements p
      join named cl on cl.id = p.client_id
      cross join span
     where p.start_date between span.period and span.last_day
     group by p.client_id
  )
  select ln.client_id::text || '|' || ln.template,
         ln.client_id,
         cl.name,
         cl.client_no,
         co.name,
         nullif(btrim(coalesce(cl.referring_office, '')), ''),
         span.period,
         ln.template,
         ln.report_id,
         ln.status,
         ln.owner_id,
         st.name,
         /*
          * A report nobody has started still has a date it is wanted by, if
          * it is one the practice owes: the 5th of the month after, which is
          * what the scheduler stamps on the row it makes on the 1st. Read
          * from the same function, so the board and the draft cannot differ
          * by a day.
          *
          * The narrower reports are written when a counselor asks, so an
          * unstarted one has no date and is not late. This is the whole use
          * of `owed`: eleven clients hold a coaching authorization and the
          * board would otherwise have opened with eleven reports overdue
          * that nobody had asked for.
          */
         coalesce(ln.due_on,
                  case when ln.owed then public.monthly_report_due_on(span.period) end),
         case
           when coalesce(ln.due_on,
                         case when ln.owed then public.monthly_report_due_on(span.period) end) is null
             then null
           else (coalesce(ln.due_on,
                          public.monthly_report_due_on(span.period)) - span.today)::int
         end,
         ln.signed_at,
         ln.sent_at,
         ln.sent_to,
         ln.owed,
         coalesce(sv.services, '{}'::text[]),
         coalesce(sv.hourly, false),
         coalesce(nt.n, 0),
         coalesce(sp.n, 0),
         coalesce(lg.hours, 0)::numeric,
         coalesce(wk.sure, 0),
         coalesce(wk.all_weeks, 0),
         wk.first_open,
         coalesce(ap.n, 0),
         coalesce(pl.n, 0)
    from lines ln
    cross join span
    join named cl on cl.id = ln.client_id
    left join public.counselors co on co.id = cl.counselor_id
    left join public.staff st on st.id = ln.owner_id
    left join served sv on sv.client_id = ln.client_id
    left join noted nt on nt.client_id = ln.client_id
    left join spoke sp on sp.client_id = ln.client_id
    left join logged lg on lg.client_id = ln.client_id
    left join weeks wk on wk.client_id = ln.client_id
    left join applied ap on ap.client_id = ln.client_id
    left join placed pl on pl.client_id = ln.client_id
   order by cl.name, ln.template;
$function$
;
