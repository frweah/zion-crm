-- ─────────────────────────────────────────────────────────────
-- 0043 — a job that is over stops asking for things
--
-- Found by the caseload view, which is the first screen to ask "what is next"
-- out loud. Answering an interview reminder with "Not selected" moved the job
-- along but left its dates alone, so the follow-up task and the follow-up
-- appointment stayed on the books — and, once the calendar events sync, on
-- somebody's Outlook. A job coach would have kept a 9am slot to follow up on
-- a job that was decided a week earlier.
--
-- Two changes, and the second is the one that matters.
-- ─────────────────────────────────────────────────────────────

-- ─────────────────────────────────────────────────────────────
-- Deciding a job clears its dates
--
-- Clearing the dates is already the cleanup path: the reminder trigger's else
-- branch deletes the open tasks and marks the calendar events to remove. This
-- just walks through it rather than inventing a second way to tidy up.
-- ─────────────────────────────────────────────────────────────
create or replace function public.answer_reminder(
  p_task_id uuid,
  p_status  text,
  p_outcome text default ''
)
returns void
language plpgsql security definer set search_path = public as $$
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

    -- Hired or Not selected is the end of this job. Whatever was still booked
    -- for it is not going to happen, and leaving it booked is how a calendar
    -- stops being believed.
    if p_status in ('Hired', 'Not selected') then
      update public.lead_matches
         set interview_on = null, follow_up_on = null
       where id = v_match
         and (interview_on is not null or follow_up_on is not null);
    end if;
  elsif coalesce(p_outcome, '') <> '' then
    update public.lead_matches set outcome = p_outcome where id = v_match;
  end if;

  update public.tasks
     set status = 'Done', done_at = current_date
   where id = p_task_id;
end;
$$;

revoke execute on function public.answer_reminder(uuid, text, text) from public;
grant execute on function public.answer_reminder(uuid, text, text) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- Withdrawing a reminder removes it, rather than declining to push it
--
-- The cancel path set push_state to 'Not pushed' when the event had never
-- reached Outlook — which reads as "we did not send this" and left the
-- appointment sitting in the CRM calendar for a date that no longer exists.
-- Only the pushed case was really being withdrawn. Now a reminder that was
-- never pushed is deleted outright, which is what the sweeper already does
-- to the pushed ones once Outlook has let go of them, and for the reason it
-- gives: a reminder whose date was cleared is not a record of anything.
--
-- Otherwise unchanged from 0035.
-- ─────────────────────────────────────────────────────────────
create or replace function public.sync_match_reminders()
returns trigger language plpgsql security definer set search_path = public as $$
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
  if new.interview_on is not null then
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

    -- Nine in the morning, Mountain time, for an hour. The date carries no
    -- time of day, so one is chosen and said out loud rather than left to
    -- whatever the server's timezone happens to be.
    insert into public.calendar_events (client_id, staff_id, kind, title, starts_at, ends_at,
                                        origin, push_state, source_match_id, source_kind,
                                        note, created_by)
    values (v_client, v_owner, 'Interview',
            'Interview — ' || v_client_name || ' at ' || v_employer,
            (new.interview_on + time '09:00') at time zone 'America/Denver',
            (new.interview_on + time '10:00') at time zone 'America/Denver',
            'CRM', 'Pending', v_match, 'Interview',
            coalesce(v_title, ''), v_owner)
    on conflict (source_match_id, source_kind) where source_match_id is not null
    do update set starts_at = excluded.starts_at, ends_at = excluded.ends_at,
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
$$;


-- ─────────────────────────────────────────────────────────────
-- client_next_up says what is booked, not what ought to be
--
-- The first version skipped follow-ups on decided jobs, which read as a
-- safeguard and was not one: the same date also lives in a task and a calendar
-- event, neither of which knew about the status, so the filter hid one of
-- three copies and the screen showed the other two. What is next is now
-- simply what is on the books — and 0043's first half is what keeps a
-- finished job off them.
-- ─────────────────────────────────────────────────────────────
create or replace view public.client_next_up as
select distinct on (x.client_id)
       x.client_id,
       x.at,
       x.kind,
       x.title
  from (
    select e.client_id, e.starts_at as at, e.kind, e.title
      from public.calendar_events e
     where e.client_id is not null
       and e.starts_at >= now()
       and coalesce(e.push_state, '') <> 'To remove'

    union all

    select t.client_id, t.due::timestamptz, 'Task', t.title
      from public.tasks t
     where t.client_id is not null
       and t.status = 'Open'
       and t.due >= public.practice_today()

    union all

    select m.client_id, m.interview_on::timestamptz, 'Interview',
           'Interview — ' || coalesce(e.name, l.title, 'a job')
      from public.lead_matches m
      join public.job_leads l on l.id = m.lead_id
      left join public.employers e on e.id = l.employer_id
     where m.interview_on >= public.practice_today()

    union all

    select m.client_id, m.follow_up_on::timestamptz, 'Follow-up',
           'Follow up — ' || coalesce(e.name, l.title, 'a job')
      from public.lead_matches m
      join public.job_leads l on l.id = m.lead_id
      left join public.employers e on e.id = l.employer_id
     where m.follow_up_on >= public.practice_today()
  ) x
 order by x.client_id, x.at;

alter view public.client_next_up set (security_invoker = true);
grant select on public.client_next_up to authenticated;

comment on view public.client_next_up is
  'The soonest thing on the books for each client — appointment, task, interview or job follow-up. Nothing in the past, and nothing already withdrawn from a calendar.';
