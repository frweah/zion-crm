-- Zion Vocational Rehab CRM — sending the packet is what makes an item
-- Submitted (Billing Lifecycle Brief §2, §8)
--
-- Report & bill has always been the way a claim actually leaves the building:
-- pick the client, pick the authorization, the form comes up filled in, and
-- Send emails it to the billing office with the signed PDF and the
-- authorization behind it. The item has to learn about that, or Billing >
-- Items would show work as waiting that went out a fortnight ago.
--
-- So the send calls this, and this is the only way an item reaches Submitted
-- from that flow - a person still cannot type the status anywhere (her 12.8).
-- The item is created if there is not one, because the practice has sent
-- claims for years without anything called an item, and a send that quietly
-- made no record would be the worst of both.
--
-- Where the dates come from, and where they do not: a month's item ends when
-- the month ends, which is a fact about the period rather than a guess about
-- the work. A one-time item's service dates are left alone - the send says
-- the paperwork went, not when somebody did the job - and the checklist goes
-- on asking for them.

create or replace function public.submit_item_for_form(
  p_auth uuid,
  p_month text,
  p_recipient text,
  p_staff uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_auth public.authorizations;
  rule public.billing_service_rules;
  v_period date;
  v_item uuid;
begin
  select * into v_auth from public.authorizations where id = p_auth;
  if not found then return null; end if;
  select * into rule from public.billing_service_rules where service = v_auth.service_type;
  if not found then return null; end if;

  if rule.recurrence = 'Monthly' then
    v_period := date_trunc('month', coalesce(to_date(nullif(p_month, ''), 'YYYY-MM'), public.practice_today()))::date;
  end if;

  select id into v_item from public.billing_items
   where client_id = v_auth.client_id and auth_id = p_auth
     and service = v_auth.service_type
     and period is not distinct from v_period;

  if v_item is null then
    insert into public.billing_items (
      client_id, auth_id, service, period, status,
      billing_type, rate, assigned_staff_id, recipient, submitted_at, submitted_by,
      service_end, notes
    )
    values (
      v_auth.client_id, p_auth, v_auth.service_type, v_period, 'Submitted',
      rule.billing_type, v_auth.rate,
      (select billing_staff_id from public.clients where id = v_auth.client_id),
      p_recipient, now(), p_staff,
      case when v_period is not null then (v_period + interval '1 month' - interval '1 day')::date end,
      'Opened by Report & bill when the packet was sent (0128).'
    )
    returning id into v_item;
    return v_item;
  end if;

  -- An item already there: it is being sent, whatever it thought it was
  -- doing. A month's end is filled in if it was missing, because the trigger
  -- refuses to bill work still recorded as in progress - and the packet has
  -- just gone out, so it is not.
  update public.billing_items
     set status = 'Submitted',
         recipient = p_recipient,
         submitted_at = now(),
         submitted_by = p_staff,
         followup_due = null,
         service_end = case
           when service_end is not null then service_end
           when v_period is not null then (v_period + interval '1 month' - interval '1 day')::date
           else service_end
         end
   where id = v_item
     and status not in ('Paid', 'Closed');

  return v_item;
end;
$$;
revoke execute on function public.submit_item_for_form(uuid, text, text, uuid) from public, anon;
grant execute on function public.submit_item_for_form(uuid, text, text, uuid) to authenticated;

comment on function public.submit_item_for_form(uuid, text, text, uuid) is
  'Report & bill''s send, in the item''s words (0128): the one way that flow reaches Submitted, and it records who and when like any other move.';
