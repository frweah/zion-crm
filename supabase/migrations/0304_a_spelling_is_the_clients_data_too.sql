-- Zion Vocational Rehab CRM — a spelling is the client's data too
--
-- Three checks fired the moment client_aliases existed, and all three were
-- right:
--
--   verify_records_request: a table holding a client_id must be in the bundle
--   a records request is answered with, or on the written list of exclusions.
--   The other spellings of somebody's own name are their data, so they go in
--   the bundle rather than on the list.
--
--   verify_system_account: a table the system account can write to is a table
--   the system account can forge. apply_system_read_only closes it.
--
--   verify_time_clock failed as well, and it is not this - see the report.
--
-- The bundle function is replaced from what the database actually had rather
-- than from the migration that last defined it, because the two drift and the
-- database is the one answering records requests.

begin;

CREATE OR REPLACE FUNCTION public.records_request_bundle(p_client uuid, p_purpose text DEFAULT 'Records request'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_bundle jsonb;
begin
  v_bundle := public.records_request_bundle_before_reports(p_client, p_purpose);

  return v_bundle
    || jsonb_build_object(
      /*
       * The other spellings of their own name (0303).
       *
       * A client's name as somebody else writes it is the client's data. The
       * practice holds these so a warrant or an invoice under one spelling
       * finds the record, and a records request that left them out would be
       * answered with less than the practice holds. Where each spelling was
       * seen is included, because that is the part that explains why it is
       * on file at all.
       */
      'other_spellings', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'spelling', a.name,
                 'seen_on', a.source,
                 'why', nullif(a.note, ''),
                 'added_by', nullif(a.added_by_name, ''),
                 'added_at', a.at
               ) order by a.name), '[]'::jsonb)
          from public.client_aliases a where a.client_id = p_client
      ),
      'weekly_reports', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'week_from', w.week_start,
                 'week_to', w.week_start + 6,
                 'status', w.status,
                 'kept_by', (select nullif(s.name, '') from public.staff s where s.id = w.owner_id),
                 'confirmed_by', (select nullif(s.name, '') from public.staff s where s.id = w.confirmed_by),
                 'confirmed_at', w.confirmed_at,
                 'what_staff_wrote', nullif(w.note, ''),
                 'what_the_record_showed', w.content
               ) order by w.week_start), '[]'::jsonb)
          from public.client_weekly_reports w where w.client_id = p_client
      ),
      'reports', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'report', m.template,
                 'period', m.period,
                 'status', m.status,
                 'due_on', m.due_on,
                 'kept_by', (select nullif(s.name, '') from public.staff s where s.id = m.owner_id),
                 'signed_by', (select nullif(s.name, '') from public.staff s where s.id = m.signed_by),
                 'signed_at', m.signed_at,
                 'sent_at', m.sent_at,
                 'sent_to', nullif(m.sent_to, ''),
                 'reopened_because', nullif(m.reopen_reason, ''),
                 'what_staff_wrote', nullif(m.note, ''),
                 'what_the_record_showed', m.content,
                 'document', (select a.filename from public.attachments a
                               where a.id = m.pdf_attachment_id)
               ) order by m.period, m.template), '[]'::jsonb)
          from public.client_reports m where m.client_id = p_client
      ));
end;
$function$;

select public.apply_system_read_only('client_aliases');

commit;
