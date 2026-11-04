 WITH required AS (
         SELECT s.id AS staff_id,
            t.key AS type_key,
            t.label,
            t.kind,
            t.expires,
            t.warn_days,
            t.hours_target,
            t.applies_to,
            t.sort_order,
            t.applies_to = 'everyone'::text OR COALESCE(e.transports_clients, false) AS required
           FROM staff s
             CROSS JOIN credential_types t
             LEFT JOIN staff_employment e ON e.staff_id = s.id
          WHERE s.active AND t.active
        ), latest AS (
         SELECT DISTINCT ON (c_1.staff_id, c_1.type_key) c_1.staff_id,
            c_1.type_key,
            c_1.id AS credential_id,
            c_1.issued_on,
            c_1.expires_on,
            c_1.reference,
            c_1.file_id,
            c_1.verified_at,
            c_1.verified_by
           FROM staff_credentials c_1
          ORDER BY c_1.staff_id, c_1.type_key, c_1.expires_on DESC, c_1.created_at DESC
        ), ce AS (
         SELECT ce_entries.staff_id,
            sum(ce_entries.hours) FILTER (WHERE ce_entries.on_date >= date_trunc('year'::text, practice_today()::timestamp with time zone)::date) AS hours_this_year,
            max(ce_entries.on_date) AS last_entry_on
           FROM ce_entries
          GROUP BY ce_entries.staff_id
        )
 SELECT r.staff_id,
    r.type_key,
    r.label,
    r.kind,
    r.required,
    r.sort_order,
    l.credential_id,
    l.reference,
    l.issued_on,
    l.expires_on,
    l.file_id,
    l.verified_at,
    COALESCE(c.hours_this_year, 0::numeric) AS hours_this_year,
    r.hours_target,
    c.last_entry_on,
        CASE
            WHEN r.kind = 'hours'::text THEN
            CASE
                WHEN NOT r.required THEN 'Not required'::text
                WHEN COALESCE(c.hours_this_year, 0::numeric) >= COALESCE(r.hours_target, 0::numeric) THEN 'Met'::text
                ELSE 'Outstanding'::text
            END
            WHEN l.credential_id IS NULL THEN
            CASE
                WHEN r.required THEN 'Missing'::text
                ELSE 'Not held'::text
            END
            WHEN r.expires AND l.expires_on IS NOT NULL AND l.expires_on < practice_today() THEN 'Expired'::text
            WHEN l.verified_at IS NULL THEN 'Awaiting check'::text
            WHEN NOT r.expires OR l.expires_on IS NULL THEN 'Valid'::text
            WHEN l.expires_on <= (practice_today() + r.warn_days) THEN 'Expiring'::text
            ELSE 'Valid'::text
        END AS state,
        CASE
            WHEN l.expires_on IS NULL THEN NULL::integer
            ELSE l.expires_on - practice_today()
        END AS days_left
   FROM required r
     LEFT JOIN latest l ON l.staff_id = r.staff_id AND l.type_key = r.type_key
     LEFT JOIN ce c ON c.staff_id = r.staff_id AND r.kind = 'hours'::text
  WHERE r.required OR l.credential_id IS NOT NULL;