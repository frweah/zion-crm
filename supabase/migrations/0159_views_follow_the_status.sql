-- Zion Vocational Rehab CRM — the long tail of a status rename
-- (Billing Simplification Brief §§1, 4, 10, 11)
--
-- Five views still asked for an authorization whose status is 'Open', a
-- value §4 removed, and one of them read the invoice table §10 removes.
-- Every one of them would have gone quietly wrong rather than loudly:
-- 'Open' matches nothing now, so each returned zero or nothing at all, and a
-- view that returns nothing looks exactly like a practice with nothing to
-- show.
--
-- verify_capacity caught the first. It is the reason the rest were looked
-- for rather than discovered one failing screen at a time.
--
-- Each view below is the live definition with the status condition swapped
-- and, for billing_position, the invoice count moved onto the
-- authorization's own payment. Task statuses are left alone: a task is still
-- Open or Done, and that is a different column with the same word in it.

-- ── billing_position: where each authorization stands on money ──
--
-- Written out rather than spliced. It counted paid and outstanding from the
-- invoice table, which §10 removes, and every one of those figures now lives
-- on the authorization itself - so a splice would have left a view shaped
-- around a record that is gone. The payment count still comes from
-- `payments`, which is the warrant record and is untouched by this brief.
--
-- The column list is unchanged, because other things select from this.
create or replace view public.billing_position as
 SELECT e.auth_id,
    e.client_id,
    c.name AS client_name,
    e.auth_number,
    e.service_type,
    e.status,
    e.authorized,
    e.invoiced,
    e.received AS paid,
    e.outstanding,
    GREATEST(e.authorized - e.invoiced, 0::numeric) AS not_yet_invoiced,
    a.paid_on AS last_paid_on,
    COALESCE(p.n, 0::bigint) AS payments
   FROM authorization_economics e
     JOIN clients c ON c.id = e.client_id
     JOIN authorizations a ON a.id = e.auth_id
     LEFT JOIN ( SELECT y.auth_id, count(*) AS n
                   FROM payments y
                  GROUP BY y.auth_id) p ON p.auth_id = e.auth_id;
alter view public.billing_position set (security_invoker = true);
grant select on public.billing_position to authenticated;

-- ── client_next_up: Which authorization is still live. ──
create or replace view public.client_next_up as
 SELECT DISTINCT ON (client_id) client_id,
    at,
    kind,
    title
   FROM ( SELECT e.client_id,
            e.starts_at AS at,
            e.kind,
            e.title
           FROM calendar_events e
          WHERE e.client_id IS NOT NULL AND e.starts_at >= now() AND COALESCE(e.push_state, ''::text) <> 'To remove'::text
        UNION ALL
         SELECT t.client_id,
            t.due::timestamp with time zone AS due,
            'Task'::text,
            t.title
           FROM tasks t
          WHERE t.client_id IS NOT NULL AND t.status = 'Open'::text AND t.due >= practice_today()
        UNION ALL
         SELECT m.client_id,
            m.interview_on::timestamp with time zone AS interview_on,
            'Interview'::text,
            'Interview â€” '::text || COALESCE(e.name, l.title, 'a job'::text)
           FROM lead_matches m
             JOIN job_leads l ON l.id = m.lead_id
             LEFT JOIN employers e ON e.id = l.employer_id
          WHERE m.interview_on >= practice_today()
        UNION ALL
         SELECT m.client_id,
            m.follow_up_on::timestamp with time zone AS follow_up_on,
            'Follow-up'::text,
            'Follow up â€” '::text || COALESCE(e.name, l.title, 'a job'::text)
           FROM lead_matches m
             JOIN job_leads l ON l.id = m.lead_id
             LEFT JOIN employers e ON e.id = l.employer_id
          WHERE m.follow_up_on >= practice_today()) x
  ORDER BY client_id, at;
alter view public.client_next_up set (security_invoker = true);
grant select on public.client_next_up to authenticated;

