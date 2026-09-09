-- ─────────────────────────────────────────────────────────────
-- 0033 — the client activity timeline.
--
-- One reverse-chronological feed of everything that has happened to a client,
-- assembled from the tables that already record it. A view and nothing else:
-- there is no new table, no trigger writing a second copy of events, and
-- nothing here to fall out of step with what it describes. If a note is
-- edited, the timeline shows the edit, because the timeline *is* the note.
--
-- security_invoker, which is the whole safety story. Every branch below reads
-- its source table as the person asking, so the rules already written continue
-- to apply — a note restricted to Admin and Job Search stays restricted here,
-- rather than leaking through a feed that forgot to ask.
--
-- Dates that are stored as dates arrive as midnight. Two things on the same
-- day therefore sort by kind rather than by hour, which is the honest
-- presentation: the underlying record does not know what time it happened.
-- ─────────────────────────────────────────────────────────────

create or replace view public.client_activity as

-- Notes as typed
select n.client_id,
       coalesce(n.at, n.created_at)                as at,
       'Note'::text                                as kind,
       n.type                                      as title,
       n.text                                      as detail,
       n.staff_name                                as who,
       'notes'::text                               as tab,
       n.id                                        as ref_id
  from public.notes n

union all

-- Stage changes
select h.client_id,
       coalesce(h.at, h.created_at),
       'Stage',
       'Moved to ' || h.stage,
       '',
       s.name,
       'overview',
       h.id
  from public.client_stage_history h
  left join public.staff s on s.id = h.staff_id

union all

-- A job applied for
select m.client_id,
       m.applied_on::timestamptz,
       'Job',
       'Applied — ' || coalesce(e.name, l.title, 'a job'),
       coalesce(l.title, ''),
       s.name,
       'overview',
       m.id
  from public.lead_matches m
  join public.job_leads l on l.id = m.lead_id
  left join public.employers e on e.id = l.employer_id
  left join public.staff s on s.id = m.created_by
 where m.applied_on is not null

union all

-- An interview
select m.client_id,
       m.interview_on::timestamptz,
       'Interview',
       'Interview — ' || coalesce(e.name, l.title, 'a job'),
       coalesce(l.title, ''),
       s.name,
       'overview',
       m.id
  from public.lead_matches m
  join public.job_leads l on l.id = m.lead_id
  left join public.employers e on e.id = l.employer_id
  left join public.staff s on s.id = m.created_by
 where m.interview_on is not null

union all

-- How a job ended, whichever way it went
select m.client_id,
       m.decided_on::timestamptz,
       'Job',
       m.status || ' — ' || coalesce(e.name, l.title, 'a job'),
       coalesce(m.notes, ''),
       s.name,
       'overview',
       m.id
  from public.lead_matches m
  join public.job_leads l on l.id = m.lead_id
  left join public.employers e on e.id = l.employer_id
  left join public.staff s on s.id = m.created_by
 where m.decided_on is not null

union all

-- Tasks, once done. An open task is on the dashboard, not in a history.
select t.client_id,
       t.done_at,
       'Task',
       'Done — ' || t.title,
       '',
       s.name,
       'tasks',
       t.id
  from public.tasks t
  left join public.staff s on s.id = t.assigned_staff_id
 where t.status = 'Done' and t.done_at is not null

union all

-- Forms completed
select f.client_id,
       f.completed_at,
       'Form',
       'Completed — ' || coalesce(ft.name, 'form'),
       '',
       f.completed_by_name,
       'forms',
       f.id
  from public.forms f
  left join public.form_templates ft on ft.id = f.template_id
 where f.completed_at is not null

union all

-- Forms sent on
select f.client_id,
       f.sent_at,
       'Form',
       'Sent — ' || coalesce(ft.name, 'form'),
       coalesce(f.sent_to, ''),
       f.completed_by_name,
       'forms',
       f.id
  from public.forms f
  left join public.form_templates ft on ft.id = f.template_id
 where f.sent_at is not null

union all

-- Counselor contacts, including reports sent
select cl.client_id,
       cl.date::timestamptz,
       'Counselor',
       cl.method || coalesce(' — ' || nullif(cl.topic, ''), ''),
       coalesce(cl.outcome, ''),
       s.name,
       'counselors',
       cl.id
  from public.contact_log cl
  left join public.staff s on s.id = cl.staff_id
 where cl.client_id is not null

union all

-- A placement starting
select p.client_id,
       p.start_date::timestamptz,
       'Placement',
       'Started — ' || coalesce(nullif(p.employer, ''), 'a placement'),
       coalesce(p.title, ''),
       null,
       'placements',
       p.id
  from public.placements p
 where p.start_date is not null

union all

-- Retention checks, one row each, so a gap in them is visible
select p.client_id, c.at::timestamptz, 'Retention',
       c.label || ' check — ' || coalesce(nullif(p.employer, ''), 'placement'),
       '', null, 'placements', p.id
  from public.placements p
 cross join lateral (
   values (p.check30, '30 day'), (p.check60, '60 day'), (p.check90, '90 day')
 ) as c(at, label)
 where c.at is not null

union all

-- Service hours, reached through the authorization they were billed under
select a.client_id,
       se.date::timestamptz,
       'Hours',
       public.fmt_hours(se.hours) || ' logged'
         || case when se.non_billable then ' (non-billable)' else '' end,
       coalesce(se.notes, ''),
       s.name,
       'authorizations',
       se.id
  from public.service_entries se
  join public.authorizations a on a.id = se.auth_id
  left join public.staff s on s.id = se.staff_id

union all

-- Appointments, from either side of the Outlook sync
select ce.client_id,
       ce.starts_at,
       'Appointment',
       ce.kind || ' — ' || ce.title,
       coalesce(ce.location, ''),
       s.name,
       'calendar',
       ce.id
  from public.calendar_events ce
  left join public.staff s on s.id = ce.staff_id
 where ce.client_id is not null

union all

-- Logged correspondence. Subject and direction only, as everywhere else.
select ml.client_id,
       ml.sent_at,
       'Mail',
       case ml.direction when 'Incoming' then 'From ' else 'To ' end
         || ml.counterpart_email,
       ml.subject,
       null,
       'calendar',
       ml.id
  from public.mail_log ml
 where ml.client_id is not null;

alter view public.client_activity set (security_invoker = true);
grant select on public.client_activity to authenticated;

comment on view public.client_activity is
  'Read-only feed over the tables that already record what happened. No new source of truth.';
