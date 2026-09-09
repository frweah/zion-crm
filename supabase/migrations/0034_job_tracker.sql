-- ─────────────────────────────────────────────────────────────
-- 0034 — the job tracker, in Margaret's words.
--
-- Renaming, not rebuilding. lead_matches already records a client against a
-- job with dates and a status, and already writes a note whenever the status
-- moves. What was wrong was the vocabulary: "Considering" and "Declined" are
-- not what anybody says out loud, and there was nowhere to put a follow-up —
-- which is the step Margaret does most and the one the system knew nothing
-- about.
--
--   Considering  ->  Saved
--   Declined     ->  Not selected
--   (new)            Follow-up
--
-- The note trigger keeps its job. It fires on the row rather than on the
-- screen, so it holds for the board, for this new panel, and for a correction
-- run months from now.
-- ─────────────────────────────────────────────────────────────

-- Existing rows first, or the new constraint would refuse them.
update public.lead_matches set status = 'Saved'        where status = 'Considering';
update public.lead_matches set status = 'Not selected' where status = 'Declined';

alter table public.lead_matches drop constraint if exists lead_matches_status_check;
alter table public.lead_matches add constraint lead_matches_status_check
  check (status in ('Saved', 'Applied', 'Follow-up', 'Interview', 'Offer', 'Hired', 'Not selected'));

alter table public.lead_matches alter column status set default 'Saved';

alter table public.lead_matches
  add column if not exists follow_up_on date,
  -- What came of it, in the words of whoever was there. Distinct from notes,
  -- which is the running commentary.
  add column if not exists outcome text not null default '';

comment on column public.lead_matches.follow_up_on is
  'When to chase this. Item 3 turns it into a task; on its own it is a date somebody meant to keep.';

-- A job can be at a different site from the employer's address, and "where is
-- it" is the second question every client asks.
alter table public.job_leads
  add column if not exists location text not null default '';

-- ─────────────────────────────────────────────────────────────
-- The order the steps actually happen in, so a list can be sorted by progress
-- rather than alphabetically — which would put Applied after a rejection.
-- ─────────────────────────────────────────────────────────────
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
    else 8
  end;
$$;

grant execute on function public.job_status_rank(text) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- The note the trigger writes, in the new vocabulary
-- ─────────────────────────────────────────────────────────────
create or replace function public.note_type_for_match(p_status text)
returns text language sql immutable as $$
  select case p_status
    when 'Applied'   then 'Application submitted'
    when 'Interview' then 'Interview'
    when 'Offer'     then 'Employer contact'
    when 'Hired'     then 'Employer contact'
    else 'Job search'
  end;
$$;

create or replace function public.log_lead_match()
returns trigger language plpgsql security definer set search_path = public as $$
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
-- client_job_history gains what the panel shows
-- ─────────────────────────────────────────────────────────────
-- Dropped rather than replaced: the column list changes, and a replace can
-- only add columns at the end.
drop view if exists public.client_job_history;
create view public.client_job_history as
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
       e.contact_email
  from public.lead_matches m
  join public.job_leads l on l.id = m.lead_id
  join public.employers e on e.id = l.employer_id;

alter view public.client_job_history set (security_invoker = true);
grant select on public.client_job_history to authenticated;

