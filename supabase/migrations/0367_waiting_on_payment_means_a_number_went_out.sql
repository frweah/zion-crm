-- Zion Vocational Rehab CRM — waiting on payment means a number has gone out
--
-- The board's status pill offers two values, Outstanding and Waiting on
-- payment, and the ruling gates the second on the authorization already
-- having an invoice number (owner, 17 November 2026).
--
-- The gate goes here, not on the pill. `set_authorization_status` took
-- 'Submitted' from anybody with billing hands and asked nothing: probed
-- against a real row before this was written, a Due authorization with no
-- invoice number moved to Submitted and the function said "Now submitted."
-- So the rule the board is about to show would have been true on the board
-- and false on the authorization record, which is the same screen-deep rule
-- 0366 refused to write.
--
-- The definition is restated from what the database held
-- (scripts/dump-function.mjs).

begin;

CREATE OR REPLACE FUNCTION public.set_authorization_status(p_auth uuid, p_status text, p_reason text DEFAULT NULL::text, p_received date DEFAULT NULL::date)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_auth public.authorizations%rowtype;
begin
  if not public.billing_hands() then
    raise exception 'Changing an authorization''s status is Billing''s, or an Admin''s.'
      using errcode = 'insufficient_privilege';
  end if;

  select * into v_auth from public.authorizations where id = p_auth for update;
  if not found then
    raise exception 'That authorization does not exist.' using errcode = 'no_data_found';
  end if;
  if v_auth.status = p_status then
    return format('It was already %s.', lower(p_status));
  end if;

  if p_status = 'Paid' then
    perform public.record_payment(p_auth, p_received, null, null, null);
    return 'Paid, and the payment is on the record.';
  end if;

  if p_status = 'Closed' then
    if coalesce(btrim(p_reason), '') = '' then
      raise exception 'Say why it is being closed. Somebody will ask.' using errcode = 'check_violation';
    end if;
    update public.authorizations
       set status = 'Closed', closed_reason = btrim(p_reason) where id = p_auth;
    return 'Closed, with the reason on the record.';
  end if;

  /*
   * Submitted means the packet went to USOR, and a packet carries an invoice
   * number.
   *
   * The board's pill offers "Waiting on payment" and gates it on there being
   * a number (owner, 17 November 2026). Asked here rather than only there:
   * the pill is one caller, the authorization record is another, and a rule
   * that lives on a screen holds until somebody uses the other screen. The
   * number comes off the stub through `raise_invoice`, which is still the
   * only thing that makes one.
   *
   * Measured before it was added: nothing on file was Due or Submitted with
   * an invoice number, and the status moved to Submitted with no number at
   * all without complaint.
   */
  if p_status = 'Submitted'
     and not exists (select 1 from public.invoices i
                      where i.auth_id = p_auth and i.number is not null) then
    raise exception 'Raise the invoice first - waiting on payment means a number has gone to USOR.'
      using errcode = 'check_violation';
  end if;

  if p_status not in ('Authorized', 'Due', 'Submitted') then
    raise exception '"%" is not a status an authorization has.', p_status using errcode = 'check_violation';
  end if;

  -- The state machine decides whether this move is legal, and says so itself.
  perform set_config('zion.correction_reason', coalesce(btrim(p_reason), ''), true);
  update public.authorizations set status = p_status where id = p_auth;
  perform set_config('zion.correction_reason', '', true);
  return format('Now %s.', lower(p_status));
end;
$function$;

commit;
