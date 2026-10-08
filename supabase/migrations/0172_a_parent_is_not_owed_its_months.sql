-- Zion Vocational Rehab CRM — a coaching parent is not still owed what its
-- months have earned
-- (Billing Simplification Brief §§5, 11)
--
-- 0171 moved coaching hours onto the month they were worked, which is where the
-- bill is. That left one figure wrong, and it is the one on the dashboard:
--
--   committed - "authorized, not yet earned" - is the authorized value less
--   what has been earned, and it counted earnings on the authorization's own
--   row. A coaching parent has none now: they are on its months. So a
--   twenty-hour coaching authorization with every hour worked and billed still
--   read as 900 of work still to do.
--
-- hours_left had the same shape of fault, and for the same reason: an
-- authorization whose hours were all worked read as having every one of them
-- still available.
--
-- Nothing else in the view moves. earned, invoiced, received and unbilled stay
-- on the months, which is what makes a sum over every row count each of them
-- once; committed and hours_left are about the authorization as a whole, so
-- they reach down to the months it is made of.
--
-- This is the live definition with that one subtraction widened.

create or replace view public.authorization_economics as
 WITH used AS (
         SELECT a_1.id,
            COALESCE(a_1.carried_used, 0::numeric) + COALESCE(( SELECT sum(se.hours) AS sum
                   FROM service_entries se
                  WHERE se.auth_id = a_1.id AND NOT se.non_billable), 0::numeric) AS hours_used,
            ( SELECT min(se.date) AS min
                   FROM service_entries se
                  WHERE se.auth_id = a_1.id) AS first_entry_on,
            ( SELECT max(se.date) AS max
                   FROM service_entries se
                  WHERE se.auth_id = a_1.id) AS last_entry_on,
            ( SELECT count(*) AS count
                   FROM service_entries se
                  WHERE se.auth_id = a_1.id) AS entry_count
           FROM authorizations a_1
        ), billed AS (
         SELECT a_1.id,
                CASE
                    WHEN a_1.status = ANY (ARRAY['Submitted'::text, 'Paid'::text]) THEN authorization_amount(a_1.id)
                    ELSE 0::numeric
                END AS invoiced,
            COALESCE(a_1.paid_amount, 0::numeric) AS received,
                CASE
                    WHEN a_1.status = 'Submitted'::text THEN authorization_amount(a_1.id)
                    ELSE 0::numeric
                END AS outstanding,
            a_1.submitted_on AS last_invoice_on
           FROM authorizations a_1
        ), done AS (
         SELECT a_1.id,
            ( SELECT max(c.completion) AS max
                   FROM completions c
                  WHERE c.auth_id = a_1.id AND c.completion IS NOT NULL) AS completed_on
           FROM authorizations a_1
        )
 SELECT a.id AS auth_id,
    a.client_id,
    a.number AS auth_number,
    a.service_type,
    a.funding_source,
    a.status,
    a.rate_type,
    a.rate,
    a.total_hours,
    a.start_date,
    a.end_date,
    u.hours_used,
        CASE
            WHEN a.total_hours IS NULL THEN NULL::numeric
            -- A coaching parent's hours are logged on its months (0171), so
            -- how many are left has to count them. Without this, an
            -- authorization whose hours are all used reads as having them all.
            ELSE GREATEST(a.total_hours - (u.hours_used + COALESCE((
                SELECT sum(e.hours)
                  FROM service_entries e
                  JOIN authorizations ch ON ch.id = e.auth_id
                 WHERE ch.parent_id = a.id AND NOT e.non_billable), 0::numeric)), 0::numeric)
        END AS hours_left,
    u.first_entry_on,
    u.last_entry_on,
    u.entry_count,
    d.completed_on,
        CASE
            WHEN a.rate_type = 'Hourly'::text THEN COALESCE(a.total_hours, 0::numeric) * a.rate
            ELSE a.rate
        END AS authorized,
        CASE
            WHEN a.rate_type = 'Hourly'::text THEN u.hours_used * a.rate
            WHEN d.completed_on IS NOT NULL THEN a.rate
            ELSE 0::numeric
        END AS earned,
    b.invoiced,
    b.received,
    b.outstanding,
    b.last_invoice_on,
        CASE
            WHEN a.status <> ALL (ARRAY['Authorized'::text, 'Due'::text, 'Submitted'::text]) THEN 0::numeric
            ELSE GREATEST(
            CASE
                WHEN a.rate_type = 'Hourly'::text THEN u.hours_used * a.rate
                WHEN d.completed_on IS NOT NULL THEN a.rate
                ELSE 0::numeric
            END - b.invoiced, 0::numeric)
        END AS unbilled,
        CASE
            WHEN a.status <> ALL (ARRAY['Authorized'::text, 'Due'::text, 'Submitted'::text]) THEN 0::numeric
            ELSE GREATEST(
            CASE
                WHEN a.rate_type = 'Hourly'::text THEN COALESCE(a.total_hours, 0::numeric) * a.rate
                ELSE a.rate
            END -
            (CASE
                WHEN a.rate_type = 'Hourly'::text THEN u.hours_used * a.rate
                WHEN d.completed_on IS NOT NULL THEN a.rate
                ELSE 0::numeric
            END
            -- A coaching parent's hours live on its months (0171). What those
            -- months have earned is earned against this authorization, so it
            -- is not still committed.
            + COALESCE((
                SELECT sum(e.hours)
                  FROM service_entries e
                  JOIN authorizations ch ON ch.id = e.auth_id
                 WHERE ch.parent_id = a.id AND NOT e.non_billable), 0::numeric)
              * COALESCE(a.rate, 0::numeric)), 0::numeric)
        END AS committed
   FROM authorizations a
     JOIN used u ON u.id = a.id
     JOIN billed b ON b.id = a.id
     JOIN done d ON d.id = a.id;

alter view public.authorization_economics set (security_invoker = true);
grant select on public.authorization_economics to authenticated;
