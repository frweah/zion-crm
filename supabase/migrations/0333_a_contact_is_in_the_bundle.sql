-- Zion Vocational Rehab CRM - a contact is in the bundle
--
-- verify_records_request asserts that every table carrying a client_id is in
-- the bundle a legal request is answered with, or on a written list of
-- exceptions with its reason. 0330 added two, and both belong in the bundle.
--
-- A client's other phone numbers are the client's data, plainly. So is the
-- fact that the practice holds their daughter-in-law's number, her name, how
-- she is related, and whether she gets the weekly update - held because of
-- this client, and about them as much as about her.
--
-- A contact who has come off the record is in there too. The row stays so the
-- texts they sent keep their name, and a row that stays is a row that is
-- disclosed - the same reasoning the discarded "to file" item is in on.

begin;

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
      /*
       * The numbers the practice holds for them, and the people around them
       * (0330).
       *
       * A client's other phone numbers are the client's data, and so is the
       * fact that the practice holds their daughter-in-law's number, her
       * name, how she is related, and whether she gets the weekly update. A
       * records request is answered with what the practice holds about this
       * person, and a contact's details are held because of them.
       *
       * A contact who has come off the record is in here too. The row stays
       * so the texts they sent keep their name, and a row that stays is a row
       * that is disclosed.
       */
      'other_numbers', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'number', p.phone,
                 'what_it_is', p.label,
                 'note', nullif(p.note, ''),
                 'added_by', (select nullif(s.name, '') from public.staff s where s.id = p.added_by),
                 'added_at', p.created_at
               ) order by p.created_at), '[]'::jsonb)
          from public.client_phones p where p.client_id = p_client
      ),
      'contacts', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'name', t.name,
                 'relationship', t.relationship,
                 'number', t.phone,
                 'what_the_number_is', t.phone_label,
                 'email', nullif(t.email, ''),
                 'gets_the_weekly_update', t.receives_updates,
                 'may_speak_for_the_client', t.may_speak_for,
                 'on_the_record', t.active,
                 'note', nullif(t.note, ''),
                 'added_by', (select nullif(s.name, '') from public.staff s where s.id = t.added_by),
                 'added_at', t.created_at
               ) order by t.created_at), '[]'::jsonb)
          from public.client_contacts t where t.client_id = p_client
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
