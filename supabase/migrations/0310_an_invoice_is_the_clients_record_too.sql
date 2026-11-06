-- Zion Vocational Rehab CRM — the invoice ledger (Phase 3, part five)
--
-- Two checks fired the moment the ledger existed, and both were right.
--
--   verify_records_request: invoices hold a client_id, so they are either in
--   the bundle a records request is answered with or on the written list of
--   exclusions. A client's invoices are a record of what the practice billed
--   the state for work done with them. They go in the bundle, with the
--   service lines, because a figure with no lines behind it is a number
--   somebody has to take on trust.
--
--   verify_portal_rls: every staff table and view has to read empty for a
--   client signed into the portal, and invoice_month read one row. Not a leak
--   of anything - the view is scalar aggregates over tables whose own RLS
--   gives a portal client nothing, so every figure in that row was zero - but
--   the rule is "no rows", and a row of zeros is a row. A view built entirely
--   of scalar subqueries always returns one, so it needed a WHERE of its own.
--
-- The bundle function is replaced from what the database had rather than from
-- the migration that last defined it: the two drift, and the database is the
-- one answering records requests.

begin;

-- ── the tile reads nothing for anybody who is not staff ──────
create or replace view public.invoice_month as
  select
    coalesce((select sum(i.amount) from public.invoices i
               where i.submitted_on >= date_trunc('month', public.practice_today())::date), 0) as invoiced_this_month,
    coalesce((select sum(p.amount) from public.payments p
               where p.warrant_date >= date_trunc('month', public.practice_today())::date), 0) as paid_this_month,
    coalesce((select sum(i.amount) from public.invoices i
               where i.status in ('Submitted', 'Short-paid')), 0) as outstanding,
    coalesce((select sum(i.amount) from public.invoices i
               where i.status in ('Submitted', 'Short-paid')
                 and i.submitted_on is not null
                 and public.practice_today() - i.submitted_on >= 30), 0) as overdue,
    (select count(*) from public.invoices i
      where i.status in ('Submitted', 'Short-paid')) as open_invoices,
    (select count(*) from public.invoices i
      where i.status in ('Submitted', 'Short-paid')
        and i.submitted_on is not null
        and public.practice_today() - i.submitted_on >= 30) as overdue_invoices
  where public.is_active_staff();

alter view public.invoice_month set (security_invoker = on);
revoke all on public.invoice_month from anon, authenticated;
grant select on public.invoice_month to authenticated;

CREATE OR REPLACE FUNCTION public.records_request_bundle(p_client uuid, p_purpose text DEFAULT 'Records request'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_bundle jsonb;
begin
  v_bundle := public.records_request_bundle_before_reports(p_client, p_purpose);

  return v_bundle
    || jsonb_build_object(
      /*
       * The other spellings of their own name (0303).
       *
       * A client's name as somebody else writes it is the client's data. The
       * practice holds these so a warrant or an invoice under one spelling
       * finds the record, and a records request that left them out would be
       * answered with less than the practice holds. Where each spelling was
       * seen is included, because that is the part that explains why it is
       * on file at all.
       */
      'other_spellings', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'spelling', a.name,
                 'seen_on', a.source,
                 'why', nullif(a.note, ''),
                 'added_by', nullif(a.added_by_name, ''),
                 'added_at', a.at
               ) order by a.name), '[]'::jsonb)
          from public.client_aliases a where a.client_id = p_client
      ),
      /*
       * The invoices sent about them (0306).
       *
       * A client's invoices are a record of what the practice billed the
       * state for work done with them, and theirs to see. The services on
       * each one come with it: a figure with no lines behind it is a number
       * somebody has to take on trust.
       */
      'invoices', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'invoice', i.number,
                 'sent_on', i.submitted_on,
                 'sent_to', nullif(i.sent_to, ''),
                 'office', (select b.name from public.billing_offices b where b.id = i.office_id),
                 'sent_by', (select nullif(s.name, '') from public.staff s where s.id = i.submitted_by),
                 'authorization', (select nullif(a.number, '') from public.authorizations a where a.id = i.auth_id),
                 'claim', i.claim,
                 'amount', i.amount,
                 'status', i.status,
                 'paid_on', i.paid_on,
                 'amount_paid', i.amount_paid,
                 'warrant', nullif(i.warrant, ''),
                 'voucher', nullif(i.voucher, ''),
                 'note', nullif(i.note, ''),
                 'services', (
                   select coalesce(jsonb_agg(jsonb_build_object(
                            'on', l.on_date, 'what', nullif(l.description, ''),
                            'hours', l.hours, 'rate', l.rate, 'amount', l.amount
                          ) order by l.on_date), '[]'::jsonb)
                     from public.invoice_lines l where l.invoice_id = i.id)
               ) order by i.number), '[]'::jsonb)
          from public.invoices i where i.client_id = p_client
      ),
      'weekly_reports', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'week_from', w.week_start,
                 'week_to', w.week_start + 6,
                 'status', w.status,
                 'kept_by', (select nullif(s.name, '') from public.staff s where s.id = w.owner_id),
                 'confirmed_by', (select nullif(s.name, '') from public.staff s where s.id = w.confirmed_by),
                 'confirmed_at', w.confirmed_at,
                 'what_staff_wrote', nullif(w.note, ''),
                 'what_the_record_showed', w.content
               ) order by w.week_start), '[]'::jsonb)
          from public.client_weekly_reports w where w.client_id = p_client
      ),
      'reports', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'report', m.template,
                 'period', m.period,
                 'status', m.status,
                 'due_on', m.due_on,
                 'kept_by', (select nullif(s.name, '') from public.staff s where s.id = m.owner_id),
                 'signed_by', (select nullif(s.name, '') from public.staff s where s.id = m.signed_by),
                 'signed_at', m.signed_at,
                 'sent_at', m.sent_at,
                 'sent_to', nullif(m.sent_to, ''),
                 'reopened_because', nullif(m.reopen_reason, ''),
                 'what_staff_wrote', nullif(m.note, ''),
                 'what_the_record_showed', m.content,
                 'document', (select a.filename from public.attachments a
                               where a.id = m.pdf_attachment_id)
               ) order by m.period, m.template), '[]'::jsonb)
          from public.client_reports m where m.client_id = p_client
      ));
end;
$function$;

-- ── and a definer function says who may call it ──────────────
--
-- The third check that fired: billing_office_for_authorization is SECURITY
-- DEFINER and granted to anybody signed in, and it asked nothing about who
-- was asking. Which office covers an authorization is not much to learn, but
-- the rule is the rule, and a client signed into the portal is somebody
-- signed in. It answers nothing to anybody who is not active staff now.
create or replace function public.billing_office_for_authorization(p_auth uuid)
returns uuid
language sql
stable security definer
set search_path to 'public'
as $$
  select coalesce(
    (select b.id from public.authorizations a
       join public.billing_offices b
         on lower(btrim(b.name)) = lower(btrim(replace(coalesce(a.recipient, ''), ' CRP', '')))
      where a.id = p_auth),
    (select o.billing_office_id
       from public.authorizations a
       join public.client_billing_office o on o.client_id = a.client_id
      where a.id = p_auth)
  )
  where public.is_active_staff();
$$;

revoke execute on function public.billing_office_for_authorization(uuid) from anon, authenticated;
grant execute on function public.billing_office_for_authorization(uuid) to authenticated;

commit;
