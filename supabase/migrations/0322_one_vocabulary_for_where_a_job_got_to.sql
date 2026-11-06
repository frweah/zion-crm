-- Zion Vocational Rehab CRM — one vocabulary for where a job got to
--
-- The owner, 6 Nov 2026: "the job status vocabulary cleanup (unify
-- lead_matches.status into the nine words) now that the leads board was
-- touched."
--
-- 0270 left two vocabularies for one thing and said so out loud: the nine in
-- `job_status_history`, which is where an application's history is kept, and
-- the eight in `lead_matches.status`, which is what the leads board and the
-- views read. `lead_status_for_application` mapped the nine onto the eight in
-- one place, and the comment said the rename was "a separate decision with
-- 281 rows and 30 call sites in it". This is that decision.
--
-- ── what the two vocabularies were costing ───────────────────
--
-- The mapping is lossy in the direction it runs. Of 282 applications on file,
-- 275 have a history, and the history says:
--
--   No response 202 · Declined by employer 49 · Interview scheduled 8
--   Client withdrew 7 · Interviewed 6 · Hired 3
--
-- while the board, reading the eight, says "Applied" for all 202 of the no
-- responses, because 'No response' and 'Applied' both map to 'Applied'. So
-- the board has been showing two hundred applications as live when the
-- practice already recorded that nobody ever wrote back. That is not a
-- cosmetic disagreement: it is the difference between a caseload with two
-- hundred things in play and one with two hundred dead ends to work through,
-- and the screen was showing the first.
--
-- The same loss sits under 'Interview', which is 'Interview scheduled' and
-- 'Interviewed' flattened into one - an interview still to happen and one
-- that already did, told apart nowhere on the board.
--
-- ── so the column takes the nine, and keeps Saved ────────────
--
-- Ten words, not nine: 'Saved' is not an application status and never was.
-- A job somebody put aside to try has not been applied for, has no history
-- row, and gets its first status when it becomes an application. Dropping it
-- would mean inventing an application for seven saved jobs.
--
-- Where a history exists it is the truth, so the column is set from the
-- latest history row rather than from a reverse mapping - a reverse mapping
-- would have to guess which of 'No response' and 'Applied' an 'Applied' row
-- meant, and the history already knows.
--
-- `lead_status_for_application` goes. One vocabulary has nothing to map onto,
-- and a translation left lying about is a translation something starts using
-- again.

begin;

-- ─────────────────────────────────────────────────────────────
-- The triggers stay out of this
--
-- `log_lead_match` writes a note on the client every time the status changes,
-- which is right for a person moving a job along and wrong for a migration:
-- it would put 275 notes on client records today saying things that happened
-- in September. `hired_starts_everything` is the same argument with a
-- placement on the end of it.
--
-- Nothing about these rows is actually changing. The word is.
-- ─────────────────────────────────────────────────────────────
alter table public.lead_matches disable trigger user;

alter table public.lead_matches drop constraint if exists lead_matches_status_check;

-- The latest thing recorded about each application, which is what the column
-- is for: one word, the most recent.
with latest as (
  select distinct on (h.match_id) h.match_id, h.status
    from public.job_status_history h
   order by h.match_id, h.at desc, h.created_at desc
)
update public.lead_matches m
   set status = latest.status
  from latest
 where latest.match_id = m.id
   and m.status <> latest.status;

-- updated_at is left where it was, deliberately. "When did anything happen to
-- this application" is a question somebody asks of the record, and the honest
-- answer is September, not the afternoon the word was changed.

alter table public.lead_matches
  add constraint lead_matches_status_check
  check (status in (
    'Saved',
    'Applied',
    'Employer responded',
    'Interview scheduled',
    'Interviewed',
    'Offer',
    'Hired',
    'Declined by employer',
    'Client withdrew',
    'No response'));

alter table public.lead_matches enable trigger user;

-- ─────────────────────────────────────────────────────────────
-- The order they happen in
--
-- Which is also the order the board sorts by, so it has to cover all ten.
-- 'No response' sits with the endings rather than next to 'Applied': an
-- application nobody answered for a fortnight is over in every way except
-- somebody saying so.
-- ─────────────────────────────────────────────────────────────
create or replace function public.job_status_rank(p_status text)
returns integer language sql immutable as $$
  select case p_status
    when 'Saved'                then 1
    when 'Applied'              then 2
    when 'Employer responded'   then 3
    when 'Interview scheduled'  then 4
    when 'Interviewed'          then 5
    when 'Offer'                then 6
    when 'Hired'                then 7
    when 'Declined by employer' then 8
    when 'Client withdrew'      then 9
    when 'No response'          then 10
    else 11
  end;
