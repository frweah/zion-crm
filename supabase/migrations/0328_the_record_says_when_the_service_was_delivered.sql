-- Zion Vocational Rehab CRM — the record says when the service was delivered
--
-- Three columns onto `authorization_record`, which is what the authorization
-- screen reads: the day the service was delivered, who said so, and what the
-- amount is evidence of. The amount has been on the view all along and the
-- screen has been labelling it "flat fee" or "N h x rate" from the rate type,
-- which was a guess that happened to be right until an invoice disagreed with
-- it. Now the view says.
--
-- Appended rather than inserted: a view cannot be replaced with its columns in
-- a different order, and nothing about the order matters to the screens.
--
-- `has_months` comes with them, because a coaching authorization is not
-- delivered - its months are - and a screen should not offer a control the
-- database is going to refuse.

begin;

create or replace view public.authorization_record as
 SELECT a.id,
    a.client_id,
    c.name AS client_name,
    c.client_no,
    a.parent_id,
    p.number AS parent_number,
    COALESCE(NULLIF(a.number, ''::text), p.number, ''::text) AS number,
    a.is_placeholder,
    a.service_type,
    a.funding_source,
    a.period,
    a.status,
    a.rate_type,
    a.rate,
    a.total_hours,
    COALESCE(pp.total_hours, a.total_hours) AS authorized_hours,
    a.carried_used,
    a.start_date,
    a.end_date,
    a.service_start,
    a.service_end,
    a.first_work_day,
    a.received_on,
    a.bill_by,
    a.stale_date,
    a.stale_reason,
    a.submitted_on,
    a.submitted_by,
    sb.name AS submitted_by_name,
    a.recipient,
    a.paid_on,
    a.paid_amount,
    a.warrant,
    a.correction_note,
    a.followup_due,
    a.closed_reason,
    a.closed_at,
    a.note,
    a.zero_hours_confirmed_at,
    k.name AS counselor_name,
    k.email AS counselor_email,
    bo.billing_office_id,
    bo.billing_office AS billing_office_name,
    b.billing_email AS billing_office_email,
    authorization_amount(a.id) AS amount,
    COALESCE(( SELECT sum(e.hours) AS sum
           FROM service_entries e
          WHERE e.auth_id = a.id AND NOT e.non_billable), 0::numeric) AS hours_logged,
    COALESCE(( SELECT sum(e.hours) AS sum
           FROM service_entries e
             JOIN authorizations ch ON ch.id = e.auth_id
          WHERE NOT e.non_billable AND (ch.id = COALESCE(a.parent_id, a.id) OR ch.parent_id = COALESCE(a.parent_id, a.id))), 0::numeric) AS hours_on_the_authorization,
    authorization_can_submit(a.id) AS can_submit,
    authorization_gate_met(a.id) AS gate_met,
    authorization_missing_forms(a.id) AS missing_forms,
    t.attention,
    t.urgency,
    a.delivered_on,
    sd.name AS delivered_by_name,
    authorization_amount_basis(a.id) AS amount_basis,
    (EXISTS ( SELECT 1
           FROM authorizations ch
          WHERE ch.parent_id = a.id)) AS has_months
   FROM authorizations a
     JOIN clients c ON c.id = a.client_id
     LEFT JOIN authorizations p ON p.id = a.parent_id
     LEFT JOIN authorizations pp ON pp.id = a.parent_id
     LEFT JOIN counselors k ON k.id = c.counselor_id
     LEFT JOIN client_billing_office bo ON bo.client_id = c.id
     LEFT JOIN billing_offices b ON b.id = bo.billing_office_id
     LEFT JOIN staff sb ON sb.id = a.submitted_by
     LEFT JOIN staff sd ON sd.id = a.delivered_by
     CROSS JOIN LATERAL authorization_attention(a.id) t(attention, urgency);

commit;
