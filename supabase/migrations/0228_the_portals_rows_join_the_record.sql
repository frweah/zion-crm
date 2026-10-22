-- Zion Vocational Rehab CRM — 0228 the portal's rows join the record
--
-- Two gaps the portal merge left, both found by checks that already existed
-- and both about the same three tables.
--
-- **A records request has to be everything.** portal_requests holds what the
-- practice asked a client for and what they said back; portal_resumes holds a
-- resume the client wrote. Both are the client's own words about themselves,
-- and neither was in the bundle - so a client asking for their file would
-- have been handed one with those pages missing. verify_records_request
-- counts tables that hold client data and appear in no section, which is
-- exactly the check for this, and it was right.
--
-- **And the deploy check's account must not be able to write them.** The
-- system account (0120) opens every screen on every deploy and is refused
-- every write by a policy on each table. Three portal tables had been added
-- without one.
--
-- The bundle below is the live definition with one section added and nothing
-- else touched.

CREATE OR REPLACE FUNCTION public.records_request_bundle(p_client uuid, p_purpose text DEFAULT 'Records request'::text)
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
      ))
    || jsonb_build_object(
      -- What the client asked for and was asked for, in their own portal,
      -- and the resume they built there. Both hold the client's own words,
      -- so both belong in a records request (0228).
      'portal_requests', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'asked_for', r.item,
                 'label', nullif(r.label, ''),
                 'note', nullif(r.note, ''),
                 'due', r.due,
                 'status', r.status,
                 'sent_back_because', nullif(r.return_reason, ''),
                 'asked_by', nullif(r.requested_by_name, ''),
                 'asked_at', r.created_at,
                 'answered_at', r.answered_at,
                 'reviewed_at', r.reviewed_at
               ) order by r.created_at), '[]'::jsonb)
          from public.portal_requests r where r.client_id = p_client
      ),
      'portal_resume', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'status', s.status,
                 'step', s.step,
                 'sent_back_because', nullif(s.return_note, ''),
                 'submitted_at', s.submitted_at,
                 'reviewed_at', s.reviewed_at,
                 'started_at', s.created_at,
                 'content', s.data
               ) order by s.created_at), '[]'::jsonb)
          from public.portal_resumes s where s.client_id = p_client
      ));
end;
$function$;

-- The system account reads and never writes, on these three as on the rest.
select public.apply_system_read_only('portal_notices');
select public.apply_system_read_only('portal_requests');
select public.apply_system_read_only('portal_resumes');
