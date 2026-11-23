/**
 * A call reads as a call on the client's record (Part 3, 23 November 2026).
 *
 * The activity stream had twenty-one kinds and no Call: every note arrived as
 * a Note, so a phone call looked like a piece of writing and the dashboard's
 * Calls chip - which the owner asked to have back - had nothing to filter on.
 * A note whose method is Phone is a call, and the only thing that changes
 * here is the word the stream calls it.
 *
 * Re-stated from the live view rather than from the migration that last
 * created it: this one has been replaced six times.
 */

create or replace view public.client_activity as
 SELECT client_id,
    at,
    kind,
    title,
    detail,
    who,
    tab,
    ref_id
   FROM ( SELECT n.client_id,
            COALESCE(n.at::timestamp with time zone, n.created_at) AS at,
            -- A call is a note that says so (0378). The stream carried every
            -- note as a Note, so the client dashboard had no way to show a
            -- phone call as one and the Calls chip had nothing to filter.
            CASE WHEN n.method = 'Phone' THEN 'Call'::text ELSE 'Note'::text END AS kind,
            n.type AS title,
            n.text AS detail,
            n.staff_name AS who,
            'notes'::text AS tab,
            n.id AS ref_id
           FROM notes n
          WHERE n.category IS DISTINCT FROM 'Personal'::text
        UNION ALL
         SELECT h.client_id,
            COALESCE(h.at::timestamp with time zone, h.created_at) AS "coalesce",
            'Stage'::text,
            'Moved to '::text || h.stage,
            ''::text,
            s.name,
            'overview'::text,
            h.id
           FROM client_stage_history h
             LEFT JOIN staff s ON s.id = h.staff_id
        UNION ALL
         SELECT m.client_id,
            m.applied_on::timestamp with time zone AS applied_on,
            'Job'::text,
            'Applied — '::text || COALESCE(e.name, l.title, 'a job'::text),
            COALESCE(l.title, ''::text) AS "coalesce",
            s.name,
            'overview'::text,
            m.id
           FROM lead_matches m
             JOIN job_leads l ON l.id = m.lead_id
             LEFT JOIN employers e ON e.id = l.employer_id
             LEFT JOIN staff s ON s.id = m.created_by
          WHERE m.applied_on IS NOT NULL
        UNION ALL
         SELECT m.client_id,
            m.interview_on::timestamp with time zone AS interview_on,
            'Interview'::text,
            'Interview — '::text || COALESCE(e.name, l.title, 'a job'::text),
            COALESCE(l.title, ''::text) AS "coalesce",
            s.name,
            'overview'::text,
            m.id
           FROM lead_matches m
             JOIN job_leads l ON l.id = m.lead_id
             LEFT JOIN employers e ON e.id = l.employer_id
             LEFT JOIN staff s ON s.id = m.created_by
          WHERE m.interview_on IS NOT NULL
        UNION ALL
         SELECT m.client_id,
            m.follow_up_on::timestamp with time zone AS follow_up_on,
            'Follow-up'::text,
            'Follow up — '::text || COALESCE(e.name, l.title, 'a job'::text),
            COALESCE(l.title, ''::text) AS "coalesce",
            s.name,
            'overview'::text,
            m.id
           FROM lead_matches m
             JOIN job_leads l ON l.id = m.lead_id
             LEFT JOIN employers e ON e.id = l.employer_id
             LEFT JOIN staff s ON s.id = m.created_by
          WHERE m.follow_up_on IS NOT NULL
        UNION ALL
         SELECT m.client_id,
            m.decided_on::timestamp with time zone AS decided_on,
            'Job'::text,
            (m.status || ' — '::text) || COALESCE(e.name, l.title, 'a job'::text),
            COALESCE(NULLIF(m.outcome, ''::text), m.notes, ''::text) AS "coalesce",
            s.name,
            'overview'::text,
            m.id
           FROM lead_matches m
             JOIN job_leads l ON l.id = m.lead_id
             LEFT JOIN employers e ON e.id = l.employer_id
             LEFT JOIN staff s ON s.id = m.created_by
          WHERE m.decided_on IS NOT NULL
        UNION ALL
         SELECT t.client_id,
            t.done_at,
            'Task'::text,
            'Done — '::text || t.title,
            ''::text,
            s.name,
            'tasks'::text,
            t.id
           FROM tasks t
             LEFT JOIN staff s ON s.id = t.assigned_staff_id
          WHERE t.status = 'Done'::text AND t.done_at IS NOT NULL
        UNION ALL
         SELECT f.client_id,
            f.completed_at,
            'Form'::text,
            'Completed — '::text || COALESCE(ft.name, 'form'::text),
            ''::text,
            f.completed_by_name,
            'forms'::text,
            f.id
           FROM forms f
             LEFT JOIN form_templates ft ON ft.id = f.template_id
          WHERE f.completed_at IS NOT NULL
        UNION ALL
         SELECT f.client_id,
            f.sent_at,
            'Form'::text,
            'Sent — '::text || COALESCE(ft.name, 'form'::text),
            COALESCE(f.sent_to, ''::text) AS "coalesce",
            f.completed_by_name,
            'forms'::text,
            f.id
           FROM forms f
             LEFT JOIN form_templates ft ON ft.id = f.template_id
          WHERE f.sent_at IS NOT NULL
        UNION ALL
         SELECT cl.client_id,
            cl.date::timestamp with time zone AS date,
            'Counselor'::text,
            cl.method || COALESCE(' — '::text || NULLIF(cl.topic, ''::text), ''::text),
            COALESCE(cl.outcome, ''::text) AS "coalesce",
            s.name,
            'counselors'::text,
            cl.id
           FROM contact_log cl
             LEFT JOIN staff s ON s.id = cl.staff_id
          WHERE cl.client_id IS NOT NULL
        UNION ALL
         SELECT p.client_id,
            p.start_date::timestamp with time zone AS start_date,
            'Placement'::text,
            'Started — '::text || COALESCE(NULLIF(p.employer, ''::text), 'a placement'::text),
            COALESCE(p.title, ''::text) AS "coalesce",
            NULL::text,
            'placements'::text,
            p.id
           FROM placements p
          WHERE p.start_date IS NOT NULL
        UNION ALL
         SELECT p.client_id,
            c.at::timestamp with time zone AS at,
            'Retention'::text,
            (c.label || ' check — '::text) || COALESCE(NULLIF(p.employer, ''::text), 'placement'::text),
            ''::text,
            NULL::text,
            'placements'::text,
            p.id
           FROM placements p
             CROSS JOIN LATERAL ( VALUES (p.check30,'30 day'::text), (p.check60,'60 day'::text), (p.check90,'90 day'::text)) c(at, label)
          WHERE c.at IS NOT NULL
        UNION ALL
         SELECT a.client_id,
            se.date::timestamp with time zone AS date,
            'Hours'::text,
            (fmt_hours(se.hours) || ' logged'::text) ||
                CASE
                    WHEN se.non_billable THEN ' (non-billable)'::text
                    ELSE ''::text
                END,
            COALESCE(se.notes, ''::text) AS "coalesce",
            s.name,
            'authorizations'::text,
            se.id
           FROM service_entries se
             JOIN authorizations a ON a.id = se.auth_id
             LEFT JOIN staff s ON s.id = se.staff_id
        UNION ALL
         SELECT ce.client_id,
            ce.starts_at,
            'Appointment'::text,
            (ce.kind || ' — '::text) || ce.title,
            COALESCE(ce.location, ''::text) AS "coalesce",
            s.name,
            'calendar'::text,
            ce.id
           FROM calendar_events ce
             LEFT JOIN staff s ON s.id = ce.staff_id
          WHERE ce.client_id IS NOT NULL
        UNION ALL
         SELECT ml.client_id,
            ml.sent_at,
            'Mail'::text,
                CASE ml.direction
                    WHEN 'Incoming'::text THEN 'From '::text
                    ELSE 'To '::text
                END || ml.counterpart_email,
            ml.subject,
            NULL::text,
            'calendar'::text,
            ml.id
           FROM mail_log ml
          WHERE ml.client_id IS NOT NULL
        UNION ALL
         SELECT sm.client_id,
            COALESCE(sm.sent_at, sm.created_at) AS "coalesce",
            'Text'::text,
                CASE sm.direction
                    WHEN 'Incoming'::text THEN 'From the client'::text
                    ELSE 'To the client'::text
                END ||
                CASE
                    WHEN sm.status = 'Failed'::text THEN ' — not delivered'::text
                    WHEN sm.kind = 'Reminder'::text THEN ' — appointment reminder'::text
                    ELSE ''::text
                END,
            sm.body,
            s.name,
            'calendar'::text,
            sm.id
           FROM sms_messages sm
             LEFT JOIN staff s ON s.id = sm.created_by
          WHERE sm.client_id IS NOT NULL
        UNION ALL
         SELECT a.client_id,
            COALESCE(pay.warrant_date::timestamp with time zone, pay.created_at) AS "coalesce",
            'Payment'::text,
            (('Paid $'::text || to_char(pay.amount, 'FM999,999,990.00'::text)) || ' — '::text) || COALESCE(NULLIF(a.number, ''::text), a.service_type),
                CASE pay.source
                    WHEN 'Warrant'::text THEN 'Read from the warrant'::text
                    WHEN 'Workbook'::text THEN 'Workbook import'::text
                    ELSE 'By hand'::text
                END AS "case",
            NULLIF(pay.recorded_by_name, ''::text) AS "nullif",
            'payments'::text,
            pay.id
           FROM payments pay
             JOIN authorizations a ON a.id = pay.auth_id
        UNION ALL
         SELECT c.client_id,
            COALESCE(c.last_message_at, c.created_at) AS "coalesce",
            'Chat'::text,
                CASE
                    WHEN c.title <> ''::text THEN 'Staff thread — '::text || c.title
                    ELSE 'Staff thread about this client'::text
                END AS "case",
            COALESCE(( SELECT string_agg(s.name, ', '::text ORDER BY s.name) AS string_agg
                   FROM conversation_participants p
                     JOIN staff s ON s.id = p.staff_id
                  WHERE p.conversation_id = c.id AND p.left_at IS NULL), ''::text) AS "coalesce",
            ( SELECT s.name
                   FROM staff s
                  WHERE s.id = c.created_by) AS name,
            'chat'::text,
            c.id
           FROM conversations c
          WHERE c.kind = 'internal'::text AND c.client_id IS NOT NULL
        UNION ALL
         SELECT c.client_id,
            COALESCE(c.last_message_at, c.created_at) AS "coalesce",
            'Website'::text,
            'Chat on the website'::text,
            COALESCE(( SELECT m.body
                   FROM messages m
                  WHERE m.conversation_id = c.id AND m.sender_kind = 'visitor'::text
                  ORDER BY m.seq
                 LIMIT 1), ''::text) AS "coalesce",
            ( SELECT s.name
                   FROM staff s
                  WHERE s.id = c.assigned_staff_id) AS name,
            'web'::text,
            c.id
           FROM conversations c
          WHERE c.kind = 'web'::text AND c.client_id IS NOT NULL AND NOT c.spam
        UNION ALL
         SELECT r.client_id,
            COALESCE(r.confirmed_at, r.created_at) AS "coalesce",
            'Recording'::text,
            COALESCE(NULLIF(att.filename, ''::text), 'Recording'::text) ||
                CASE
                    WHEN r.minutes IS NULL THEN ''::text
                    WHEN r.minutes < 1::numeric THEN ' — under a minute'::text
                    ELSE (' — '::text || to_char(round(r.minutes), 'FM999990'::text)) || ' min'::text
                END,
            ''::text,
            s.name,
            'documents'::text,
            r.id
           FROM recordings r
             LEFT JOIN attachments att ON att.id = r.attachment_id
             LEFT JOIN staff s ON s.id = r.staff_id
          WHERE r.client_id IS NOT NULL
        UNION ALL
         SELECT cr.client_id,
            cr.sent_at,
            'Report'::text,
            'Report sent — '::text || to_char(cr.period::timestamp with time zone, 'FMMon YYYY'::text),
            COALESCE(cr.sent_to, ''::text) AS "coalesce",
            s.name,
            'documents'::text,
            cr.id
           FROM client_reports cr
             LEFT JOIN staff s ON s.id = cr.sent_by
          WHERE cr.sent_at IS NOT NULL
        UNION ALL
         SELECT i.client_id,
            i.submitted_on::timestamp with time zone AS submitted_on,
            'Invoice'::text,
            (('Invoice '::text || i.number::text) || ' — $'::text) || to_char(i.amount, 'FM999,999,990.00'::text),
            COALESCE(NULLIF(a.number, ''::text), a.service_type, ''::text) AS "coalesce",
            s.name,
            'billing'::text,
            i.id
           FROM invoices i
             LEFT JOIN authorizations a ON a.id = i.auth_id
             LEFT JOIN staff s ON s.id = i.submitted_by
          WHERE i.submitted_on IS NOT NULL AND i.client_id IS NOT NULL) feed;

-- Supabase grants every new view to authenticated on creation, and a replace
-- keeps what was there; both are stated so that neither depends on it.
alter view public.client_activity set (security_invoker = on);
revoke all on public.client_activity from anon;
grant select on public.client_activity to authenticated;
