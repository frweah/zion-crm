-- Zion Vocational Rehab CRM — the activity line stops naming the warrant
--
-- `client_activity` wrote the warrant number and the voucher into the detail
-- of a payment on the client's own timeline: "Warrant F15xxxxxx · voucher
-- 26Axxxxx". Every role that can open a client could read it there, and no
-- warrant gate was ever near it.
--
-- 0360 closed `payments.warrant_no` and `payments.voucher`, and because this
-- view reads as the invoker it then refused everybody - including Admin, who
-- was told it could no longer read a client's activity at all. Which is how
-- the leak was found: a column grant turns a quiet read into a loud failure.
--
-- The line says how the payment came to be on record instead - read from the
-- warrant, imported from the workbook, or entered by hand - which is the same
-- thing `recordedHow` puts beside a payment on the authorization record, and
-- names no number.
--
-- The definition is restated from what the database held (dump-function.mjs),
-- not from the migration that last created it.

begin;

create or replace view public.client_activity
with (security_invoker = true) as
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
            'Note'::text AS kind,
            n.type AS title,
            n.text AS detail,
            n.staff_name AS who,
            'notes'::text AS tab,
            n.id AS ref_id
           FROM notes n
        UNION ALL
         SELECT h.client_id,
            COALESCE(h.at::timestamp with time zone, h.created_at) AS "coalesce",
            'Stage'::text AS text,
            'Moved to '::text || h.stage,
            ''::text AS text,
            s.name,
            'overview'::text AS text,
            h.id
           FROM client_stage_history h
             LEFT JOIN staff s ON s.id = h.staff_id
        UNION ALL
         SELECT m.client_id,
            m.applied_on::timestamp with time zone AS applied_on,
            'Job'::text AS text,
            'Applied — '::text || COALESCE(e.name, l.title, 'a job'::text),
            COALESCE(l.title, ''::text) AS "coalesce",
            s.name,
            'overview'::text AS text,
            m.id
           FROM lead_matches m
             JOIN job_leads l ON l.id = m.lead_id
             LEFT JOIN employers e ON e.id = l.employer_id
             LEFT JOIN staff s ON s.id = m.created_by
          WHERE m.applied_on IS NOT NULL
        UNION ALL
         SELECT m.client_id,
            m.interview_on::timestamp with time zone AS interview_on,
            'Interview'::text AS text,
            'Interview — '::text || COALESCE(e.name, l.title, 'a job'::text),
            COALESCE(l.title, ''::text) AS "coalesce",
            s.name,
            'overview'::text AS text,
            m.id
           FROM lead_matches m
             JOIN job_leads l ON l.id = m.lead_id
             LEFT JOIN employers e ON e.id = l.employer_id
             LEFT JOIN staff s ON s.id = m.created_by
          WHERE m.interview_on IS NOT NULL
        UNION ALL
         SELECT m.client_id,
            m.follow_up_on::timestamp with time zone AS follow_up_on,
            'Follow-up'::text AS text,
            'Follow up — '::text || COALESCE(e.name, l.title, 'a job'::text),
            COALESCE(l.title, ''::text) AS "coalesce",
            s.name,
            'overview'::text AS text,
            m.id
           FROM lead_matches m
             JOIN job_leads l ON l.id = m.lead_id
             LEFT JOIN employers e ON e.id = l.employer_id
             LEFT JOIN staff s ON s.id = m.created_by
          WHERE m.follow_up_on IS NOT NULL
        UNION ALL
         SELECT m.client_id,
            m.decided_on::timestamp with time zone AS decided_on,
            'Job'::text AS text,
            (m.status || ' — '::text) || COALESCE(e.name, l.title, 'a job'::text),
            COALESCE(NULLIF(m.outcome, ''::text), m.notes, ''::text) AS "coalesce",
            s.name,
            'overview'::text AS text,
            m.id
           FROM lead_matches m
             JOIN job_leads l ON l.id = m.lead_id
             LEFT JOIN employers e ON e.id = l.employer_id
             LEFT JOIN staff s ON s.id = m.created_by
          WHERE m.decided_on IS NOT NULL
        UNION ALL
         SELECT t.client_id,
            t.done_at,
            'Task'::text AS text,
            'Done — '::text || t.title,
            ''::text AS text,
            s.name,
            'tasks'::text AS text,
            t.id
           FROM tasks t
             LEFT JOIN staff s ON s.id = t.assigned_staff_id
          WHERE t.status = 'Done'::text AND t.done_at IS NOT NULL
        UNION ALL
         SELECT f.client_id,
            f.completed_at,
            'Form'::text AS text,
            'Completed — '::text || COALESCE(ft.name, 'form'::text),
            ''::text AS text,
            f.completed_by_name,
            'forms'::text AS text,
            f.id
           FROM forms f
             LEFT JOIN form_templates ft ON ft.id = f.template_id
          WHERE f.completed_at IS NOT NULL
        UNION ALL
         SELECT f.client_id,
            f.sent_at,
            'Form'::text AS text,
            'Sent — '::text || COALESCE(ft.name, 'form'::text),
            COALESCE(f.sent_to, ''::text) AS "coalesce",
            f.completed_by_name,
            'forms'::text AS text,
            f.id
           FROM forms f
             LEFT JOIN form_templates ft ON ft.id = f.template_id
          WHERE f.sent_at IS NOT NULL
        UNION ALL
         SELECT cl.client_id,
            cl.date::timestamp with time zone AS date,
            'Counselor'::text AS text,
            cl.method || COALESCE(' — '::text || NULLIF(cl.topic, ''::text), ''::text),
            COALESCE(cl.outcome, ''::text) AS "coalesce",
            s.name,
            'counselors'::text AS text,
            cl.id
           FROM contact_log cl
             LEFT JOIN staff s ON s.id = cl.staff_id
          WHERE cl.client_id IS NOT NULL
        UNION ALL
         SELECT p.client_id,
            p.start_date::timestamp with time zone AS start_date,
            'Placement'::text AS text,
            'Started — '::text || COALESCE(NULLIF(p.employer, ''::text), 'a placement'::text),
            COALESCE(p.title, ''::text) AS "coalesce",
            NULL::text AS text,
            'placements'::text AS text,
            p.id
           FROM placements p
          WHERE p.start_date IS NOT NULL
        UNION ALL
         SELECT p.client_id,
            c.at::timestamp with time zone AS at,
            'Retention'::text AS text,
            (c.label || ' check — '::text) || COALESCE(NULLIF(p.employer, ''::text), 'placement'::text),
            ''::text AS text,
            NULL::text AS text,
            'placements'::text AS text,
            p.id
           FROM placements p
             CROSS JOIN LATERAL ( VALUES (p.check30,'30 day'::text), (p.check60,'60 day'::text), (p.check90,'90 day'::text)) c(at, label)
          WHERE c.at IS NOT NULL
        UNION ALL
         SELECT a.client_id,
            se.date::timestamp with time zone AS date,
            'Hours'::text AS text,
            (fmt_hours(se.hours) || ' logged'::text) ||
                CASE
                    WHEN se.non_billable THEN ' (non-billable)'::text
                    ELSE ''::text
                END,
            COALESCE(se.notes, ''::text) AS "coalesce",
            s.name,
            'authorizations'::text AS text,
            se.id
           FROM service_entries se
             JOIN authorizations a ON a.id = se.auth_id
             LEFT JOIN staff s ON s.id = se.staff_id
        UNION ALL
         SELECT ce.client_id,
            ce.starts_at,
            'Appointment'::text AS text,
            (ce.kind || ' — '::text) || ce.title,
            COALESCE(ce.location, ''::text) AS "coalesce",
            s.name,
            'calendar'::text AS text,
            ce.id
           FROM calendar_events ce
             LEFT JOIN staff s ON s.id = ce.staff_id
          WHERE ce.client_id IS NOT NULL
        UNION ALL
         SELECT ml.client_id,
            ml.sent_at,
            'Mail'::text AS text,
                CASE ml.direction
                    WHEN 'Incoming'::text THEN 'From '::text
                    ELSE 'To '::text
                END || ml.counterpart_email,
            ml.subject,
            NULL::text AS text,
            'calendar'::text AS text,
            ml.id
           FROM mail_log ml
          WHERE ml.client_id IS NOT NULL
        UNION ALL
         SELECT sm.client_id,
            COALESCE(sm.sent_at, sm.created_at) AS "coalesce",
            'Text'::text AS text,
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
            'calendar'::text AS text,
            sm.id
           FROM sms_messages sm
             LEFT JOIN staff s ON s.id = sm.created_by
          WHERE sm.client_id IS NOT NULL
        UNION ALL
         SELECT a.client_id,
            COALESCE(pay.warrant_date::timestamp with time zone, pay.created_at) AS "coalesce",
            'Payment'::text AS text,
            (('Paid $'::text || to_char(pay.amount, 'FM999,999,990.00'::text)) || ' — '::text) || COALESCE(NULLIF(a.number, ''::text), a.service_type),
            CASE pay.source
                WHEN 'Warrant'::text THEN 'Read from the warrant'::text
                WHEN 'Workbook'::text THEN 'Workbook import'::text
                ELSE 'By hand'::text
            END,
            NULLIF(pay.recorded_by_name, ''::text) AS "nullif",
            'payments'::text AS text,
            pay.id
           FROM payments pay
             JOIN authorizations a ON a.id = pay.auth_id
        UNION ALL
         SELECT c.client_id,
            COALESCE(c.last_message_at, c.created_at) AS "coalesce",
            'Chat'::text AS text,
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
            'chat'::text AS text,
            c.id
           FROM conversations c
          WHERE c.kind = 'internal'::text AND c.client_id IS NOT NULL
        UNION ALL
         SELECT c.client_id,
            COALESCE(c.last_message_at, c.created_at) AS "coalesce",
            'Website'::text AS text,
            'Chat on the website'::text AS text,
            COALESCE(( SELECT m.body
                   FROM messages m
                  WHERE m.conversation_id = c.id AND m.sender_kind = 'visitor'::text
                  ORDER BY m.seq
                 LIMIT 1), ''::text) AS "coalesce",
            ( SELECT s.name
                   FROM staff s
                  WHERE s.id = c.assigned_staff_id) AS name,
            'web'::text AS text,
            c.id
           FROM conversations c
          WHERE c.kind = 'web'::text AND c.client_id IS NOT NULL AND NOT c.spam) feed;

-- Supabase grants a new view everything to `authenticated`, and a replace
-- leaves the existing grants alone - stated anyway, so the day this is dropped
-- and recreated it comes back read-only (verify_view_grants).
revoke all on public.client_activity from public, anon, authenticated;
grant select on public.client_activity to authenticated;

commit;