-- ── client_paperwork: Which authorization still wants its forms. ──
create or replace view public.client_paperwork as
 WITH required AS (
         SELECT a.client_id,
            a.id AS auth_id,
            a.number AS auth_number,
            a.service_type,
            t.id AS template_id,
            t.usor,
            t.name AS form_name,
            t.monthly
           FROM authorizations a
             JOIN form_templates t ON t.required_for_billing AND (a.service_type = ANY (t.services))
          WHERE a.status = ANY (ARRAY['Authorized'::text, 'Due'::text, 'Submitted'::text])
        ), expected AS (
        (
                 SELECT r.client_id,
                    r.auth_id,
                    r.auth_number,
                    r.service_type,
                    r.template_id,
                    r.usor,
                    r.form_name,
                    r.monthly,
                    to_char(se.date::timestamp with time zone, 'YYYY-MM'::text) AS month,
                    sum(se.hours) AS hours_logged
                   FROM required r
                     JOIN service_entries se ON se.auth_id = r.auth_id
                  WHERE r.monthly
                  GROUP BY r.client_id, r.auth_id, r.auth_number, r.service_type, r.template_id, r.usor, r.form_name, r.monthly, (to_char(se.date::timestamp with time zone, 'YYYY-MM'::text))
                UNION
                 SELECT r.client_id,
                    r.auth_id,
                    r.auth_number,
                    r.service_type,
                    r.template_id,
                    r.usor,
                    r.form_name,
                    r.monthly,
                    to_char(practice_today()::timestamp with time zone, 'YYYY-MM'::text) AS to_char,
                    0::numeric AS "numeric"
                   FROM required r
                  WHERE r.monthly
        ) UNION ALL
         SELECT r.client_id,
            r.auth_id,
            r.auth_number,
            r.service_type,
            r.template_id,
            r.usor,
            r.form_name,
            r.monthly,
            NULL::text AS text,
            COALESCE(( SELECT sum(se.hours) AS sum
                   FROM service_entries se
                  WHERE se.auth_id = r.auth_id), 0::numeric) AS "coalesce"
           FROM required r
          WHERE NOT r.monthly
        )
 SELECT e.client_id,
    e.auth_id,
    e.auth_number,
    e.service_type,
    e.template_id,
    e.usor,
    e.form_name,
    e.monthly,
    e.month,
    e.hours_logged,
    f.id AS form_id,
    f.status AS form_status,
        CASE
            WHEN f.status = ANY (ARRAY['Completed'::text, 'Sent'::text]) THEN 'Complete'::text
            WHEN f.status = 'Draft'::text THEN 'In progress'::text
            WHEN COALESCE(e.hours_logged, 0::numeric) > 0::numeric THEN 'Missing'::text
            ELSE 'Not started'::text
        END AS state
   FROM expected e
     LEFT JOIN forms f ON f.client_id = e.client_id AND f.template_id = e.template_id AND f.auth_id = e.auth_id AND (e.month IS NULL OR f.month = e.month);
alter view public.client_paperwork set (security_invoker = true);
grant select on public.client_paperwork to authenticated;

-- ── staff_capacity: What hours a member of staff still owes. ──
create or replace view public.staff_capacity as
 SELECT s.id AS staff_id,
    s.name,
    s.role,
    c.active_clients,
    c.quiet_clients,
    c.front_clients,
    a.open_authorizations,
    a.committed_hours,
    a.committed_value,
    h.hours_30,
    h.hours_90,
    h.client_hours_90,
    h.uncategorised_hours_90
   FROM staff s
     LEFT JOIN LATERAL ( SELECT count(*) FILTER (WHERE cl.status = 'Active'::text) AS active_clients,
            count(*) FILTER (WHERE cl.status = 'Active'::text AND COALESCE(la.last_activity_at, '-infinity'::timestamp with time zone) < (now() - '30 days'::interval)) AS quiet_clients,
            count(*) FILTER (WHERE cl.status = 'Active'::text AND (cl.stage = ANY (ARRAY['Referral'::text, 'Intake'::text, 'Assessment'::text]))) AS front_clients
           FROM clients cl
             LEFT JOIN client_last_activity la ON la.client_id = cl.id
          WHERE cl.assigned_staff_id = s.id) c ON true
     LEFT JOIN LATERAL ( SELECT count(*) AS open_authorizations,
            COALESCE(sum(e.hours_left), 0::numeric) AS committed_hours,
            COALESCE(sum(e.committed), 0::numeric) AS committed_value
           FROM authorization_economics e
             JOIN clients cl ON cl.id = e.client_id
          WHERE cl.assigned_staff_id = s.id AND e.status = ANY (ARRAY['Authorized'::text, 'Due'::text, 'Submitted'::text])) a ON true
     LEFT JOIN LATERAL ( SELECT COALESCE(sum(v.hours) FILTER (WHERE v.worked_on >= (practice_today() - 30)), 0::numeric) AS hours_30,
            COALESCE(sum(v.hours) FILTER (WHERE v.worked_on >= (practice_today() - 90)), 0::numeric) AS hours_90,
            COALESCE(sum(v.hours) FILTER (WHERE v.worked_on >= (practice_today() - 90) AND v.category_billable), 0::numeric) AS client_hours_90,
            COALESCE(sum(v.hours) FILTER (WHERE v.worked_on >= (practice_today() - 90) AND v.category IS NULL), 0::numeric) AS uncategorised_hours_90
           FROM work_session_values v
          WHERE v.staff_id = s.id) h ON true
  WHERE s.active;
