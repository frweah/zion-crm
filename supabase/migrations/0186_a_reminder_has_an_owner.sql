-- Zion Vocational Rehab CRM — a reminder always has somebody to own it
--
-- Found by verify_leads.sql the moment Rule 8 (0184) made a hire set a
-- follow-up date by itself: sync_match_reminders resolved the owner as the
-- client's assigned staff member or whoever recorded the match, and when a
-- client had neither it inserted null into calendar_events.staff_id, which is
-- not null. The reminder did not fall back to anybody - the update raised.
--
-- It was unreachable before, because the only way to set a follow-up date was
-- a screen and a screen always knows who is looking. A hire recorded by a rule
-- does not.
--
-- Everything else in this function is 0117 unchanged; it is written out in
-- full rather than patched so what it does can be read here.

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
  -- Who the reminder belongs to. The client's assigned staff member, or
  -- whoever recorded the match - and failing both, whoever the practice says
  -- owns placements (org_settings.placement_staff_id, 0182).
  --
  -- That last fallback is not tidiness. calendar_events.staff_id is not null,
  -- so a reminder with nobody to own it did not fall back to anybody - it
  -- raised and took the whole update with it. Unreachable while the only way
  -- to set a follow-up date was a screen, which always records who was
  -- looking; reachable the moment a hire sets one by itself (Rule 8, 0184),
  -- which is where verify_leads found it.
  select c.name,
         coalesce(c.assigned_staff_id,
                  new.created_by, old.created_by,
                  (select placement_staff_id from public.org_settings limit 1))
    into v_client_name, v_owner
    from public.clients c where c.id = v_client;

  if v_owner is null then
    -- Still nobody. Say so rather than failing on a not-null column three
    -- statements later, where the message would be about calendar_events.
    raise exception 'There is nobody to own the reminders for this job match.'
      using hint = 'Assign the client to somebody, or set who owns placements in the practice settings.',
            errcode = 'check_violation';
  end if;

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
$function$
