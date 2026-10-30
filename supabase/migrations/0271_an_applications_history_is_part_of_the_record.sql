-- An application's history is part of the record
--
-- 0270 moved where an application got to out of `lead_matches.status` and
-- into `job_status_history`, and a records request asks for everything on
-- file about a person. The bundle disclosed the application row and would have
-- disclosed none of its nine statuses, so "applied on the 12th, employer rang
-- on the 20th, declined on the 3rd" would have been missing from the answer to
-- a legal request.
--
-- verify_records_request.sql could not have caught this. It walks the tables
-- carrying a `client_id` and asks whether each is in the bundle or on the
-- written list of exclusions, and `job_status_history` carries none - the
-- client is reached through the application, the same way `service_entries`
-- is reached through its authorization. Both of those are disclosed inside
-- their parent's section, which is what this does.
--
-- The function below is the live definition with that one section replaced.
-- Dumped rather than taken from 0166 or 0228, because the database drifts from
-- the migrations and replacing a function from an old file is how whatever was
-- added since gets quietly dropped.

CREATE OR REPLACE FUNCTION public.records_request_bundle_before_billing(p_client uuid, p_purpose text DEFAULT 'Records request'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'vault', 'extensions'
AS $function$
declare
  v_out    jsonb;
  v_client jsonb;
begin
  if not public.is_admin() then
    raise exception 'Only Admin produces a records request.'
      using errcode = 'insufficient_privilege';
  end if;

  select to_jsonb(c) - 'legacy_id' - 'ghl_id' - 'import_review'
    into v_client
    from public.clients c where c.id = p_client;

  if v_client is null then
    raise exception 'That client does not exist.' using errcode = 'no_data_found';
  end if;

  perform public.log_access('Records request', p_client, null, p_purpose);

  select jsonb_build_object(
    'produced_at', now(),
    'client', v_client,

    'restricted_details', (
      select to_jsonb(p) from public.client_private p where p.client_id = p_client
    ),

    'intake', (
      select to_jsonb(i) - 'id' from public.intakes i where i.client_id = p_client
    ),

    'stage_history', (
      select coalesce(jsonb_agg(to_jsonb(h) - 'id' order by h.at), '[]'::jsonb)
        from public.client_stage_history h where h.client_id = p_client
    ),

    'notes', (
      select coalesce(jsonb_agg(to_jsonb(n) - 'id' - 'legacy_id' order by n.ts), '[]'::jsonb)
        from public.notes n where n.client_id = p_client
    ),

    'counselor_contacts', (
      select coalesce(jsonb_agg(to_jsonb(cl) - 'id' - 'legacy_id' order by cl.date), '[]'::jsonb)
        from public.contact_log cl where cl.client_id = p_client
    ),

    'tasks', (
      select coalesce(jsonb_agg(to_jsonb(t) - 'id' - 'legacy_id' order by t.created_at), '[]'::jsonb)
        from public.tasks t where t.client_id = p_client
    ),

    'authorizations', (
      select coalesce(jsonb_agg(to_jsonb(a) - 'legacy_id' order by a.start_date), '[]'::jsonb)
        from public.authorizations a where a.client_id = p_client
    ),

    'service_hours', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'worked_on', w.worked_on, 'hours', w.hours,
               'description', w.description, 'category', w.category,
               'voided', w.voided) order by w.worked_on), '[]'::jsonb)
        from public.work_sessions w where w.client_id = p_client
    ),

    'forms', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'template_id', f.template_id, 'month', f.month, 'status', f.status,
               'completed_at', f.completed_at, 'sent_at', f.sent_at, 'sent_to', f.sent_to,
               'data', f.data) order by f.created_at), '[]'::jsonb)
        from public.forms f where f.client_id = p_client
    ),

    'placements', (
      select coalesce(jsonb_agg(to_jsonb(pl) - 'id' - 'legacy_id' order by pl.start_date), '[]'::jsonb)
        from public.placements pl where pl.client_id = p_client
    ),

    'jobs_applied_for', (
      select coalesce(jsonb_agg(
               (to_jsonb(m) - 'id')
               || jsonb_build_object('statuses', (
                    select coalesce(jsonb_agg(jsonb_build_object(
                             'status', h.status,
                             'at', h.at,
                             'note', h.note,
                             'reported_by', h.reported_by_name,
                             'recorded_by_a_rule', h.automatic
                           ) order by h.at, h.created_at), '[]'::jsonb)
                      from public.job_status_history h where h.match_id = m.id
                  ))
               order by m.created_at), '[]'::jsonb)
        from public.lead_matches m where m.client_id = p_client
    ),

    'appointments', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'kind', e.kind, 'title', e.title, 'starts_at', e.starts_at,
               'ends_at', e.ends_at, 'location', e.location, 'note', e.note)
               order by e.starts_at), '[]'::jsonb)
        from public.calendar_events e where e.client_id = p_client
    ),

    'texts', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'direction', m.direction, 'phone', m.phone, 'body', m.body,
               'kind', m.kind, 'status', m.status,
               'at', coalesce(m.sent_at, m.created_at)) order by m.created_at), '[]'::jsonb)
        from public.sms_messages m where m.client_id = p_client
    ),

    'texting_consent', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'state', ev.state, 'method', ev.method, 'note', ev.note, 'at', ev.at)
               order by ev.seq), '[]'::jsonb)
        from public.sms_consent_events ev where ev.client_id = p_client
    ),

    'email', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'subject', ml.subject, 'direction', ml.direction,
               'counterpart', ml.counterpart_email, 'sent_at', ml.sent_at)
               order by ml.sent_at), '[]'::jsonb)
        from public.mail_log ml where ml.client_id = p_client
    ),

    -- Conversations about the client (0104): texts, web chats and staff
    -- threads about them, every message, removed ones as the marker they left.
    'conversations', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'kind', cv.kind, 'title', cv.title, 'started', cv.created_at,
               'messages', (select coalesce(jsonb_agg(jsonb_build_object(
                                 'from', case msg.sender_kind when 'staff' then msg.sender_label else msg.sender_kind end,
                                 'at', msg.created_at,
                                 'text', case when msg.removed_at is null then msg.body else '(message removed)' end)
                               order by msg.seq), '[]'::jsonb)
                          from public.messages msg where msg.conversation_id = cv.id))
               order by cv.created_at), '[]'::jsonb)
        from public.conversations cv where cv.client_id = p_client
    ),

    'files', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'filename', at2.filename, 'category', at2.category,
               'note', at2.note, 'size_bytes', at2.size_bytes,
               'restricted', at2.restricted, 'added', at2.created_at)
               order by at2.created_at), '[]'::jsonb)
        from public.attachments at2 where at2.client_id = p_client
    ),

    'who_read_this_record', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'at', l.at, 'who', l.staff_name, 'role', l.staff_role,
               'what', l.subject, 'why', l.purpose) order by l.at), '[]'::jsonb)
        from public.access_log l where l.client_id = p_client
    ),

    -- Who can sign in to the portal for this person, including guardians.
    'portal_access', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'kind', pa.kind, 'name', pa.name, 'relationship', pa.relationship,
               'phone', pa.phone, 'email', pa.email,
               'given_by', pa.invited_by_name, 'given_at', pa.invited_at,
               'first_signed_in_at', pa.first_signed_in_at, 'last_signed_in_at', pa.last_signed_in_at,
               'turned_off_at', pa.disabled_at, 'turned_off_because', pa.disabled_reason)
               order by pa.invited_at), '[]'::jsonb)
        from public.portal_accounts pa where pa.client_id = p_client
    ),

    -- Every consent choice, in the order made, with what it was made against.
    'portal_consent', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'kind', pc.kind, 'given', pc.given, 'at', pc.at,
               'terms_version', pc.terms_version, 'by', pc.actor_name,
               'acting_as', pc.acting_as, 'ip', pc.ip, 'browser', pc.user_agent)
               order by pc.seq), '[]'::jsonb)
        from public.portal_consents pc where pc.client_id = p_client
    ),

    'portal_activity', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'at', pv.at, 'what', pv.action, 'detail', pv.detail,
               'by', pv.actor_name, 'acting_as', pv.acting_as)
               order by pv.seq), '[]'::jsonb)
        from public.portal_activity pv where pv.client_id = p_client
    )
  ) into v_out;

  return v_out;
end;
$function$
