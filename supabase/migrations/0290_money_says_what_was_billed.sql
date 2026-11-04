-- Money says what was billed, and what is still open
--
-- Two faults on one screen, both found by reading the figures rather than the
-- code.
--
-- **"0 open authorizations."** The page filtered `status === "Open"`, and
-- `authorizations.status` has never held that word - it is Authorized, Due,
-- Submitted, Paid or Closed, and the constraint says so. So the filter matched
-- nothing, and everything built on it read zero: authorized-and-not-invoiced,
-- the committed and unbilled totals, and the open-authorizations table. Money
-- said none while Billing listed fourteen.
--
-- Fixed by having one definition rather than two. `billing_worklist` already
-- decided what open means, and it is not only the status: it also leaves out
-- the parent of a child authorization, and anything on a client who has
-- closed. 21 authorizations are not Paid or Closed; 15 of those are not
-- parents; 14 of those have an open client - which is Billing's fourteen,
-- exactly. A status test alone would have given Money a third number, so the
-- condition moves into the view both screens read.
--
-- **Paid above invoiced.** `invoiced` is computed as logged hours times the
-- rate. Not one hourly authorization that has ever been paid has a single
-- service entry against it - 38 of them, $31,747.50 - so the figure computed
-- to zero against real money. One flat fee was paid $250 with no rate ever
-- entered, and one closed authorization holds $900. Forty rows in all,
-- $32,897.50.
--
-- The hours are not invented. `billed` takes the computed amount where there
-- is one and the payment where there is not, and `billed_from_payment` says
-- which, so the screen can label the row rather than presenting a payment as
-- though the work had been logged. A closed authorization with a payment
-- counts, which it did not before.
--
-- `invoiced` is left exactly as it was. It is what the hours come to, which is
-- what `unbilled` and `not_yet_invoiced` are about, and the month-end export
-- reads it.

create or replace view public.authorization_economics
  with (security_invoker = true) as
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
                -- What the practice billed, as against what the hours log can
                -- account for (0290): the computed amount where there is one,
                -- the payment where there is not. `invoiced` above is left
                -- alone - it is what the hours come to, which is what
                -- `unbilled` and `not_yet_invoiced` are about.
                CASE
                    WHEN a_1.status = ANY (ARRAY['Submitted'::text, 'Paid'::text, 'Closed'::text]) THEN
                      CASE WHEN authorization_amount(a_1.id) > 0::numeric
                           THEN authorization_amount(a_1.id)
                           ELSE COALESCE(a_1.paid_amount, 0::numeric)
                      END
                    ELSE 0::numeric
                END AS billed,
                (a_1.status = ANY (ARRAY['Submitted'::text, 'Paid'::text, 'Closed'::text]))
                  AND authorization_amount(a_1.id) = 0::numeric
                  AND COALESCE(a_1.paid_amount, 0::numeric) > 0::numeric AS billed_from_payment,
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
    -- Open, in the one definition the practice has. Money filtered on
    -- status = 'Open', a value this column has never held, so its whole
    -- work-in-hand half read zero while Billing listed fourteen. These are
    -- `billing_worklist`'s own three conditions, in one place both screens
    -- read: not finished, not the parent of a child authorization, and not on
    -- a client who has closed (0290).
    a.status <> ALL (ARRAY['Paid'::text, 'Closed'::text])
      AND NOT (EXISTS (SELECT 1 FROM authorizations ch WHERE ch.parent_id = a.id))
      AND (SELECT c2.status FROM clients c2 WHERE c2.id = a.client_id) <> 'Closed'::text AS is_open
   FROM authorizations a
     JOIN used u ON u.id = a.id
     JOIN billed b ON b.id = a.id
     JOIN done d ON d.id = a.id;

revoke all on table public.authorization_economics from anon, authenticated;
grant select on table public.authorization_economics to authenticated;

-- billing_position carries them through: the Money page reads that for the
-- per-client table rather than the economics view directly.
create or replace view public.billing_position
  with (security_invoker = true) as
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
    COALESCE(p.n, 0::bigint) AS payments,
    e.billed,
    e.billed_from_payment,
    e.is_open
   FROM authorization_economics e
     JOIN clients c ON c.id = e.client_id
     JOIN authorizations a ON a.id = e.auth_id
     LEFT JOIN ( SELECT y.auth_id,
            count(*) AS n
           FROM payments y
          GROUP BY y.auth_id) p ON p.auth_id = e.auth_id;

revoke all on table public.billing_position from anon, authenticated;
grant select on table public.billing_position to authenticated;

-- ─────────────────────────────────────────────────────────────
-- Money and Billing count the same authorizations
--
-- The number is not asserted - it changes every time an authorization is
-- raised or paid. What is asserted is that the two screens agree, which is the
-- thing that was wrong.

do $$
declare
  v_money integer; v_billing integer;
  v_billed numeric; v_paid numeric; v_from_payment integer;
begin
  select count(*) into v_money from public.authorization_economics where is_open;
  select count(*) into v_billing from public.billing_worklist(public.practice_today());
  if v_money <> v_billing then
    raise exception 'Money counts % open authorization(s) and Billing counts %', v_money, v_billing;
  end if;
  raise notice 'ok  Money and Billing both count % open authorization(s)', v_money;

  select sum(billed), sum(received), count(*) filter (where billed_from_payment)
    into v_billed, v_paid, v_from_payment
    from public.authorization_economics;

  -- Billed can still sit below Paid - a payment larger than the hours logged
  -- is a real thing and the hours are not invented to cover it - but not by
  -- the rows this file is about: every one of those now takes its figure from
  -- the payment, so it cannot be short.
  if exists (
    select 1 from public.authorization_economics
     where billed_from_payment and billed <> received
  ) then
    raise exception 'a row billed from its payment does not match the payment';
  end if;

  raise notice 'ok  % row(s) take their billed figure from the payment; billed % against % paid',
    v_from_payment, v_billed, v_paid;
end $$;
