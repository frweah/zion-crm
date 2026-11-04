-- A client who was put forward for a job can still be removed
--
-- `lead_matches.client_id` is `on delete cascade`, and
-- `lead_matches_reminders_delete` is a BEFORE DELETE trigger that fires for
-- each cascaded row. By then the client row is already gone, so this:
--
--     select c.name,
--            coalesce(c.assigned_staff_id, new.created_by, old.created_by,
--                     (select placement_staff_id from public.org_settings limit 1))
--       into v_client_name, v_owner
--       from public.clients c where c.id = v_client;
--
-- returns no row at all. A `select into` that matches nothing leaves its
-- targets null - the fallbacks are inside the select list, so none of them is
-- ever evaluated - and the owner guard below it then refuses the delete.
--
-- The effect: **any client who has ever been put forward for a job could not
-- be removed**, and the sentence they were given was about reminders for a job
-- match rather than about the client they were trying to remove. Not about a
-- follow-up date either: the trigger fires for every cascaded match, whether
-- or not it had a reminder on it.
--
-- The guard is right for an insert or an update - a reminder being created
-- needs somebody to own it, which is what 0186 was for. It has nothing to say
-- about a delete, which takes reminders away and needs no owner to do it. So
-- the guard now applies to the two cases it was written for, the delete branch
-- below runs as it always did, and a reminder already pushed to Outlook is
-- still marked for removal there.
--
-- The same correction as `application_is_gone` (0270) and
-- `authorization_is_gone`: a trigger that keeps a record in step has to let go
-- when the thing it is keeping in step is being deleted. Third time, same
-- shape - worth saying out loud, because the next append-only or sync trigger
-- written on a child table will have it too unless somebody asks.
--
-- The body below is the live definition with that one condition added and
-- nothing else changed.

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

  -- Nobody has to own a reminder that is being taken away. Removing a client
  -- cascades to its job matches, and this trigger then fires for each one with
  -- the client row already deleted: the select above finds nothing, every
  -- fallback is null, and this guard refused the delete with a sentence about
  -- reminders. Somebody removing a client who had ever been put forward for a
  -- job was told "There is nobody to own the reminders for this job match" and
  -- could not remove them.
  --
  -- The delete branch below needs no owner - it only takes reminders away, and
  -- it still runs, so a reminder already pushed to Outlook is still marked for
  -- removal there. The same correction as `application_is_gone` (0270) and
  -- `authorization_is_gone`: a trigger that keeps a record in step has to let
  -- go when the thing it is keeping in step is being deleted.
  if v_owner is null and tg_op <> 'DELETE' then
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

;

-- ─────────────────────────────────────────────────────────────
-- Removing the client works, and the guard still bites where it was meant to
--
-- Both halves matter. Dropping the condition altogether would let a reminder
-- be created with nobody to own it, which is the bug 0186 exists for, so the
-- second block puts that fault back by taking the practice's placement owner
-- away inside a block that rolls itself back.

do $$
declare
  v_rei uuid; v_counsel uuid; v_employer uuid; v_lead uuid;
  v_c uuid; v_m uuid;
begin
  select placement_staff_id into v_rei from public.org_settings limit 1;

  insert into public.counselors (name, email, office)
  values ('ZQ Removal Counselor', 'zq-removal@example.test', 'Salt Lake City')
  returning id into v_counsel;
  insert into public.employers (name) values ('ZZ Removal Employer') returning id into v_employer;
  insert into public.job_leads (employer_id, title) values (v_employer, 'ZZ Removal Opening')
  returning id into v_lead;

  insert into public.clients (name, stage, status, counselor_id, assigned_staff_id)
  values ('ZZ Removable Testperson', 'Job Search', 'Active', v_counsel, v_rei)
  returning id into v_c;
  insert into public.lead_matches (lead_id, client_id, status)
  values (v_lead, v_c, 'Applied') returning id into v_m;
  update public.lead_matches set follow_up_on = public.practice_today() + 7 where id = v_m;

  -- The fault put back: with the guard applying to a delete, this raises
  -- 'There is nobody to own the reminders for this job match' and the client
  -- stays on the books for ever.
  delete from public.clients where id = v_c;
  if exists (select 1 from public.clients where id = v_c) then
    raise exception 'the client was not removed';
  end if;
  if exists (select 1 from public.lead_matches where id = v_m) then
    raise exception 'the job match outlived the client';
  end if;
  raise notice 'ok  a client who was put forward for a job can be removed, and the match goes with them';

  delete from public.job_leads where id = v_lead;
  delete from public.employers where id = v_employer;
  delete from public.counselors where id = v_counsel;
end $$;

do $$
declare
  v_counsel uuid; v_employer uuid; v_lead uuid; v_c uuid; v_m uuid;
begin
  begin
    -- Nobody to fall back to: no assigned staff member, nobody recorded the
    -- match, and the practice has not said who owns placements. This update
    -- rolls back with the block, so the practice setting is as it was either
    -- way.
    update public.org_settings set placement_staff_id = null;

    insert into public.counselors (name, email, office)
    values ('ZQ Ownerless Counselor', 'zq-ownerless@example.test', 'Salt Lake City')
    returning id into v_counsel;
    insert into public.employers (name) values ('ZZ Ownerless Employer') returning id into v_employer;
    insert into public.job_leads (employer_id, title) values (v_employer, 'ZZ Ownerless Opening')
    returning id into v_lead;
    insert into public.clients (name, stage, status, counselor_id)
    values ('ZZ Ownerless Testperson', 'Job Search', 'Active', v_counsel) returning id into v_c;
    insert into public.lead_matches (lead_id, client_id, status, created_by)
    values (v_lead, v_c, 'Applied', null) returning id into v_m;

    update public.lead_matches set follow_up_on = public.practice_today() + 7 where id = v_m;

    -- Not check_violation, so it is not swallowed by the handler below.
    raise exception 'a reminder was created with nobody to own it'
      using errcode = 'raise_exception';
  exception when check_violation then
    raise notice 'ok  and a reminder still cannot be created with nobody to own it';
  end;

  if (select placement_staff_id from public.org_settings limit 1) is null then
    raise exception 'the practice no longer says who owns placements';
  end if;
end $$;
