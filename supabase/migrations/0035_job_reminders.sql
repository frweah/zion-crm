-- ─────────────────────────────────────────────────────────────
-- 0035 — reminders that follow the date, not the screen.
--
-- An interview date is set from the job panel, from the leads board, and by
-- the status shortcut that fills it in when somebody marks Interview. Put the
-- task-making in any one of those and it is missing from the other two, which
-- is how "the system reminded me last time but not this time" starts.
--
-- So it lives on the row, exactly like the note trigger it sits beside. Set a
-- date anywhere and the reminders appear; move it and they move; clear it and
-- they go.
--
-- What the trigger will not do is talk to Microsoft. It writes the calendar
-- row and marks it Pending, and the app pushes it on the next sync or straight
-- after the action. A database that makes outbound network calls to a third
-- party is a database that hangs when that third party is slow.
-- ─────────────────────────────────────────────────────────────

alter table public.tasks
  add column if not exists source_match_id uuid
    references public.lead_matches(id) on delete set null,
  add column if not exists source_kind text
    check (source_kind in ('Interview prep', 'Interview day', 'Follow-up'));

comment on column public.tasks.source_match_id is
  'The job this reminder came from. Null for a task somebody wrote themselves.';

-- One *open* reminder of each sort per job. The trigger relies on this to move
-- an existing task rather than pile up a second one every time a date is
-- edited.
--
-- Open, not simply one ever: a follow-up that has been done and a new date set
-- afterwards is a second round of chasing and deserves its own reminder. With
-- the index over every row, the finished one blocked the new one and the job
-- went quiet — which is the exact failure this whole item exists to prevent.
drop index if exists tasks_source_idx;
create unique index tasks_source_idx on public.tasks (source_match_id, source_kind)
  where source_match_id is not null and status = 'Open';

-- An interview and a follow-up are appointments in their own right.
alter table public.calendar_events drop constraint if exists calendar_events_kind_check;
alter table public.calendar_events add constraint calendar_events_kind_check
  check (kind in ('Coaching visit', 'Intake appointment', 'Counselor call',
                  'Interview', 'Follow-up', 'Other'));

-- A pushed event whose date has been cleared has to come out of Outlook too,
-- and only the app can do that. The trigger marks it and the app clears it,
-- rather than deleting the row here and leaving the copy behind.
alter table public.calendar_events drop constraint if exists calendar_events_push_state_check;
alter table public.calendar_events add constraint calendar_events_push_state_check
  check (push_state in ('Pending', 'Pushed', 'Failed', 'Not pushed', 'To remove'));

alter table public.calendar_events
  add column if not exists source_match_id uuid
    references public.lead_matches(id) on delete set null,
  add column if not exists source_kind text
    check (source_kind in ('Interview', 'Follow-up'));

drop index if exists calendar_events_source_idx;
create unique index calendar_events_source_idx
  on public.calendar_events (source_match_id, source_kind)
  where source_match_id is not null;

-- ─────────────────────────────────────────────────────────────
-- The reminders themselves
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
    update public.calendar_events
       set push_state = case when outlook_event_id is null then 'Not pushed' else 'To remove' end
     where source_match_id = v_match;
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
    update public.calendar_events
       set push_state = case when outlook_event_id is null then 'Not pushed' else 'To remove' end
     where source_match_id = v_match and source_kind = 'Interview';
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
    update public.calendar_events
       set push_state = case when outlook_event_id is null then 'Not pushed' else 'To remove' end
     where source_match_id = v_match and source_kind = 'Follow-up';
  end if;

  return new;
end;
$$;

drop trigger if exists lead_matches_reminders on public.lead_matches;
create trigger lead_matches_reminders
  after insert or update of interview_on, follow_up_on on public.lead_matches
  for each row execute function public.sync_match_reminders();

drop trigger if exists lead_matches_reminders_delete on public.lead_matches;
create trigger lead_matches_reminders_delete
  before delete on public.lead_matches
  for each row execute function public.sync_match_reminders();

/**
 * Answering the "how did it go?" prompt.
 *
 * Completing an interview or follow-up reminder is the moment somebody knows
 * something new, and the moment they are least likely to go and find the job
 * to record it. So the answer moves the job along from here, in one step, and
 * the note trigger writes it up as it would for any other status change.
 */
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
