-- Zion Vocational Rehab CRM — the ledger joins a records request (0145)
--
-- journal_lines carries a client_id, so verify_records_request refused the
-- ledger the moment it existed: a table that holds client data and is in no
-- section of the bundle is a table somebody forgot.
--
-- It was not forgotten, and the answer is to include it rather than to add a
-- reason to a skipped list. The same argument settled updates.text in 0137: a
-- privacy rule with a list of exceptions is one somebody will add to without
-- thinking, and a records request with a list of what it leaves out is the
-- same shape of mistake. If a posting names a person, that posting is part of
-- what the practice holds about them.
--
-- What goes in is what a person would recognise: the day, what it was for,
-- the account in words, and the amount. Not debits and credits - a request
-- for one's records is answered in sentences, not in bookkeeping.

create or replace function public.records_request_bundle(
  p_client uuid,
  p_purpose text default 'Records request'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $function$
declare
  v_bundle jsonb;
begin
  v_bundle := public.records_request_bundle_before_billing(p_client, p_purpose);

  return v_bundle
    || jsonb_build_object(
      'billing', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'service', i.service,
                 'period', i.period,
                 'status', i.status,
                 'service_start', i.service_start,
                 'service_end', i.service_end,
                 'first_work_day', i.first_work_day,
                 'authorization', a.number,
                 'hours', i.hours,
                 'rate', i.rate,
                 'amount', coalesce(i.amount, i.hours * i.rate),
                 'sent_on', i.submitted_at,
                 'sent_to', i.recipient,
                 'paid_on', i.paid_on,
                 'paid_amount', i.paid_amount,
                 'warrant', i.warrant,
                 'closed_reason', i.closed_reason,
                 'history', (
                   select coalesce(jsonb_agg(jsonb_build_object(
                            'at', e.at, 'was', e.was, 'became', e.became,
                            'note', e.note, 'by', e.staff_name) order by e.at), '[]'::jsonb)
                     from public.billing_item_events e where e.item_id = i.id
                 )
               ) order by i.period nulls last, i.service), '[]'::jsonb)
          from public.billing_items i
          left join public.authorizations a on a.id = i.auth_id
         where i.client_id = p_client
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

revoke execute on function public.records_request_bundle(uuid, text) from public, anon;
grant execute on function public.records_request_bundle(uuid, text) to authenticated;

comment on function public.records_request_bundle is
  'Everything the practice holds about one person, the ledger postings that name them included (0145).';
