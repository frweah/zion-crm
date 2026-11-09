-- Zion Vocational Rehab CRM - a parent is not a bill, and Money says where
-- its figures came from
--
-- The two things the verify suite found within the minute of 0325 landing,
-- both of them right.
--
-- A coaching parent is not a bill (section 5). The new amount gives an hourly
-- row with nothing logged what its authorization allows, which is the right
-- answer for a coaching month and the wrong one for the authorization above
-- it: a parent that came to nothing now came to its whole ceiling, and that
-- ceiling is already counted on the months. Nothing on a screen showed it,
-- because the working list leaves parents out - but authorization_amount is
-- read in ten places, and this is exactly how a total comes to be counted
-- twice. So a row with months comes to nothing, and says so.
--
-- And Money says where a figure came from. The reason is in the view below,
-- beside the lines it explains.

begin;

CREATE OR REPLACE FUNCTION public.authorization_amount_for(p_auths uuid[])
 RETURNS TABLE(auth_id uuid, amount numeric, basis text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  with invoiced as (
    -- Every claim raised against it. USOR takes one authorization as several
    -- claims often enough - V1002111 went out as four - and what the practice
    -- billed is all of them, not the last one.
    select i.auth_id, sum(i.amount) as amount
      from public.invoices i
     where i.auth_id = any(p_auths) and i.amount is not null
     group by i.auth_id
  ),
  logged as (
    select e.auth_id, sum(e.hours) as hours
      from public.service_entries e
     where e.auth_id = any(p_auths)
       and e.non_billable = false
     group by e.auth_id
  ),
  months as (
    select ch.parent_id as auth_id
      from public.authorizations ch
     where ch.parent_id = any(p_auths)
     group by ch.parent_id
  )
  select a.id,
         case
           -- A coaching authorization is not a bill; its months are
           -- (section 5). The hours, the rate and the ceiling are all on this
           -- row and all of them are counted on the months, so anything other
           -- than nothing here is the same money twice.
           when m.auth_id is not null then 0
           when v.amount is not null then round(v.amount, 2)
           when l.hours is not null then round(l.hours * coalesce(a.rate, 0), 2)
           when a.rate_type = 'Flat Fee' then round(coalesce(a.rate, 0), 2)
           -- Nothing invoiced, nothing logged, and paid by the hour: what the
           -- authorization allows. It is the only figure there is, and
           -- `basis` says so rather than letting it pass as work done.
           --
           -- A coaching month has no hours of its own - the hours are on the
           -- authorization above it, drawn down month by month - so the
           -- ceiling is the parent's. It overstates a month where the
           -- authorization runs over several, which is why it is never shown
           -- without "no work logged yet" beside it. Reading 0.00 there was
           -- worse: it said a month was worth nothing.
           else round(coalesce(a.rate, 0) * coalesce(a.total_hours, p.total_hours, 0), 2)
         end,
         case
           when m.auth_id is not null then 'Not a bill'
           when v.amount is not null then 'Invoiced'
           when l.hours is not null then 'Logged'
           when a.rate_type = 'Flat Fee' then 'Flat fee'
           else 'Authorized'
         end
    from public.authorizations a
    left join public.authorizations p on p.id = a.parent_id
    left join invoiced v on v.auth_id = a.id
    left join logged l on l.auth_id = a.id
    left join months m on m.auth_id = a.id
   where a.id = any(p_auths);
$function$;

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
                    WHEN a_1.status = ANY (ARRAY['Submitted'::text, 'Paid'::text]) THEN m.amount
                    ELSE 0::numeric
                END AS invoiced,
                /*
                 * What was billed, and whether the figure is evidence of it
                 * (0325, 0329).
                 *
                 * This read "the amount, or the payment if the amount is
                 * zero", and zero was how an hourly row with no hours logged
                 * announced that it knew nothing. No service hours have ever
                 * been logged in this practice, so that was every hourly row.
                 *
                 * The amount now comes from the strongest evidence there is
                 * and says which, so the question is asked properly: a figure
                 * worked out from what an authorization merely allows is not
                 * what was billed, and where the state has paid, what it paid
                 * is the better evidence. Every settled row keeps the figure
                 * it had.
                 */
                CASE
                    WHEN a_1.status = ANY (ARRAY['Submitted'::text, 'Paid'::text, 'Closed'::text]) THEN
                    CASE
                        WHEN m.basis <> 'Authorized'::text THEN m.amount
                        WHEN COALESCE(a_1.paid_amount, 0::numeric) > 0::numeric THEN a_1.paid_amount
                        ELSE m.amount
                    END
                    ELSE 0::numeric
                END AS billed,
            (a_1.status = ANY (ARRAY['Submitted'::text, 'Paid'::text, 'Closed'::text])) AND m.basis = 'Authorized'::text AND COALESCE(a_1.paid_amount, 0::numeric) > 0::numeric AS billed_from_payment,
            COALESCE(a_1.paid_amount, 0::numeric) AS received,
                CASE
                    WHEN a_1.status = 'Submitted'::text THEN m.amount
                    ELSE 0::numeric
                END AS outstanding,
            a_1.submitted_on AS last_invoice_on
           FROM authorizations a_1
             CROSS JOIN LATERAL authorization_amount_for(ARRAY[a_1.id]) m(auth_id, amount, basis)
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
            ELSE GREATEST(a.total_hours - (u.hours_used + COALESCE(( SELECT sum(e.hours) AS sum
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
            END - (
            CASE
                WHEN a.rate_type = 'Hourly'::text THEN u.hours_used * a.rate
                WHEN d.completed_on IS NOT NULL THEN a.rate
                ELSE 0::numeric
            END + COALESCE(( SELECT sum(e.hours) AS sum
               FROM service_entries e
                 JOIN authorizations ch ON ch.id = e.auth_id
              WHERE ch.parent_id = a.id AND NOT e.non_billable), 0::numeric) * COALESCE(a.rate, 0::numeric)), 0::numeric)
        END AS committed,
    b.billed,
    b.billed_from_payment,
    (a.status <> ALL (ARRAY['Paid'::text, 'Closed'::text])) AND NOT (EXISTS ( SELECT 1
           FROM authorizations ch
          WHERE ch.parent_id = a.id)) AND (( SELECT c2.status
           FROM clients c2
          WHERE c2.id = a.client_id)) <> 'Closed'::text AS is_open
   FROM authorizations a
     JOIN used u ON u.id = a.id
     JOIN billed b ON b.id = a.id
     JOIN done d ON d.id = a.id;

commit;