alter view public.staff_capacity set (security_invoker = true);
grant select on public.staff_capacity to authenticated;

-- ── staff_checklist: Which authorization a checklist item is still about. ──
create or replace view public.staff_checklist as
 SELECT s.id AS staff_id,
    s.name AS staff_name,
    s.active AS staff_active,
    COALESCE(e.employment_type, 'Contractor'::text) AS employment_type,
    t.id AS task_id,
    t.phase,
    t.label,
    t.detail,
    t.auto_key,
    t.required,
    t.sort_order,
        CASE t.auto_key
            WHEN 'account_accepted'::text THEN s.accepted_at IS NOT NULL
            WHEN 'tax_form_signed'::text THEN onboarding_step_done(s.id, 'tax_form_signed'::text)
            WHEN 'address_on_file'::text THEN COALESCE(NULLIF(p.address_line1, ''::text), ''::text) <> ''::text
            WHEN 'pay_rate_set'::text THEN (EXISTS ( SELECT 1
               FROM staff_pay r
              WHERE r.staff_id = s.id))
            WHEN 'tour_completed'::text THEN ( SELECT tp.hints_seen >= tp.hints_total AND tp.hints_total > 0
               FROM my_tour_progress tp
              WHERE tp.staff_id = s.id)
            WHEN 'personal_details'::text THEN onboarding_step_done(s.id, 'personal_details'::text)
            WHEN 'identity_documents'::text THEN onboarding_step_done(s.id, 'identity_documents'::text)
            WHEN 'identity_inspected'::text THEN onboarding_step_done(s.id, 'identity_inspected'::text)
            WHEN 'certifications_submitted'::text THEN onboarding_step_done(s.id, 'certifications_submitted'::text)
            WHEN 'policy_signed'::text THEN onboarding_step_done(s.id, 'policy_signed'::text)
            WHEN 'payment_setup'::text THEN onboarding_step_done(s.id, 'payment_setup'::text)
            WHEN 'account_closed'::text THEN NOT s.active
            WHEN 'clients_reassigned'::text THEN NOT (EXISTS ( SELECT 1
               FROM clients c
              WHERE c.assigned_staff_id = s.id AND c.status = 'Active'::text))
            WHEN 'tasks_reassigned'::text THEN NOT (EXISTS ( SELECT 1
               FROM tasks k
              WHERE k.assigned_staff_id = s.id AND k.status = 'Open'::text))
            WHEN 'statements_settled'::text THEN NOT (EXISTS ( SELECT 1
               FROM contractor_statements st
              WHERE st.staff_id = s.id AND (st.status = ANY (ARRAY['Draft'::text, 'Submitted'::text]))))
            ELSE NULL::boolean
        END AS auto_done,
    i.done_on,
    i.done_by,
    COALESCE(i.note, ''::text) AS note
   FROM staff s
     CROSS JOIN checklist_tasks t
     LEFT JOIN staff_employment e ON e.staff_id = s.id
     LEFT JOIN contractor_profiles p ON p.staff_id = s.id
     LEFT JOIN staff_checklist_items i ON i.staff_id = s.id AND i.task_id = t.id
  WHERE t.active AND (t.applies_to IS NULL OR (COALESCE(e.employment_type, 'Contractor'::text) = ANY (t.applies_to))) AND (( SELECT is_admin() AS is_admin) OR s.id = (( SELECT current_staff_id() AS current_staff_id)));
alter view public.staff_checklist set (security_invoker = true);
grant select on public.staff_checklist to authenticated;
