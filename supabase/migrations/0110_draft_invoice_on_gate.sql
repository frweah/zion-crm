-- Zion Vocational Rehab CRM — the draft invoice the form has earned
--
-- The billing gate (check_invoice_forms, 0002) refuses to send an invoice
-- while a required USOR form is still a draft. It has always been a refusal
-- and never a prompt: the moment the last form is signed and sent, the
-- practice is owed money and nothing anywhere says so. Billing finds out by
-- going to look.
--
-- So when a form completes the gate for an authorization, the invoice it has
-- earned is written as a Draft, with the amount worked out from the hours
-- actually logged. Draft is the whole point: nothing has been claimed from
-- USOR and nothing has been sent. Billing puts the invoice number on it and
-- sends it, and the gate they already have checks it again on the way out.
--
-- Deliberately a database function rather than a server action: the person
-- who signs the form is usually Job Search, who may not create an invoice.
-- The system is creating this, not them, and it creates exactly one.

/** Is every form this authorization's service needs now out of draft? */
create or replace function public.billing_gate_met(p_auth uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select not exists (
    select 1
      from public.authorizations a
      join public.form_templates t
        on t.required_for_billing and a.service_type = any (t.services)
     where a.id = p_auth
       and not exists (
         select 1 from public.forms f
          where f.auth_id = a.id and f.template_id = t.id and f.status <> 'Draft'));
$$;

/**
 * The Draft invoice for an authorization whose paperwork is complete.
 *
 * Returns the invoice, or null when there is nothing to raise: the gate is
 * not met, there is nothing unbilled, or a Draft is already waiting. It never
 * raises a second one - somebody sending two forms for one authorization in
 * the same afternoon should end up with one invoice, not two.
 */
create or replace function public.draft_invoice_for_authorization(p_auth uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_unbilled numeric;
  v_service  text;
  v_id       uuid;
begin
  if not public.is_active_staff() then
    raise exception 'Only staff raise an invoice.' using errcode = 'insufficient_privilege';
  end if;
  if not public.billing_gate_met(p_auth) then
    return null;
  end if;

  -- What the hours come to, less anything already invoiced. The view zeroes
  -- this for an authorization that is not Open, which is what we want.
  select e.unbilled, a.service_type into v_unbilled, v_service
    from public.authorization_economics e
    join public.authorizations a on a.id = e.auth_id
   where e.auth_id = p_auth;

  if coalesce(v_unbilled, 0) <= 0 then
    return null;
  end if;
  if exists (select 1 from public.invoices where auth_id = p_auth and status = 'Draft') then
    return null;
  end if;

  -- No number: Billing puts theirs on when they send it. The amount guard
  -- (0002) still applies, and the forms guard checks again on the way out.
  insert into public.invoices (auth_id, amount, status, date, service_type)
  values (p_auth, round(v_unbilled, 2), 'Draft', public.practice_today(), coalesce(v_service, ''))
  returning id into v_id;
  return v_id;
end;
$$;

revoke execute on function public.billing_gate_met(uuid) from public, anon;
revoke execute on function public.draft_invoice_for_authorization(uuid) from public, anon;
grant execute on function public.billing_gate_met(uuid) to authenticated, service_role;
grant execute on function public.draft_invoice_for_authorization(uuid) to authenticated, service_role;
