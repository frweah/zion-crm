-- Zion Vocational Rehab CRM — the job-search spreadsheet, in the CRM
--
-- Job Search kept a workbook (ZVRC Client Job Applications and Interview
-- Schedules): a tab per client logging every application week by week, and
-- an Interview Schedule tab across all of them. The CRM had the same pipeline
-- - employer, job, a client's application to it, its status and dates - but
-- not everything the workbook recorded, so the workbook stayed in use and
-- the CRM's tracker stayed empty (owner, 21 Sept 2026).
--
-- What the workbook had and the CRM did not, added where it belongs:
--
--   The job      the posting's requisition number, the posting link and the
--                application link.
--   The interview  its time (the date alone put everything at 9 a.m.), how
--                it happens (in person, video, phone), where, whether the
--                client has confirmed they will go, and what happened -
--                done, rescheduled, cancelled, backed out, no-show.
--   The status   Withdrawn: the client stepped away - declined an offer,
--                backed out. "Not selected" is the employer's decision and
--                said the wrong thing about the 3 offers clients declined.
--   The client   the places they will work, and the job-search email the
--                practice set up for them to apply from.
--
-- Deliberately not added: the workbook's SSNs and account passwords. The
-- CRM does not hold either, and an email alias is recorded here without its
-- password.

-- ── the job ────────────────────────────────────────────────
alter table public.job_leads
  add column if not exists requisition text not null default '',
  add column if not exists posting_url text not null default '',
  add column if not exists apply_url   text not null default '';

-- ── the interview ──────────────────────────────────────────
alter table public.lead_matches
  add column if not exists interview_time      time,
  add column if not exists interview_kind      text not null default '',
  add column if not exists interview_location  text not null default '',
  add column if not exists interview_confirmed text not null default '',
  add column if not exists interview_result    text not null default '';

alter table public.lead_matches drop constraint if exists lead_matches_interview_kind_check;
alter table public.lead_matches add constraint lead_matches_interview_kind_check
  check (interview_kind in ('', 'In person', 'Video', 'Phone'));
alter table public.lead_matches drop constraint if exists lead_matches_interview_confirmed_check;
alter table public.lead_matches add constraint lead_matches_interview_confirmed_check
  check (interview_confirmed in ('', 'Confirmed', 'Unconfirmed'));
alter table public.lead_matches drop constraint if exists lead_matches_interview_result_check;
alter table public.lead_matches add constraint lead_matches_interview_result_check
  check (interview_result in ('', 'Done', 'Rescheduled', 'Cancelled', 'Backed out', 'No-show', 'Unscheduled'));

comment on column public.lead_matches.interview_confirmed is
  'Whether the client has said they will go. Empty until somebody asks.';
comment on column public.lead_matches.interview_result is
  'What happened to the interview itself. Whether they got the job is the status.';

-- ── Withdrawn ──────────────────────────────────────────────
alter table public.lead_matches drop constraint if exists lead_matches_status_check;
alter table public.lead_matches add constraint lead_matches_status_check
  check (status in ('Saved', 'Applied', 'Follow-up', 'Interview', 'Offer', 'Hired', 'Not selected', 'Withdrawn'));

create or replace function public.job_status_rank(p_status text)
returns integer language sql immutable as $$
  select case p_status
    when 'Saved'        then 1
    when 'Applied'      then 2
    when 'Follow-up'    then 3
    when 'Interview'    then 4
    when 'Offer'        then 5
    when 'Hired'        then 6
    when 'Not selected' then 7
    when 'Withdrawn'    then 8
    else 9
  end;
$$;

CREATE OR REPLACE FUNCTION public.log_lead_match()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

  select l.title, e.name into v_title, v_employer
    from public.job_leads l
    join public.employers e on e.id = l.employer_id
   where l.id = new.lead_id;

  select name into v_name from public.staff where id = coalesce(new.created_by, v_actor);

  v_text := case new.status
    when 'Saved'        then 'Saved ' || v_title || ' at ' || v_employer || ' to try.'
    when 'Applied'      then 'Applied for ' || v_title || ' at ' || v_employer || '.'
    when 'Follow-up'    then 'Following up on ' || v_title || ' at ' || v_employer || '.'
    when 'Interview'    then 'Interview for ' || v_title || ' at ' || v_employer || '.'
    when 'Offer'        then 'Offer received for ' || v_title || ' at ' || v_employer || '.'
    when 'Hired'        then 'Hired for ' || v_title || ' at ' || v_employer || '.'
    when 'Not selected' then 'Not selected for ' || v_title || ' at ' || v_employer || '.'
    when 'Withdrawn'    then 'Withdrew from ' || v_title || ' at ' || v_employer || '.'
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
$function$;