-- ─────────────────────────────────────────────────────────────
-- The timeline learns about follow-ups
-- ─────────────────────────────────────────────────────────────
create or replace view public.client_activity as
select * from (
  select n.client_id, coalesce(n.at, n.created_at) as at, 'Note'::text as kind,
         n.type as title, n.text as detail, n.staff_name as who,
         'notes'::text as tab, n.id as ref_id
    from public.notes n
  union all
  select h.client_id, coalesce(h.at, h.created_at), 'Stage',
         'Moved to ' || h.stage, '', s.name, 'overview', h.id
    from public.client_stage_history h
    left join public.staff s on s.id = h.staff_id
  union all
  select m.client_id, m.applied_on::timestamptz, 'Job',
         'Applied — ' || coalesce(e.name, l.title, 'a job'), coalesce(l.title, ''),
         s.name, 'overview', m.id
    from public.lead_matches m
    join public.job_leads l on l.id = m.lead_id
    left join public.employers e on e.id = l.employer_id
    left join public.staff s on s.id = m.created_by
   where m.applied_on is not null
  union all
  select m.client_id, m.interview_on::timestamptz, 'Interview',
         'Interview — ' || coalesce(e.name, l.title, 'a job'), coalesce(l.title, ''),
         s.name, 'overview', m.id
    from public.lead_matches m
    join public.job_leads l on l.id = m.lead_id
    left join public.employers e on e.id = l.employer_id
    left join public.staff s on s.id = m.created_by
   where m.interview_on is not null
  union all
  select m.client_id, m.follow_up_on::timestamptz, 'Follow-up',
         'Follow up — ' || coalesce(e.name, l.title, 'a job'), coalesce(l.title, ''),
         s.name, 'overview', m.id
    from public.lead_matches m
    join public.job_leads l on l.id = m.lead_id
    left join public.employers e on e.id = l.employer_id
    left join public.staff s on s.id = m.created_by
   where m.follow_up_on is not null
  union all
  select m.client_id, m.decided_on::timestamptz, 'Job',
         m.status || ' — ' || coalesce(e.name, l.title, 'a job'),
         coalesce(nullif(m.outcome, ''), m.notes, ''), s.name, 'overview', m.id
    from public.lead_matches m
    join public.job_leads l on l.id = m.lead_id
    left join public.employers e on e.id = l.employer_id
    left join public.staff s on s.id = m.created_by
   where m.decided_on is not null
  union all
  select t.client_id, t.done_at, 'Task', 'Done — ' || t.title, '', s.name, 'tasks', t.id
    from public.tasks t
    left join public.staff s on s.id = t.assigned_staff_id
   where t.status = 'Done' and t.done_at is not null
  union all
  select f.client_id, f.completed_at, 'Form',
         'Completed — ' || coalesce(ft.name, 'form'), '', f.completed_by_name, 'forms', f.id
    from public.forms f
    left join public.form_templates ft on ft.id = f.template_id
   where f.completed_at is not null
  union all
  select f.client_id, f.sent_at, 'Form',
         'Sent — ' || coalesce(ft.name, 'form'), coalesce(f.sent_to, ''),
         f.completed_by_name, 'forms', f.id
    from public.forms f
    left join public.form_templates ft on ft.id = f.template_id
   where f.sent_at is not null
  union all
  select cl.client_id, cl.date::timestamptz, 'Counselor',
         cl.method || coalesce(' — ' || nullif(cl.topic, ''), ''), coalesce(cl.outcome, ''),
         s.name, 'counselors', cl.id
    from public.contact_log cl
    left join public.staff s on s.id = cl.staff_id
   where cl.client_id is not null
  union all
  select p.client_id, p.start_date::timestamptz, 'Placement',
         'Started — ' || coalesce(nullif(p.employer, ''), 'a placement'),
         coalesce(p.title, ''), null, 'placements', p.id
    from public.placements p
   where p.start_date is not null
  union all
  select p.client_id, c.at::timestamptz, 'Retention',
         c.label || ' check — ' || coalesce(nullif(p.employer, ''), 'placement'),
         '', null, 'placements', p.id
    from public.placements p
   cross join lateral (
     values (p.check30, '30 day'), (p.check60, '60 day'), (p.check90, '90 day')
   ) as c(at, label)
   where c.at is not null
  union all
  select a.client_id, se.date::timestamptz, 'Hours',
         public.fmt_hours(se.hours) || ' logged'
           || case when se.non_billable then ' (non-billable)' else '' end,
         coalesce(se.notes, ''), s.name, 'authorizations', se.id
    from public.service_entries se
    join public.authorizations a on a.id = se.auth_id
    left join public.staff s on s.id = se.staff_id
  union all
  select ce.client_id, ce.starts_at, 'Appointment',
         ce.kind || ' — ' || ce.title, coalesce(ce.location, ''), s.name, 'calendar', ce.id
    from public.calendar_events ce
    left join public.staff s on s.id = ce.staff_id
   where ce.client_id is not null
  union all
  select ml.client_id, ml.sent_at, 'Mail',
         case ml.direction when 'Incoming' then 'From ' else 'To ' end || ml.counterpart_email,
         ml.subject, null, 'calendar', ml.id
    from public.mail_log ml
   where ml.client_id is not null
) feed;

alter view public.client_activity set (security_invoker = true);
grant select on public.client_activity to authenticated;
