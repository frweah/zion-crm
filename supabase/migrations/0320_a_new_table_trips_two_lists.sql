-- Zion Vocational Rehab CRM — the two lists a new client table trips
--
-- "To file" (0317) put a client_id on a new table, and two checks found it
-- within the minute, both rightly.
--
-- ── the records request ──────────────────────────────────────
--
-- verify_records_request asserts that every table carrying a client_id is in
-- the bundle a legal request is answered with, or on a list of exceptions with
-- its reason. `to_file` is in the bundle.
--
-- It would have been easy to argue the other way: an item in somebody's inbox
-- is deliberately not on the client's record, which is what makes
-- "unconfirmed never appears in a report" true. But a records request is
-- answered with what the practice holds, not with what it has decided to act
-- on - and a discarded item stays on file for ever, so the sweep does not
-- offer it again. A row that stays is a row that is disclosed.
--
-- ── and the elevated function ────────────────────────────────
--
-- verify_portal_rls asserts that a definer function a signed-in person can
-- call checks who is calling. clients_named_in did not, and the hole was
-- real: anybody with a session - a client signed into the portal included -
-- could have handed it a name and learnt from the answer whether that person
-- is a client of this practice. It answers active staff and the nightly
-- sweep, and nobody else.
--
-- The bundle is replaced from the definition the database had rather than
-- from the migration that last defined it.

begin;

create or replace function public.clients_named_in(p_text text)
returns table(client_id uuid, how text)
language sql
stable
security definer
set search_path to 'public'
as $$
  with said as (select lower(coalesce(p_text, '')) as text),
  -- Asked once rather than in each branch below, and the sweep is let in by
  -- name: it runs with nobody signed in, so is_active_staff() is false for
  -- it and the three branches would all answer nothing.
  who as (select public.is_active_staff()
                 or coalesce(auth.role(), '') = 'service_role' as may)
  select c.id, 'named'::text
    from public.clients c, said, who
   where who.may
     and c.status = 'Active' and c.merged_into is null
     and length(btrim(c.name)) >= 6
     and said.text like '%' || lower(btrim(c.name)) || '%'
  union
  select a.client_id, 'another spelling of this name'::text
    from public.client_aliases a
    join public.clients c on c.id = a.client_id, said, who
   where who.may
     and c.status = 'Active' and c.merged_into is null
     and length(btrim(a.name)) >= 6
     and said.text like '%' || lower(btrim(a.name)) || '%'
  union
  select c.id, 'their email address'::text
    from public.clients c, said, who
   where who.may
     and c.status = 'Active' and c.merged_into is null
     and coalesce(btrim(c.email), '') <> ''
     and said.text like '%' || lower(btrim(c.email)) || '%'
$$;

comment on function public.clients_named_in is
  'Active clients whose name, a spelling on file for them, or their email '
  'address appears in a piece of text. Answers active staff and the nightly '
  'sweep only: who is a client of this practice is not a question a session '
  'answers.';

revoke all on function public.clients_named_in(text) from public, anon;
grant execute on function public.clients_named_in(text) to authenticated, service_role;

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
      /*
       * What was noticed about them and not yet filed (0317).
       *
       * An item in somebody's "To file" inbox is not on the client's record -
       * that is the whole design, and it is why an unconfirmed appointment
       * cannot reach a report. It is still something the practice holds with
       * this client's name against it, and a records request is answered with
       * what the practice holds rather than with what it has decided to act
       * on. A discarded one is in here too: the row stays so the sweep does
       * not offer it again, and a row that stays is a row that is disclosed.
       */
      'noticed_not_filed', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'what', nullif(f.title, ''),
                 'where_from', f.source,
                 'when', f.happened_at,
                 'why_this_client', nullif(f.guess_why, ''),
                 'state', f.state,
                 'outcome', nullif(f.outcome, ''),
                 'about', f.category,
                 'what_was_written', nullif(f.note, ''),
                 'decided_by', nullif(f.decided_by_name, ''),
                 'decided_at', f.decided_at
               ) order by f.happened_at desc nulls last), '[]'::jsonb)
          from public.to_file f where f.client_id = p_client
      ),
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

commit;