-- ── the client ─────────────────────────────────────────────
alter table public.clients
  add column if not exists preferred_locations text not null default '',
  add column if not exists job_search_email   text not null default '';

comment on column public.clients.job_search_email is
  'The address the practice set up for this client to apply from. Its password is not kept here.';

-- ── reminders at the interview's own time ─────────────────
CREATE OR REPLACE FUNCTION public.sync_match_reminders()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_client_name text;
  v_employer    text;
  v_title       text;
  v_owner       uuid;
  v_match       uuid := coalesce(new.id, old.id);
  v_client      uuid := coalesce(new.client_id, old.client_id);
begin
  select c.name, coalesce(c.assigned_staff_id, coalesce(new.created_by, old.created_by))
    into v_client_name, v_owner
    from public.clients c where c.id = v_client;

  select l.title, e.name into v_title, v_employer
    from public.job_leads l
    join public.employers e on e.id = l.employer_id
   where l.id = coalesce(new.lead_id, old.lead_id);

  -- ── the job is gone ────────────────────────────────────────
  if tg_op = 'DELETE' then
    -- Open reminders for a job that no longer exists are noise. A finished one
    -- stays: somebody did that preparation, and that is history rather than a
    -- pending obligation.
    delete from public.tasks
     where source_match_id = v_match and status = 'Open';
    delete from public.calendar_events
     where source_match_id = v_match and outlook_event_id is null;
    update public.calendar_events
       set push_state = 'To remove'
     where source_match_id = v_match and outlook_event_id is not null;
    return old;
  end if;

  -- ── the interview ──────────────────────────────────────────
  -- An interview that is not going to happen (0117) asks for nothing.
  if new.interview_on is not null
     and coalesce(new.interview_result, '') not in ('Cancelled', 'Backed out', 'Unscheduled') then
    insert into public.tasks (client_id, assigned_staff_id, title, due, status,
                              system_generated, source_match_id, source_kind, created_by)
    values (v_client, v_owner,
            'Interview prep — ' || v_client_name || ' at ' || v_employer,
            new.interview_on - 1, 'Open', true, v_match, 'Interview prep', v_owner)
    on conflict (source_match_id, source_kind)
      where source_match_id is not null and status = 'Open'
    do update set due = excluded.due, title = excluded.title,
                  assigned_staff_id = excluded.assigned_staff_id
      -- A reminder somebody has already dealt with is not reopened by an edit.
      where public.tasks.status = 'Open';

    insert into public.tasks (client_id, assigned_staff_id, title, due, status,
                              system_generated, source_match_id, source_kind, created_by)
    values (v_client, v_owner,
            'Interview today — ' || v_client_name || ' at ' || v_employer,
            new.interview_on, 'Open', true, v_match, 'Interview day', v_owner)
    on conflict (source_match_id, source_kind)
      where source_match_id is not null and status = 'Open'
    do update set due = excluded.due, title = excluded.title,
                  assigned_staff_id = excluded.assigned_staff_id
      where public.tasks.status = 'Open';

    -- At the interview's own time when it has one (0117), otherwise nine in
    -- the morning, Mountain time, for an hour - said out loud rather than left
    -- to whatever the server's timezone happens to be.
    insert into public.calendar_events (client_id, staff_id, kind, title, starts_at, ends_at,
                                        location, origin, push_state, source_match_id, source_kind,
                                        note, created_by)
    values (v_client, v_owner, 'Interview',
            'Interview — ' || v_client_name || ' at ' || v_employer,
            (new.interview_on + coalesce(new.interview_time, time '09:00')) at time zone 'America/Denver',
            (new.interview_on + coalesce(new.interview_time, time '09:00') + interval '1 hour') at time zone 'America/Denver',
            coalesce(new.interview_location, ''),
            'CRM', 'Pending', v_match, 'Interview',
            concat_ws(' · ', nullif(v_title, ''), nullif(new.interview_kind, '')), v_owner)
    on conflict (source_match_id, source_kind) where source_match_id is not null
    do update set starts_at = excluded.starts_at, ends_at = excluded.ends_at,
                  location = excluded.location, note = excluded.note,
                  title = excluded.title, staff_id = excluded.staff_id,
                  push_state = case when public.calendar_events.outlook_event_id is null
                                    then 'Pending' else 'Pending' end;
  else
    delete from public.tasks
     where source_match_id = v_match and source_kind in ('Interview prep', 'Interview day')
       and status = 'Open';
    delete from public.calendar_events
     where source_match_id = v_match and source_kind = 'Interview'
       and outlook_event_id is null;
    update public.calendar_events
       set push_state = 'To remove'
     where source_match_id = v_match and source_kind = 'Interview'
       and outlook_event_id is not null;
  end if;

  -- ── the follow-up ──────────────────────────────────────────
  if new.follow_up_on is not null then
    insert into public.tasks (client_id, assigned_staff_id, title, due, status,
                              system_generated, source_match_id, source_kind, created_by)
    values (v_client, v_owner,
            'Follow up — ' || v_client_name || ' at ' || v_employer,
            new.follow_up_on, 'Open', true, v_match, 'Follow-up', v_owner)
    on conflict (source_match_id, source_kind)
      where source_match_id is not null and status = 'Open'
    do update set due = excluded.due, title = excluded.title,
                  assigned_staff_id = excluded.assigned_staff_id
      where public.tasks.status = 'Open';

    insert into public.calendar_events (client_id, staff_id, kind, title, starts_at, ends_at,
                                        origin, push_state, source_match_id, source_kind,
                                        note, created_by)
    values (v_client, v_owner, 'Follow-up',
            'Follow up — ' || v_client_name || ' at ' || v_employer,
            (new.follow_up_on + time '09:00') at time zone 'America/Denver',
            (new.follow_up_on + time '09:30') at time zone 'America/Denver',
            'CRM', 'Pending', v_match, 'Follow-up',
            coalesce(v_title, ''), v_owner)
    on conflict (source_match_id, source_kind) where source_match_id is not null
    do update set starts_at = excluded.starts_at, ends_at = excluded.ends_at,
                  title = excluded.title, staff_id = excluded.staff_id,
                  push_state = 'Pending';
  else
    delete from public.tasks
     where source_match_id = v_match and source_kind = 'Follow-up' and status = 'Open';
    delete from public.calendar_events
     where source_match_id = v_match and source_kind = 'Follow-up'
       and outlook_event_id is null;
    update public.calendar_events
       set push_state = 'To remove'
     where source_match_id = v_match and source_kind = 'Follow-up'
       and outlook_event_id is not null;
  end if;

  return new;