$$;

comment on function public.job_status_rank is
  'Where a status sits in the order an application moves through, for sorting '
  'the board. Covers the ten words lead_matches.status holds.';

-- ─────────────────────────────────────────────────────────────
-- Which of the four USOR activity types the note is
--
-- The four are what USOR 96 autofill reads, so this maps ten words onto four
-- and not onto ten. An employer answering, an interview booked and an
-- interview held are all employer contact; a refusal is job search, because
-- what the form is counting is work done rather than how it turned out.
-- ─────────────────────────────────────────────────────────────
create or replace function public.note_type_for_match(p_status text)
returns text language sql immutable as $$
  select case p_status
    when 'Applied'             then 'Application submitted'
    when 'Employer responded'  then 'Employer contact'
    when 'Interview scheduled' then 'Interview'
    when 'Interviewed'         then 'Interview'
    when 'Offer'               then 'Employer contact'
    when 'Hired'               then 'Employer contact'
    else 'Job search'
  end;
$$;

-- ─────────────────────────────────────────────────────────────
-- The sentence that goes on the client's record
-- ─────────────────────────────────────────────────────────────
create or replace function public.log_lead_match()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_title    text;
  v_employer text;
  v_actor    uuid := public.current_staff_id();
  v_name     text;
  v_text     text;
begin
  if tg_op = 'UPDATE' and new.status is not distinct from old.status then
    return new;
  end if;

  /**
   * Silence is not an activity.
   *
   * This is the one consequence of the unification that had to be caught.
   * Under the two vocabularies 'No response' mapped back onto 'Applied', so
   * the fourteen-day sweep changed nothing on the row and wrote nothing. Now
   * it changes the column - which is the point, the board was calling two
   * hundred dead applications live - and that change would fire this trigger
   * on every one of them.
   *
   * Two reasons it must not. A note typed by nobody on two hundred client
   * records is noise; and `note_type_for_match` would file it as 'Job
   * search', which is one of the four activity types USOR 96 autofill counts.
   * Nothing happening would have become job-search activity on a form that
   * goes to the state.
   *
   * The next status after it writes its note in the ordinary way.
   */
  if new.status = 'No response' then
    return new;
  end if;

  select l.title, e.name into v_title, v_employer
    from public.job_leads l
    join public.employers e on e.id = l.employer_id
   where l.id = new.lead_id;

  select name into v_name from public.staff where id = coalesce(new.created_by, v_actor);

  v_text := case new.status
    when 'Saved'                then 'Saved ' || v_title || ' at ' || v_employer || ' to try.'
    when 'Applied'              then 'Applied for ' || v_title || ' at ' || v_employer || '.'
    when 'Employer responded'   then v_employer || ' answered about ' || v_title || '.'
    when 'Interview scheduled'  then 'Interview booked for ' || v_title || ' at ' || v_employer || '.'
    when 'Interviewed'          then 'Interviewed for ' || v_title || ' at ' || v_employer || '.'
    when 'Offer'                then 'Offer received for ' || v_title || ' at ' || v_employer || '.'
    when 'Hired'                then 'Hired for ' || v_title || ' at ' || v_employer || '.'
    when 'Declined by employer' then 'Not selected for ' || v_title || ' at ' || v_employer || '.'
    when 'Client withdrew'      then 'Withdrew from ' || v_title || ' at ' || v_employer || '.'
    -- Never reached: silence returns above without writing anything. The
    -- sentence is here so check-job-status can hold every one of the ten to
    -- having English to say, and so the day somebody decides a fortnight of
    -- nothing does belong on the record, it reads properly.
    when 'No response'          then 'No reply from ' || v_employer || ' about ' || v_title
                                    || ' after a fortnight.'
    else new.status || ' — ' || v_title || ' at ' || v_employer
  end;

  -- The outcome is the sentence somebody wrote about how it went, so it
  -- belongs in the note more than the running commentary does.
  if coalesce(new.outcome, '') <> '' then
    v_text := v_text || E'\n' || new.outcome;
  elsif new.notes <> '' then
    v_text := v_text || E'\n' || new.notes;
  end if;

  insert into public.notes (client_id, staff_id, staff_name, text, type, visible_roles)
  values (
    new.client_id,
    coalesce(new.created_by, v_actor),
    coalesce(v_name, ''),
    v_text,
    public.note_type_for_match(new.status),
    array['Admin', 'Job Search', 'Reports', 'Billing']
  );

  return new;
