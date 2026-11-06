-- Zion Vocational Rehab CRM — the invoice ledger (Phase 3, part three)
--
-- "One record per invoice submitted to USOR, created by Submit." So Submit
-- creates it, rather than somebody remembering to.
--
-- ── who may, and the shape that follows from it ───────────────
--
-- Marking a packet as sent is not Billing's: submit_authorization_on_send
-- asks only for a staff id, because the person who put the packet in the post
-- is the person who knows it went. Raising an invoice by hand is Billing's.
-- Both are true, and they are the same act from two directions.
--
-- So the insert lives in one place that neither gate guards, and the two ways
-- in carry their own gates: submit_invoice is Billing's and asks
-- current_staff_id() for the name, and the Submit path hands in the staff id
-- it already checked. The inner function is revoked from everybody, so the
-- only way to reach it is through one of the two.
--
-- Nothing is raised twice. An authorization with an invoice still outstanding
-- gets no second one, and a service entry can be on one invoice line, so the
-- second press bills nothing even where a second invoice would be allowed.

begin;

-- ── the record itself, reachable only from the two ways in ───
create or replace function public.raise_invoice(
  p_auth uuid,
  p_office uuid,
  p_report uuid,
  p_amount numeric,
  p_by uuid)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  a        public.authorizations;
  v_office uuid;
  v_amount numeric;
  v_hours  numeric;
  v_id     uuid;
  v_lines  integer := 0;
begin
  if p_by is null then
    raise exception 'An invoice has to say who sent it.' using errcode = 'insufficient_privilege';
  end if;

  select * into a from public.authorizations where id = p_auth for update;
  if not found then
    raise exception 'That authorization does not exist.' using errcode = 'no_data_found';
  end if;

  /*
   * A coaching parent is never invoiced; its months are.
   *
   * The same rule record_payment has, and for the same reason: Job Coaching
   * is the one monthly service, and route_entry_to_month puts every logged
   * hour onto the month rather than onto the authorization above it. An
   * invoice raised against the parent would find no hours, come to nothing,
   * and say so in a way that sounds like the hours were never logged.
   */
  if exists (select 1 from public.authorizations c where c.parent_id = p_auth) then
    raise exception 'That is the coaching authorization itself. Its months are what get invoiced.'
      using hint = 'Open the month and invoice that.',
            errcode = 'check_violation';
  end if;

  if exists (select 1 from public.invoices i
              where i.auth_id = p_auth and i.status in ('Submitted', 'Short-paid')) then
    raise exception 'There is already an invoice outstanding on %.',
      coalesce(nullif(a.number, ''), a.service_type)
      using hint = 'Record what came in against it first, or chase it. A second invoice while the first is unanswered is how the same claim gets sent twice.',
            errcode = 'unique_violation';
  end if;

  v_office := coalesce(p_office, public.billing_office_for_authorization(p_auth));

  select coalesce(sum(e.hours), 0) into v_hours
    from public.service_entries e
   where e.auth_id = p_auth and not e.non_billable
     and not exists (select 1 from public.invoice_lines l where l.entry_id = e.id);

  v_amount := coalesce(
    nullif(p_amount, 0),
    case when a.rate_type = 'Flat Fee' then nullif(coalesce(a.rate, 0), 0)
         else nullif(round(v_hours * coalesce(a.rate, 0), 2), 0) end);

  if coalesce(v_amount, 0) <= 0 then
    raise exception '% comes to nothing, so there is no invoice to send.',
      coalesce(nullif(a.number, ''), a.service_type)
      using hint = 'Log the hours, or type the amount being invoiced.',
            errcode = 'invalid_parameter_value';
  end if;

  insert into public.invoices
    (client_id, auth_id, submitted_on, submitted_by, office_id, sent_to,
     amount, report_id, status, source)
  values
    (a.client_id, p_auth, public.practice_today(), p_by, v_office,
     coalesce((select b.billing_email from public.billing_offices b where b.id = v_office), ''),
     v_amount, p_report, 'Submitted', 'Submit')
  returning id into v_id;

  insert into public.invoice_lines (invoice_id, entry_id, on_date, description, hours, rate, amount)
  select v_id, e.id, e.date, coalesce(nullif(btrim(e.notes), ''), a.service_type),
         e.hours, a.rate, round(e.hours * coalesce(a.rate, 0), 2)
    from public.service_entries e
   where e.auth_id = p_auth and not e.non_billable
     and not exists (select 1 from public.invoice_lines l where l.entry_id = e.id);
  get diagnostics v_lines = row_count;

  if v_lines = 0 then
    insert into public.invoice_lines (invoice_id, on_date, description, amount)
    values (v_id, coalesce(a.service_end, a.end_date, public.practice_today()),
            a.service_type, v_amount);
  end if;

  return v_id;
end $$;

revoke all on function public.raise_invoice(uuid, uuid, uuid, numeric, uuid) from public, anon, authenticated;

-- ── by hand, which is Billing's ──────────────────────────────
create or replace function public.submit_invoice(
  p_auth uuid,
  p_office uuid default null,
  p_report uuid default null,
  p_amount numeric default null)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if not public.billing_hands() then
    raise exception 'Raising an invoice is Billing''s, or an Admin''s.'
      using errcode = 'insufficient_privilege';
  end if;
  return public.raise_invoice(p_auth, p_office, p_report, p_amount, public.current_staff_id());
end $$;

revoke execute on function public.submit_invoice(uuid, uuid, uuid, numeric) from anon, authenticated;
grant execute on function public.submit_invoice(uuid, uuid, uuid, numeric) to authenticated;

-- ── and by sending the packet ────────────────────────────────
--
-- Replaced from what the database had rather than from the migration that
-- last defined it. Everything above the invoice is unchanged.
create or replace function public.submit_authorization_on_send(p_auth uuid, p_month text, p_recipient text, p_staff uuid)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  a        public.authorizations;
  rule     public.billing_service_rules;
  v_period date;
  v_target uuid;
  v_me     uuid := public.current_staff_id();
begin
  if v_me is null then
    perform public.refuse_elevated('submit_authorization_on_send',
      'Only a member of staff marks a packet as sent.');
  end if;

  select * into a from public.authorizations where id = p_auth;
  if not found then return null; end if;
  select * into rule from public.billing_service_rules where service = a.service_type;

  if coalesce(rule.recurrence, 'One-time') = 'Monthly' then
    v_period := date_trunc('month',
      coalesce(to_date(nullif(p_month, ''), 'YYYY-MM'), public.practice_today()))::date;

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
         -- The caller's own id, not the one they handed in.
         submitted_by = coalesce(submitted_by, v_me)
   where id = v_target and status = 'Due';

  /**
   * And the invoice, which is the whole point of Phase 3 (0306).
   *
   * Tolerant where the by-hand route refuses, because this is a side effect of
   * a status move that somebody may repeat: an authorization that already has
   * one outstanding keeps it, and one with nothing to bill yet - no hours
   * logged, no flat fee - gets its invoice when there is something on it. The
   * packet having gone out is the fact being recorded either way.
   */
  if not exists (select 1 from public.invoices i
                  where i.auth_id = v_target and i.status in ('Submitted', 'Short-paid')) then
    begin
      perform public.raise_invoice(v_target, null, null, null, v_me);
    exception when invalid_parameter_value or unique_violation then
      null;
    end;
  end if;

  return v_target;
end;
$$;

commit;