end;
$function$;

drop trigger if exists lead_matches_reminders on public.lead_matches;
create trigger lead_matches_reminders
  after insert or update of interview_on, interview_time, interview_location, interview_kind, interview_result, follow_up_on
  on public.lead_matches
  for each row execute function public.sync_match_reminders();

-- ── what the client's job panel reads ─────────────────────
drop view if exists public.client_job_history;
create view public.client_job_history with (security_invoker = true) as
select m.id            as match_id,
       m.client_id,
       m.status,
       public.job_status_rank(m.status) as status_rank,
       m.applied_on,
       m.interview_on,
       m.follow_up_on,
       m.decided_on,
       m.outcome,
       m.notes,
       m.placement_id,
       m.created_at,
       m.updated_at,
       l.id            as lead_id,
       l.title,
       l.wage_range,
       l.location,
       l.status        as lead_status,
       e.id            as employer_id,
       e.name          as employer_name,
       e.contact_name,
       e.contact_phone,
       e.contact_email,
       m.interview_time,
       m.interview_kind,
       m.interview_location,
       m.interview_confirmed,
       m.interview_result,
       l.requisition,
       l.posting_url,
       l.apply_url,
       l.hours_week,
       e.industry
  from public.lead_matches m
  join public.job_leads l on l.id = m.lead_id
  join public.employers e on e.id = l.employer_id;

grant select on public.client_job_history to authenticated;
