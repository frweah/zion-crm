-- Zion Vocational Rehab CRM — the records request follows the record
-- (Billing Simplification Brief §§10, 11)
--
-- A records request is a legal disclosure: whatever the practice holds about a
-- person goes in the bundle. It had two billing sections, and §10 removed what
-- both of them read.
--
--   'invoices' dumped every invoice row. It is gone, and nothing is lost: the
--   bundle's 'authorizations' section already dumps the whole authorization,
--   and the authorization is where the submission, the payment, the warrant and
--   the amount now live. Keeping a second section over the same rows would be
--   the duplication §11 is about, in the one place where a duplicate is most
--   likely to be read as a second charge.
--
--   'billing' read billing_items and billing_item_events. It reads the
--   authorization and authorization_events instead - the same shape, from the
--   record that holds it, so what a client or their counsel receives is what
--   the practice actually has.
--
-- Both are the live definitions with those sections replaced, so nothing else
-- in the bundle moves.

create or replace function public.records_request_bundle_before_billing(p_client uuid, p_purpose text DEFAULT 'Records request'::text)
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
      select coalesce(jsonb_agg(to_jsonb(m) - 'id' order by m.created_at), '[]'::jsonb)
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
$function$;

create or replace function public.records_request_bundle(p_client uuid, p_purpose text DEFAULT 'Records request'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_bundle jsonb;
begin
  v_bundle := public.records_request_bundle_before_billing(p_client, p_purpose);

  return v_bundle
    || jsonb_build_object(
      'billing', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'authorization', coalesce(nullif(x.number, ''), p.number),
                 'service', x.service_type,
                 'period', x.period,
                 'status', x.status,
                 'service_start', x.service_start,
                 'service_end', x.service_end,
                 'first_work_day', x.first_work_day,
                 'hours', (select coalesce(sum(e.hours), 0) from public.service_entries e
                            where e.auth_id = x.id and not e.non_billable),
                 'rate', x.rate,
                 'amount', public.authorization_amount(x.id),
                 'sent_on', x.submitted_on,
                 'sent_to', x.recipient,
                 'paid_on', x.paid_on,
                 'paid_amount', x.paid_amount,
                 'warrant', x.warrant,
                 'closed_reason', x.closed_reason,
                 'history', (
                   select coalesce(jsonb_agg(jsonb_build_object(
                            'at', ev.at, 'was', ev.was, 'became', ev.became,
                            'note', ev.note, 'by', ev.staff_name) order by ev.at), '[]'::jsonb)
                     from public.authorization_events ev where ev.auth_id = x.id
                 )
               ) order by x.period nulls last, x.service_type), '[]'::jsonb)
          from public.authorizations x
          left join public.authorizations p on p.id = x.parent_id
         where x.client_id = p_client
      ))
    || jsonb_build_object(
      'practice_forms', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'form', f.name,
                 'filled_at', e.filled_at,
                 'by', e.staff_name,
                 'answers', e.answers,
                 'has_photograph', e.attachment_path is not null
               ) order by e.filled_at), '[]'::jsonb)
          from public.practice_form_entries e
          join public.practice_forms f on f.key = e.form_key
         where e.client_id = p_client
      ))
    || jsonb_build_object(
      'books', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'date', j.entry_date,
                 'what_it_was', j.memo,
                 'account', c.name,
                 'service', nullif(l.service, ''),
                 'amount', case when l.debit > 0 then l.debit else l.credit end,
                 'from', j.source_kind
               ) order by j.entry_date, j.created_at), '[]'::jsonb)
          from public.journal_lines l
          join public.journals j on j.id = l.journal_id
          join public.ledger_accounts c on c.id = l.account_id
         where l.client_id = p_client
      ));
end;
$function$;
