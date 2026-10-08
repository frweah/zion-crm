-- Zion Vocational Rehab CRM — one door (Billing Simplification Brief §10)
--
-- "Nothing creates a bill except entering an authorization."
--
-- Two functions still created one. Both were called from the client record
-- when a form packet is signed and sent:
--
--   draft_invoice_for_authorization() raised a Draft invoice. 0161 dropped it;
--   this migration is where the caller stops asking for it.
--
--   submit_item_for_form() opened or updated a billing_item. That table has
--   been frozen against writes since 0158, so this path has been failing since
--   §1 shipped - quietly, because the caller logs the error and tells the
--   person the packet went, which it had. The packet going is the important
--   half, and it is why the failure was survivable rather than visible.
--
-- What replaces them does not create anything. Sending a signed packet is a
-- submission, and a submission is a status on an authorization that already
-- exists. If the authorization is a monthly one, the month is found; if that
-- month's record is not open yet, it is opened, because a coaching month is
-- created by the calendar and not by billing (§5) - and a packet that has gone
-- out for a month nobody opened yet still has to land somewhere.
--
-- The submit gate runs on the status change, as it does everywhere else. If it
-- refuses, the caller is told the packet went but the record did not move:
-- recoverable, and silence would not be.

create or replace function public.submit_authorization_on_send(
  p_auth uuid, p_month text, p_recipient text, p_staff uuid)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  a       public.authorizations;
  rule    public.billing_service_rules;
  v_period date;
  v_target uuid;
begin
  select * into a from public.authorizations where id = p_auth;
  if not found then return null; end if;
  select * into rule from public.billing_service_rules where service = a.service_type;

  if coalesce(rule.recurrence, 'One-time') = 'Monthly' then
    v_period := date_trunc('month',
      coalesce(to_date(nullif(p_month, ''), 'YYYY-MM'), public.practice_today()))::date;

    -- The month under this authorization, opened if the calendar has not got
    -- to it yet.
    select id into v_target from public.authorizations
     where parent_id = coalesce(a.parent_id, a.id) and period = v_period;

    if v_target is null then
      insert into public.authorizations
        (client_id, number, service_type, funding_source, rate_type, rate,
         start_date, end_date, status, parent_id, period, requires_forms, note)
      select a.client_id, '', a.service_type, a.funding_source, a.rate_type, a.rate,
             a.start_date, a.end_date, 'Due', coalesce(a.parent_id, a.id), v_period,
             a.requires_forms,
             'Opened when the signed packet for ' || to_char(v_period, 'FMMonth YYYY') || ' was sent.'
        returning id into v_target;
    end if;
  else
    v_target := coalesce(a.parent_id, a.id);
  end if;

  -- Due first when it is still only Authorized: the flow does not skip a step
  -- just because the packet went out quickly.
  update public.authorizations set status = 'Due'
   where id = v_target and status = 'Authorized';

  update public.authorizations
     set status = 'Submitted',
         recipient = coalesce(nullif(p_recipient, ''), recipient),
         submitted_by = coalesce(submitted_by, p_staff)
   where id = v_target and status = 'Due';

  return v_target;
end;
$$;

comment on function public.submit_authorization_on_send is
  'A signed packet has gone to the billing office: the authorization it was for becomes Submitted (§§10, 12.4). Creates no bill - the authorization is the bill - and opens a coaching month only if the calendar has not yet.';

revoke all on function public.submit_authorization_on_send(uuid, text, text, uuid) from anon, authenticated;
grant execute on function public.submit_authorization_on_send(uuid, text, text, uuid) to authenticated;

-- The billing item is created by nothing now.
drop function if exists public.submit_item_for_form(uuid, text, text, uuid);
