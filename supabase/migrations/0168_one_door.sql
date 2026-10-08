-- Zion Vocational Rehab CRM — one door to a bill
-- (Billing Simplification Brief §10)
--
-- §10 asks for "a verify script [that] asserts there is exactly one write path
-- that creates a billable record (add_authorization)".
--
-- There was no such function. Every screen that created an authorization did
-- it with a plain insert, which means the number of write paths was however
-- many places happened to insert - and a check written against that can only
-- count the ones somebody remembered to look for. §10's check is only worth
-- having if there is a door to check, so this builds one.
--
-- add_authorization() is it. Direct insert is revoked from `authenticated`, so
-- a bill cannot come into being any other way: not from a screen, not from a
-- script run as a signed-in person, not from the API. The functions that enter
-- an authorization from a PDF, open a coaching month, or replace a placeholder
-- are security definer and keep working - and each of those is still entering
-- an authorization, which is the one thing §10 allows.
--
-- What it does not do is validate. The rules are triggers and constraints and
-- they hold wherever the row comes from; a door that also made the rules would
-- be a second place for them to live (§11).

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
  p_note           text default null)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  if not (public.current_staff_role() in ('Admin', 'Billing')
          or public.staff_has_area('billing', 'edit')) then
    raise exception 'Only Admin and Billing add authorizations.'
      using errcode = 'insufficient_privilege';
  end if;
  if p_client is null then
    raise exception 'Choose a client.' using errcode = 'check_violation';
  end if;

  insert into public.authorizations
    (client_id, number, service_type, funding_source, rate_type, rate, total_hours,
     start_date, end_date, requires_forms, note)
  values
    (p_client, coalesce(p_number, ''), p_service_type,
     coalesce(nullif(p_funding_source, ''), 'Utah VR'),
     p_rate_type, p_rate,
     case when p_rate_type = 'Hourly' then p_total_hours end,
     p_start, p_end, coalesce(p_requires_forms, ''), btrim(coalesce(p_note, '')))
  returning id into v_id;

  return v_id;
end;
$$;

comment on function public.add_authorization is
  'The one way a billable record comes into being (§10). Entering an authorization is the only thing that creates a bill, and this is where it happens; direct insert is revoked so there is no second way.';

revoke all on function public.add_authorization(uuid, text, text, text, numeric, numeric, date, date, text, text, text) from anon, authenticated;
grant execute on function public.add_authorization(uuid, text, text, text, numeric, numeric, date, date, text, text, text) to authenticated;

-- The door is the only way in. UPDATE and DELETE are unchanged: correcting and
-- closing an authorization is not creating a bill, and RLS already says who may.
revoke insert on public.authorizations from authenticated;

-- ── and the dormant remains of the billing item ──
--
-- Its triggers went with the table, but their functions did not: two guard
-- functions were left naming a table that no longer exists. Nothing calls
-- them, which is exactly the problem - §13.17 says removed, not dormant, and a
-- function that reads a missing table is a trap for whoever next wires it up.
--
-- verify_one_door found these, by asking which functions still name a record
-- that is gone. The same question found warrant reconciliation broken.
drop function if exists public.billing_items_guard();
drop function if exists public.billing_items_opened();
drop function if exists public.billing_items_frozen();
