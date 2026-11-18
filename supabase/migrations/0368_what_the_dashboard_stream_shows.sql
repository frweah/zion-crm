-- What the dashboard's stream shows (client dashboard brief, Part 3).
--
-- The stream was asked for as "notes, texts in and out, calls, recordings
-- (title and length only - never the transcript), status changes, reports
-- sent, invoices raised, payments recorded", with one rule over the top of
-- it: a Personal note never appears there, and is read on the Notes tab by
-- the two roles that may read it at all.
--
-- Three of those were missing and one of them was wrong:
--
--   * A **Personal note was in the stream.** `notes` was read whole, with no
--     word about the category, so the three Personal notes in the practice
--     were on the front page of the record for the two roles whose
--     `visible_roles` let them read the row. The rule said the Notes tab
--     only, and the rule was not written down anywhere a query could see it.
--   * **Recordings** were not in it. They go in with the file's name and the
--     minutes, and nothing else: no transcript, no summary, no turns. The
--     left join to `attachments` is deliberate - where the file is
--     restricted and the reader cannot see it, the line still says a
--     recording happened and how long it was, rather than vanishing.
--   * **Reports sent** were not in it, though the counselor got one.
--   * **Invoices raised** were not in it, though the money arriving was.
--
-- Not added: a **Call**. There is no call anywhere in this database - no
-- table, no contact-log method, no note type - so a Call chip would be a
-- filter that is always empty, which is worse than no chip. It is reported
-- rather than invented.
--
-- `invoices` is read by name and not by star: `warrant` and `voucher` were
-- closed to everybody but Admin in 0360, and `select *` through a
-- security_invoker view would fail for every other role rather than hide a
-- column (see column grants, 0360).
--
-- Rolled back by `supabase/verify_dashboard_stream.sql`.

