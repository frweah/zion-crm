-- Zion Vocational Rehab CRM — 0263 the reports are part of the record
--
-- A client asking for everything the practice holds about them gets a bundle
-- (0070), and `supabase/verify_records_request.sql` fails if any table
-- carrying a `client_id` is in neither the bundle nor a written list of
-- exclusions. 0260 added two, and this is the answer to that question rather
-- than a way round it.
--
-- Both are in. The monthly report is the document the practice signs and
-- sends to the counselor about this person, which is about as squarely inside
-- "what you hold about me" as a record gets. The weekly one is less obvious
-- and still in: most of its lines are already disclosed through their own
-- sections - the hours under service hours, the notes under notes - but the
-- week's own sentence, written by the person who did the work, is nowhere
-- else. The `staff_day_lines` exclusion turns on the filed copy already being
-- in the bundle; here there is no other copy, so the same reasoning puts this
-- one in.
--
-- Added the way 0126 added billing: the function is renamed to what it was,
-- and a new one calls it and appends. Reproducing the whole body to add two
-- sections is how a section goes missing, and the body is long.

alter function public.records_request_bundle(uuid, text)
  rename to records_request_bundle_before_reports;

revoke execute on function public.records_request_bundle_before_reports(uuid, text)
  from public, anon, authenticated;

create or replace function public.records_request_bundle(
  p_client uuid,
  p_purpose text default 'Records request'
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_bundle jsonb;
begin
  v_bundle := public.records_request_bundle_before_reports(p_client, p_purpose);

  return v_bundle
    || jsonb_build_object(
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
      'monthly_reports', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'month', m.month,
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
               ) order by m.month), '[]'::jsonb)
          from public.client_monthly_reports m where m.client_id = p_client
      ));
end;
$$;

-- The same grants the function had before the rename: Admin and the request
-- screen call it as the signed-in person, and nobody else reaches it.
revoke execute on function public.records_request_bundle(uuid, text) from public, anon;
grant execute on function public.records_request_bundle(uuid, text) to authenticated;

comment on function public.records_request_bundle(uuid, text) is
  'Everything the practice holds about one client, as sections named for people rather than tables. The weekly and monthly reports were added in 0263.';