end;
$$;

-- ─────────────────────────────────────────────────────────────
-- Answering a reminder
--
-- The three endings, not the two. 'No response' is not one of them: it is
-- recorded by the sweep, and an interview still booked when somebody says
-- nobody ever wrote back is a contradiction worth leaving on the screen.
-- ─────────────────────────────────────────────────────────────
create or replace function public.answer_reminder(p_task_id uuid, p_status text, p_outcome text default '')
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_match uuid;
begin
  if public.current_staff_id() is null then
    raise exception 'You are not signed in.' using errcode = 'insufficient_privilege';
  end if;

  select source_match_id into v_match from public.tasks where id = p_task_id;
  if v_match is null then
    raise exception 'That task did not come from a job.' using errcode = 'check_violation';
  end if;

  if p_status is not null and p_status <> '' then
    update public.lead_matches
       set status  = p_status,
           outcome = case when coalesce(p_outcome, '') = '' then outcome else p_outcome end
     where id = v_match;

    -- The end of this job, one way or another. Whatever was still booked for
    -- it is not going to happen, and leaving it booked is how a calendar
    -- stops being believed.
    if p_status in ('Hired', 'Declined by employer', 'Client withdrew') then
      update public.lead_matches
         set interview_on = null, follow_up_on = null
       where id = v_match
         and (interview_on is not null or follow_up_on is not null);
    end if;
  elsif coalesce(p_outcome, '') <> '' then
    update public.lead_matches set outcome = p_outcome where id = v_match;
  end if;

  update public.tasks
     set status = 'Done', done_at = public.practice_today()
   where id = p_task_id;
end;
$$;

-- ─────────────────────────────────────────────────────────────
-- The history lands on the job without translation
-- ─────────────────────────────────────────────────────────────
create or replace function public.application_status_lands_on_the_job()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_word text;
  v_now  text;
begin
  -- The latest thing recorded, which is now the same word the column holds.
  -- It is read from the history rather than taken from `new` because an
  -- entry can be added for a day earlier than the last one, and the column
  -- carries where the application got to, not the last thing typed.
  select h.status into v_word
    from public.job_status_history h
   where h.match_id = new.match_id
   order by h.at desc, h.created_at desc
   limit 1;

  select status into v_now from public.lead_matches where id = new.match_id;

  -- The three dates the board still draws on a timeline. Filled in where they
  -- are blank and left alone where they are not: a date somebody typed is not
  -- ours to move.
  update public.lead_matches m
     set status           = v_word,
         applied_on       = case when m.applied_on is null and new.status = 'Applied'
                                 then new.at else m.applied_on end,
         interview_on     = case when m.interview_on is null
                                   and new.status in ('Interview scheduled', 'Interviewed')
                                 then new.at else m.interview_on end,
         decided_on       = case when m.decided_on is null
                                   and new.status in ('Hired', 'Declined by employer', 'Client withdrew')
                                 then new.at else m.decided_on end,
         interview_result = case when m.interview_result = '' and new.status = 'Interviewed'
                                 then 'Done' else m.interview_result end
   where m.id = new.match_id
     -- Nothing to say is nothing to write. Without this the fourteen-day
     -- sweep would touch rows to set each one to the word it already holds,
     -- and every one of those would write a note.
     and (v_word is distinct from v_now
          or (m.applied_on is null and new.status = 'Applied')
          or (m.interview_on is null and new.status in ('Interview scheduled', 'Interviewed'))
          or (m.decided_on is null and new.status in ('Hired', 'Declined by employer', 'Client withdrew'))
          or (m.interview_result = '' and new.status = 'Interviewed'));

  return new;
end $$;

-- ─────────────────────────────────────────────────────────────
-- And the translation goes
-- ─────────────────────────────────────────────────────────────
drop function if exists public.lead_status_for_application(text);

commit;