create or replace view public.client_activity as
select client_id, at, kind, title, detail, who, tab, ref_id
from (
  -- A note, unless it is Personal. Personal is the one category that is
  -- read on the Notes tab and nowhere else.
  select n.client_id,
         coalesce(n.at::timestamptz, n.created_at) as at,
         'Note'::text as kind,
         n.type as title,
         n.text as detail,
         n.staff_name as who,
         'notes'::text as tab,
         n.id as ref_id
    from notes n
   where n.category is distinct from 'Personal'

  union all
  select h.client_id, coalesce(h.at::timestamptz, h.created_at), 'Stage',
         'Moved to ' || h.stage, '', s.name, 'overview', h.id
    from client_stage_history h
    left join staff s on s.id = h.staff_id

  union all
  select m.client_id, m.applied_on::timestamptz, 'Job',
         'Applied — ' || coalesce(e.name, l.title, 'a job'),
         coalesce(l.title, ''), s.name, 'overview', m.id
    from lead_matches m
    join job_leads l on l.id = m.lead_id
    left join employers e on e.id = l.employer_id
    left join staff s on s.id = m.created_by
   where m.applied_on is not null

  union all
  select m.client_id, m.interview_on::timestamptz, 'Interview',
         'Interview — ' || coalesce(e.name, l.title, 'a job'),
         coalesce(l.title, ''), s.name, 'overview', m.id
    from lead_matches m
    join job_leads l on l.id = m.lead_id
    left join employers e on e.id = l.employer_id
    left join staff s on s.id = m.created_by
   where m.interview_on is not null

  union all
  select m.client_id, m.follow_up_on::timestamptz, 'Follow-up',
         'Follow up — ' || coalesce(e.name, l.title, 'a job'),
         coalesce(l.title, ''), s.name, 'overview', m.id
    from lead_matches m
    join job_leads l on l.id = m.lead_id
    left join employers e on e.id = l.employer_id
    left join staff s on s.id = m.created_by
   where m.follow_up_on is not null

  union all
  select m.client_id, m.decided_on::timestamptz, 'Job',
         m.status || ' — ' || coalesce(e.name, l.title, 'a job'),
         coalesce(nullif(m.outcome, ''), m.notes, ''), s.name, 'overview', m.id
    from lead_matches m
    join job_leads l on l.id = m.lead_id
    left join employers e on e.id = l.employer_id
    left join staff s on s.id = m.created_by
   where m.decided_on is not null

  union all
  select t.client_id, t.done_at, 'Task', 'Done — ' || t.title, '', s.name, 'tasks', t.id
    from tasks t
    left join staff s on s.id = t.assigned_staff_id
   where t.status = 'Done' and t.done_at is not null

  union all
  select f.client_id, f.completed_at, 'Form',
         'Completed — ' || coalesce(ft.name, 'form'), '',
         f.completed_by_name, 'forms', f.id
    from forms f
    left join form_templates ft on ft.id = f.template_id
   where f.completed_at is not null

  union all
  select f.client_id, f.sent_at, 'Form',
         'Sent — ' || coalesce(ft.name, 'form'), coalesce(f.sent_to, ''),
         f.completed_by_name, 'forms', f.id
    from forms f
    left join form_templates ft on ft.id = f.template_id
   where f.sent_at is not null

  union all
  select cl.client_id, cl.date::timestamptz, 'Counselor',
         cl.method || coalesce(' — ' || nullif(cl.topic, ''), ''),
         coalesce(cl.outcome, ''), s.name, 'counselors', cl.id
    from contact_log cl
    left join staff s on s.id = cl.staff_id
   where cl.client_id is not null

  union all
  select p.client_id, p.start_date::timestamptz, 'Placement',
         'Started — ' || coalesce(nullif(p.employer, ''), 'a placement'),
         coalesce(p.title, ''), null, 'placements', p.id
    from placements p
   where p.start_date is not null

  union all
  select p.client_id, c.at::timestamptz, 'Retention',
         c.label || ' check — ' || coalesce(nullif(p.employer, ''), 'placement'),
         '', null, 'placements', p.id
    from placements p
    cross join lateral (values (p.check30, '30 day'), (p.check60, '60 day'), (p.check90, '90 day')) c(at, label)
   where c.at is not null

  union all
  select a.client_id, se.date::timestamptz, 'Hours',
         fmt_hours(se.hours) || ' logged' || case when se.non_billable then ' (non-billable)' else '' end,
         coalesce(se.notes, ''), s.name, 'authorizations', se.id
    from service_entries se
    join authorizations a on a.id = se.auth_id
    left join staff s on s.id = se.staff_id

  union all
  select ce.client_id, ce.starts_at, 'Appointment',
         ce.kind || ' — ' || ce.title, coalesce(ce.location, ''), s.name, 'calendar', ce.id
    from calendar_events ce
    left join staff s on s.id = ce.staff_id
   where ce.client_id is not null

  union all
  select ml.client_id, ml.sent_at, 'Mail',
         case ml.direction when 'Incoming' then 'From ' else 'To ' end || ml.counterpart_email,
         ml.subject, null, 'calendar', ml.id
    from mail_log ml
   where ml.client_id is not null

  union all
  select sm.client_id, coalesce(sm.sent_at, sm.created_at), 'Text',
         case sm.direction when 'Incoming' then 'From the client' else 'To the client' end
         || case
              when sm.status = 'Failed' then ' — not delivered'
              when sm.kind = 'Reminder' then ' — appointment reminder'
              else ''
            end,
         sm.body, s.name, 'calendar', sm.id
    from sms_messages sm
    left join staff s on s.id = sm.created_by
   where sm.client_id is not null

  union all
  select a.client_id, coalesce(pay.warrant_date::timestamptz, pay.created_at), 'Payment',
         'Paid $' || to_char(pay.amount, 'FM999,999,990.00') || ' — '
           || coalesce(nullif(a.number, ''), a.service_type),
         case pay.source
           when 'Warrant' then 'Read from the warrant'
           when 'Workbook' then 'Workbook import'
           else 'By hand'
         end,
         nullif(pay.recorded_by_name, ''), 'payments', pay.id
    from payments pay
    join authorizations a on a.id = pay.auth_id

  union all
  select c.client_id, coalesce(c.last_message_at, c.created_at), 'Chat',
         case when c.title <> '' then 'Staff thread — ' || c.title
              else 'Staff thread about this client' end,
         coalesce((select string_agg(s.name, ', ' order by s.name)
                     from conversation_participants p
                     join staff s on s.id = p.staff_id
                    where p.conversation_id = c.id and p.left_at is null), ''),
         (select s.name from staff s where s.id = c.created_by),
         'chat', c.id
    from conversations c
   where c.kind = 'internal' and c.client_id is not null

  union all
  select c.client_id, coalesce(c.last_message_at, c.created_at), 'Website',
         'Chat on the website',
         coalesce((select m.body from messages m
                    where m.conversation_id = c.id and m.sender_kind = 'visitor'
                    order by m.seq limit 1), ''),
         (select s.name from staff s where s.id = c.assigned_staff_id),
         'web', c.id
    from conversations c
   where c.kind = 'web' and c.client_id is not null and not c.spam

  -- A recording: what it was called and how long it ran. The transcript, the
  -- turns and the summary are on the Documents tab, where confirming one is
  -- a job of work; here they would be a transcript on the front page of the
  -- record.
  union all
  select r.client_id,
         coalesce(r.confirmed_at, r.created_at),
         'Recording',
         coalesce(nullif(att.filename, ''), 'Recording')
           || case when r.minutes is null then ''
                   else ' — ' || to_char(r.minutes, 'FM999990') || ' min' end,
         '',
         s.name,
         'documents',
         r.id
    from recordings r
    left join attachments att on att.id = r.attachment_id
    left join staff s on s.id = r.staff_id
   where r.client_id is not null

  -- A report that went to the counselor.
  union all
  select cr.client_id, cr.sent_at, 'Report',
         'Report sent — ' || to_char(cr.period, 'FMMon YYYY'),
         coalesce(cr.sent_to, ''), s.name, 'documents', cr.id
    from client_reports cr
    left join staff s on s.id = cr.sent_by
   where cr.sent_at is not null

  -- An invoice that went out. Its number and its amount; the warrant it was
  -- eventually paid by is Admin's business and is not read here.
  union all
  select i.client_id, i.submitted_on::timestamptz, 'Invoice',
         'Invoice ' || i.number::text || ' — $' || to_char(i.amount, 'FM999,999,990.00'),
         coalesce(nullif(a.number, ''), a.service_type, ''), s.name, 'billing', i.id
    from invoices i
    left join authorizations a on a.id = i.auth_id
    left join staff s on s.id = i.submitted_by
   where i.submitted_on is not null and i.client_id is not null
) feed;

-- The view reads as whoever is asking, so every rule on the tables underneath
-- still applies. Supabase grants a new view to everybody; a replaced one
-- keeps what it had, and this says so out loud rather than trusting that.
alter view public.client_activity set (security_invoker = true);
revoke all on public.client_activity from anon;
grant select on public.client_activity to authenticated;
