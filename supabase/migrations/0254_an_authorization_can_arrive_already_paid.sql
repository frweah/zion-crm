-- Zion Vocational Rehab CRM — 0254 an authorization can arrive already paid
--
-- The practice has a backlog of authorizations that were issued, worked,
-- invoiced and paid before any of it went through the CRM. Typing one in and
-- then walking it through Due, Submitted and Paid to get it on the books is
-- four steps to record one fact, and each step asks for a reason that nobody
-- has, because none of it happened today (owner, 26 Oct 2026).
--
-- So the form can say "this one is already paid" and hand over the date, the
-- amount and the warrant with the rest of it.
--
-- **It does not insert a paid row.** Status on an authorization is not a
-- column somebody sets, it is the thing the ledger watches:
-- `authorizations_post` fires on *update* of status and posts the receivable
-- and the cash, and `post_authorization` already has a branch for the exact
-- case here - "paid without having been submitted here" - which raises the
-- receivable on the way past so the books balance. An inserted row with
-- `status = 'Paid'` would skip all of it and show income in Money that the
-- ledger had never heard of.
--
-- What this does instead is the same three things a person would do, in one
-- transaction: insert it, move it to Due, and record the payment through
-- `record_payment`, which is the function that already knows how. Every
-- trigger fires in its usual order, the correction log records the moves, and
-- there is no second way into the books to keep in step with the first.
--
-- A new parameter is a new signature, and a new signature is a new function
-- with a new function's grants (0235). The old one is dropped first and the
-- grants are set explicitly.

drop function if exists public.add_authorization(uuid, text, text, text, numeric, numeric, date, date, text, text, text);

create or replace function public.add_authorization(
  p_client         uuid,
  p_number         text,
  p_service_type   text,
  p_rate_type      text,
  p_rate           numeric,
  p_total_hours    numeric default null,
  p_start          date default null,
  p_end            date default null,
  p_requires_forms text default '',
  p_funding_source text default 'Utah VR',
  p_note           text default null,
  p_received_on    date default null,
  p_paid_on        date default null,
  p_paid_amount    numeric default null,
  p_warrant        text default ''
)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  if not (public.current_staff_role() in ('Admin', 'Billing')
          or public.staff_has_area('billing', 'edit')
          -- The intake, which runs as the service role with nobody signed in
          -- (0182). What it creates is unconfirmed; a person still confirms it.
          or coalesce(public.filing_caller_role(), '') = 'service_role') then
    raise exception 'Only Admin and Billing add authorizations.'
      using errcode = 'insufficient_privilege';
  end if;
  if p_client is null then
    raise exception 'Choose a client.' using errcode = 'check_violation';
  end if;

  -- Said before anything is written, because "it is already paid" and "it has
  -- no payment date" together is somebody half way through the form.
  if p_paid_on is not null and p_paid_on > public.practice_today() then
    raise exception 'A payment cannot have been received in the future.'
      using errcode = 'check_violation';
  end if;

  insert into public.authorizations
    (client_id, number, service_type, funding_source, rate_type, rate, total_hours,
     start_date, end_date, requires_forms, note, received_on)
  values
    (p_client, coalesce(p_number, ''), p_service_type,
     coalesce(nullif(p_funding_source, ''), 'Utah VR'),
     p_rate_type, p_rate,
     case when p_rate_type = 'Hourly' then p_total_hours end,
     p_start, p_end, coalesce(p_requires_forms, ''), btrim(coalesce(p_note, '')),
     p_received_on)
  returning id into v_id;

  -- ── already paid ──────────────────────────────────────────
  if p_paid_on is not null then
    -- Due first: `record_payment` records against something that is Submitted
    -- or Due, which is the rule for a payment arriving at any other time and
    -- there is no reason for this to be the exception.
    update public.authorizations set status = 'Due' where id = v_id;

    perform public.record_payment(v_id, p_paid_on, p_paid_amount, p_warrant, null);
  end if;

  return v_id;
end;
$$;

comment on function public.add_authorization is
  'Adds an authorization, and records the payment too when it arrived already paid - through record_payment, so the books see it the usual way (0254).';

revoke all on function public.add_authorization(uuid, text, text, text, numeric, numeric, date, date, text, text, text, date, date, numeric, text)
  from anon, authenticated;
grant execute on function public.add_authorization(uuid, text, text, text, numeric, numeric, date, date, text, text, text, date, date, numeric, text)
  to authenticated;
