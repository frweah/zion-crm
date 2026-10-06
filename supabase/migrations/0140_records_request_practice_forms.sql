-- Zion Vocational Rehab CRM — a client's filled forms are part of their record
--
-- A visit written up, a worksite check, an incident: these are about the
-- client, kept against the client, and read by whoever opens their record. So
-- when the client asks what is held about them, they are in the answer.
--
-- The check that refuses any table carrying a client_id and sitting in no
-- section of the bundle (0070) said so the first time it ran, which is what
-- it is for.

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
      ));
end;
$function$;

revoke execute on function public.records_request_bundle(uuid, text) from public, anon;
grant execute on function public.records_request_bundle(uuid, text) to authenticated;
