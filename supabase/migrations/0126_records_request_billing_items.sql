-- Zion Vocational Rehab CRM — a client's billing items are part of their record
--
-- The records-request bundle is what the practice hands over when a client
-- asks what is held about them, and its check refuses any table carrying a
-- client_id that is in no section of it (0070). billing_items carries one, so
-- it is in the bundle - under "billing", in the words a person would use, and
-- with the same detail as the authorizations and invoices beside it.
--
-- The history of each item comes too. A client asking what was billed in
-- their name is owed the answer to "and who changed it, and when".

-- The bundle as it stands keeps its body and takes a name that says what it
-- is: everything before billing items were part of the record. Renaming
-- rather than copying means the eighteen sections it already builds are not
-- transcribed here, where they could quietly drift from the original.
do $$
begin
  if to_regprocedure('public.records_request_bundle_before_billing(uuid, text)') is null then
    alter function public.records_request_bundle(uuid, text)
      rename to records_request_bundle_before_billing;
  end if;
end $$;

revoke execute on function public.records_request_bundle_before_billing(uuid, text) from public, anon, authenticated;

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

  return v_bundle || jsonb_build_object(
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
    )
  );
end;
$function$;

revoke execute on function public.records_request_bundle(uuid, text) from public, anon;
grant execute on function public.records_request_bundle(uuid, text) to authenticated;
