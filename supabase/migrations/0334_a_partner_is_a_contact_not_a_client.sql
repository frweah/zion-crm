-- Zion Vocational Rehab CRM — a partner is a contact, not a client
--
-- The owner's ruling of 9 November 2026: a client record that is really
-- somebody's partner becomes a contact on that client, with the phone and the
-- texts moved, and the record is closed saying what it was. Both people are
-- named by id below and nowhere else: no client is named in this repository.
--
-- The second half of the ruling, merging a duplicate record into the one it
-- duplicates, **was already done**. The duplicate carries `merged_into`, and
-- a merged row is hidden from staff by a restrictive policy on `clients`, so
-- it is not in the client list and has not been. This morning's report said
-- it was, and that was wrong: the query behind the report ran as the database
-- owner, which no policy applies to. Nothing was needed and nothing is done
-- here.
--
-- ── what moves ───────────────────────────────────────────────
--
-- The record holds one text sent on 7 November, the thread it is in, a
-- consent event granted on 6 November for that number, a task to complete an
-- intake, and a contact-log line from being taken off the board this morning.
--
-- The text, the thread and the consent move, with the new contact row against
-- them. They are about the same person reached on the same number, and a
-- reply arriving tomorrow has to land in the same thread as the text it
-- answers.
--
-- The task and the contact-log line stay. Neither is about the client they
-- would move to: one is an intake somebody was asked to do for a record that
-- should never have existed, and the other is that record being taken off the
-- board. Moving them would put two things in somebody's history that never
-- happened to him. The record stays, closed, with both on it — which is what
-- a closed record is for.
--
-- The contact's name is read off the record being closed rather than written
-- here, which is both how this repository stays free of client names and the
-- more honest way round: the name on the contact is the name the practice had
-- already written down.

begin;

do $$
declare
  k_was      uuid := '3f87ffe9-4d1e-4f45-91d1-55033a44e43f';  -- the record that is not a client
  k_client   uuid := 'efe74c7d-81a8-4806-9528-d6fbde7ec83f';  -- the client they are a contact of
  k_owner    uuid := '04b7945f-f14b-42a9-a6c4-6dda453bd17b';
  k_owner_uid uuid := '00cd300a-b606-4cab-9413-dbb2082f8f07';
  v_was_name text;
  v_client   text;
  v_first    text;
  v_phone    text;
  v_contact  uuid;
  v_moved    integer;
  v_when     timestamptz;
  v_reason   text;
begin
  perform set_config('request.jwt.claims',
                     json_build_object('sub', k_owner_uid, 'role', 'authenticated')::text, true);

  select c.name, public.normalize_phone(c.phone) into v_was_name, v_phone
    from public.clients c where c.id = k_was;
  select c.name into v_client from public.clients c where c.id = k_client;
  if v_was_name is null or v_client is null then
    raise notice 'One of the two records is gone; nothing to move.';
    return;
  end if;
  if v_phone is null then
    raise exception 'The record has no usable number, so there is nothing to move.';
  end if;

  -- The record is named "Firstname (Somebody's Partner)". The name is the
  -- part in front of the bracket; the rest is the sentence that should have
  -- been a relationship on a contact all along.
  v_first := btrim(split_part(v_was_name, '(', 1));
  if v_first = '' then v_first := v_was_name; end if;

  v_reason := format(
    'Was never a client: the partner of %s, where the record now is, as a contact. '
    || 'On the owner''s ruling of 9 November 2026.', v_client);

  -- ── the contact ──────────────────────────────────────────
  select id into v_contact from public.client_contacts
   where client_id = k_client and phone = v_phone;
  if v_contact is null then
    v_contact := public.add_client_contact(
      k_client, v_first, 'partner', v_phone, 'Mobile', '', true, false);
    raise notice 'The partner is a contact on the client now, and gets the weekly update.';
  end if;

  -- ── the texts, the thread and the consent ────────────────
  update public.sms_messages
     set client_id = k_client, contact_id = v_contact
   where client_id = k_was;
  get diagnostics v_moved = row_count;
  raise notice '% text(s) moved onto the client, labelled as the partner.', v_moved;

  update public.conversations
     set client_id = k_client, title = v_first || ' (partner)'
   where client_id = k_was and kind = 'sms';

  -- The mirror of those texts in the staff inbox carries the sender's name on
  -- each message. It is written when the text arrives, and it was written
  -- blank because there was no contact to name then.
  update public.messages m
     set sender_label = v_first || ' (partner)'
   where m.sender_kind = 'client'
     and coalesce(m.sender_label, '') = ''
     and exists (select 1 from public.sms_messages s
                  where s.id = m.source_sms_id and s.contact_id = v_contact);

  /*
   * Consent is recorded again rather than moved.
   *
   * The events are append-only, and rightly: a consent record that can be
   * edited is not evidence of anything. The event on the closed record stays
   * where it is, and the same consent for the same number is recorded against
   * the client and the contact, saying where it came from. Nothing is claimed
   * that did not happen - the person said yes to this number on 6 November
   * and the number has not changed.
   */
  select e.at into v_when
    from public.sms_consent_events e
   where e.client_id = k_was and e.state = 'Granted' and e.phone = v_phone
   order by e.at desc limit 1;

  if v_when is not null
     and not exists (select 1 from public.sms_consent_events e
                      where e.client_id = k_client and e.phone = v_phone) then
    perform public.set_sms_consent(
      k_client, v_phone, 'Granted', 'Intake form',
      format('Given on %s, when the number was on its own record. Carried across '
             || 'when that record became a contact, on the owner''s ruling of '
             || '9 November 2026. The number has not changed.',
             to_char(v_when at time zone 'America/Denver', 'FMMon FMDD, YYYY')));
    raise notice 'The consent for that number is recorded against the client and the contact.';
  end if;

  -- ── and the record is closed, in the owner's words ───────
  -- It was closed this morning with the reason "not a client". Closed again
  -- with the owner's, because the reason on a record is read by whoever finds
  -- it next and "not a client" does not say whose contact they were.
  perform public.close_client(k_was, v_reason);

  insert into public.client_corrections
    (client_id, client_name, field, was_value, new_value, reason, staff_id, staff_name)
  values
    (k_was, v_was_name, 'Record', 'A client on the caseload',
     'A contact on another client, and this record closed', v_reason, k_owner, 'Francis Weah'),
    (k_client, v_client, 'Contacts', 'None',
     'Their partner, who gets the weekly update, with the texts and the consent from the closed record',
     v_reason, k_owner, 'Francis Weah');

  perform set_config('request.jwt.claims', '', true);
end $$;

commit;
