-- Zion Vocational Rehab CRM — several numbers, and the people around a client
-- (0330, 0331, 0332)
--
-- What has to hold:
--
--   A contact is never a client. The row has nowhere to put a caseload, a
--   stage, a counselor or a status, which is what makes that structural
--   rather than a promise somebody has to keep.
--
--   A number is on one side or the other. A contact's number may not be one
--   the client is reached on, and a number added to the client may not be one
--   of their contacts' - because an inbound text matches the client first and
--   a number on both would be filed as though the client had sent it.
--
--   Nobody writes to either table directly. The functions are the only door,
--   and they are the three roles that keep client records.
--
--   The number texts go to is swapped, not set: the old one stays on the
--   record.
--
--   Consent is per number. Granting one says nothing about another, and a
--   contact's consent is not the client's.
--
--   A text to a number with no consent is refused in a sentence. A text from
--   a contact's number files on the client, labelled with who sent it. A STOP
--   from a contact's number withdraws that number and not the client's.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_admin uuid; v_admin_uid uuid := gen_random_uuid();
  v_coach uuid; v_coach_uid uuid := gen_random_uuid();
  v_client uuid;
  v_contact uuid; v_phone_id uuid;
  v_text text; v_n integer; v_bool boolean; v_label text;
  v_conv uuid; v_got uuid;
  k_own  text := '+13855550101';
  k_work text := '+13855550102';
  k_her  text := '+13855550103';
  failures text[] := '{}';
begin
  -- ── a contact is not a client, structurally ────────────────
  select count(*) into v_n
    from information_schema.columns
   where table_schema = 'public' and table_name = 'client_contacts'
     and column_name in ('stage', 'caseload', 'counselor_id', 'funding_source',
                         'assigned_staff_id', 'status', 'client_no', 'agency_id');
  if v_n <> 0 then
    failures := failures || format(
      'FAILED: client_contacts has %s column(s) that belong to a client, so a contact could become one', v_n)::text;
  else
    raise notice 'ok  a contact has nowhere to put a caseload, a stage, a counselor or a status';
  end if;

  -- ── the practice ───────────────────────────────────────────
  insert into public.staff (name, email, role, active)
  values ('ZZ Contacts Admin', 'zz-contacts-admin@example.test', 'Admin', true) returning id into v_admin;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_admin_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-contacts-admin@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_admin_uid where id = v_admin;

  insert into public.staff (name, email, role, active)
  values ('ZZ Contacts Coach', 'zz-contacts-coach@example.test', 'Job Coach', true) returning id into v_coach;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_coach_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-contacts-coach@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_coach_uid where id = v_coach;

  insert into public.clients (name, stage, status, assigned_staff_id, phone)
  values ('ZZ Several Numbers', 'Job Search', 'Active', v_admin, k_own) returning id into v_client;

  -- ── a coach does not keep client records ───────────────────
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_coach_uid, 'role', 'authenticated')::text, true);
  v_text := '';
  begin
    perform public.add_client_contact(v_client, 'ZZ Her', 'daughter-in-law', k_her, 'Mobile', '', true, false);
    v_text := 'allowed';
  exception when insufficient_privilege then
    v_text := sqlerrm;
  end;
  if v_text = 'allowed' then
    failures := failures || 'FAILED: a Job Coach added a contact'::text;
  else
    raise notice 'ok  a contact is added by the roles that keep client records';
  end if;

  -- ── and nobody writes to the table directly ────────────────
  perform set_config('role', 'authenticated', true);
  v_text := '';
  begin
    insert into public.client_contacts (client_id, name, relationship)
    values (v_client, 'ZZ Sneaked In', 'nobody');
    v_text := 'allowed';
  exception when insufficient_privilege then
    v_text := 'refused';
  when others then
    v_text := 'refused: ' || sqlerrm;
  end;
  perform set_config('role', 'postgres', true);
  if v_text = 'allowed' then
    failures := failures || 'FAILED: a signed-in person wrote a contact straight into the table'::text;
  else
    raise notice 'ok  the functions are the only door to a contact';
  end if;

  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_admin_uid, 'role', 'authenticated')::text, true);

  -- ── a number, and the one texts go to ──────────────────────
  v_phone_id := public.add_client_phone(v_client, 'Work', k_work, 'Not after five');
  select count(*) into v_n from public.client_numbers where client_id = v_client;
  select texts_here into v_bool from public.client_numbers
   where client_id = v_client and phone = k_own;
  if v_n <> 2 then
    failures := failures || format('FAILED: two numbers read as %s', v_n)::text;
  elsif not v_bool then
    failures := failures || 'FAILED: the number the client is texted at is not marked as the one'::text;
  else
    raise notice 'ok  two numbers, and exactly one of them is where texts go';
  end if;

  perform public.set_texting_number(v_client, k_work);
  select texts_here into v_bool from public.client_numbers
   where client_id = v_client and phone = k_work;
  select count(*) into v_n from public.client_numbers where client_id = v_client;
  if not coalesce(v_bool, false) then
    failures := failures || 'FAILED: the chosen number is not the one texts go to'::text;
  elsif v_n <> 2 then
    failures := failures || format('FAILED: swapping the texting number left %s number(s)', v_n)::text;
  elsif not exists (select 1 from public.client_numbers where client_id = v_client and phone = k_own) then
    failures := failures || 'FAILED: the number that was being texted was lost in the swap'::text;
  else
    raise notice 'ok  the texting number is swapped, and the other one stays on the record';
  end if;

  -- ── a contact ──────────────────────────────────────────────
  v_contact := public.add_client_contact(v_client, 'ZZ Her', 'daughter-in-law', k_her, 'Mobile', '', true, false);

  v_text := '';
  begin
    perform public.add_client_phone(v_client, 'Mobile', k_her, '');
    v_text := 'allowed';
  exception when check_violation then
    v_text := sqlerrm;
  end;
  if v_text = 'allowed' then
    failures := failures || 'FAILED: a contact''s number was added to the client as well'::text;
  elsif v_text not like '%contact%' then
    failures := failures || format('FAILED: refused, but not in a sentence: %s', v_text)::text;
  else
    raise notice 'ok  a number is on one side or the other, never both';
  end if;

  v_text := '';
  begin
    perform public.add_client_contact(v_client, 'ZZ Him', 'brother', k_work, 'Mobile', '', false, false);
    v_text := 'allowed';
  exception when check_violation then
    v_text := sqlerrm;
  end;
  if v_text = 'allowed' then
    failures := failures || 'FAILED: the client''s own texting number was made a contact as well'::text;
  else
    raise notice 'ok  and the other way round';
  end if;

  -- ── consent, per number ────────────────────────────────────
  perform public.set_sms_consent(v_client, k_work, 'Granted', 'Verbal', 'On the phone, checking this');
  select can_text into v_bool from public.sms_consent_numbers
   where client_id = v_client and phone = k_her;
  if coalesce(v_bool, false) then
    failures := failures || 'FAILED: consent for the client''s number granted it for their contact''s'::text;
  else
    raise notice 'ok  consent for one number says nothing about another';
  end if;

  perform public.set_sms_consent(v_client, k_her, 'Granted', 'Verbal', 'She said yes herself');
  select can_text into v_bool from public.sms_consent_numbers
   where client_id = v_client and phone = k_work;
  if not coalesce(v_bool, false) then
    failures := failures || 'FAILED: recording a contact''s consent took the client''s away'::text;
  else
    raise notice 'ok  and a contact''s consent is not the client''s';
  end if;

  v_text := '';
  begin
    perform public.set_sms_consent(v_client, '+13855559999', 'Granted', 'Verbal', 'Nowhere near the record');
    v_text := 'allowed';
  exception when check_violation then
    v_text := sqlerrm;
  end;
  if v_text = 'allowed' then
    failures := failures || 'FAILED: consent was recorded for a number on no record'::text;
  else
    raise notice 'ok  consent cannot be recorded for a number the practice does not hold';
  end if;

  -- ── a text to a number with no consent ─────────────────────
  perform public.set_sms_consent(v_client, k_own, 'Declined', 'Staff', '');
  v_text := '';
  begin
    insert into public.sms_messages (client_id, direction, phone, body, kind, status, created_by, send_after)
    values (v_client, 'Outgoing', k_own, 'ZZ nothing should go here', 'Manual', 'Scheduled', v_admin,
            public.next_text_window(now()));
    v_text := 'allowed';
  exception when check_violation then
    v_text := sqlerrm;
  end;
  if v_text = 'allowed' then
    failures := failures || 'FAILED: a text went to a number whose consent was declined'::text;
  elsif v_text not like '%has not agreed%' then
    failures := failures || format('FAILED: refused, but not in a sentence: %s', v_text)::text;
  else
    raise notice 'ok  a text to a number with no consent is refused, in a sentence';
  end if;

  -- ── and one to the contact's, which is consented ───────────
  insert into public.sms_messages (client_id, direction, phone, body, kind, status, created_by, send_after)
  values (v_client, 'Outgoing', k_her, 'ZZ weekly update', 'Manual', 'Scheduled', v_admin,
          public.next_text_window(now()));
  select contact_id into v_got from public.sms_messages
   where client_id = v_client and phone = k_her and direction = 'Outgoing';
  if v_got is distinct from v_contact then
    failures := failures || 'FAILED: a text to a contact''s number does not say whose number it was'::text;
  else
    raise notice 'ok  a text to a contact''s number carries the contact';
  end if;

  -- ── a text from a contact's number ─────────────────────────
  select r.client_id, r.contact_id into v_got, v_contact
    from public.record_incoming_sms(k_her, 'ZZ she replied') r;
  if v_got is distinct from v_client then
    failures := failures || 'FAILED: a text from a contact''s number did not file on the client'::text;
  else
    raise notice 'ok  a text from a contact''s number files on the client';
  end if;

  select m.sender_label into v_label
    from public.messages m
    join public.sms_messages s on s.id = m.source_sms_id
   where s.phone = k_her and s.direction = 'Incoming'
   order by m.seq desc limit 1;
  if coalesce(v_label, '') not like 'ZZ Her (daughter-in-law)%' then
    failures := failures || format('FAILED: the message says it is from "%s"', coalesce(v_label, ''))::text;
  else
    raise notice 'ok  and it says who sent it, with the relationship';
  end if;

  -- ── a STOP is about the number it came from ────────────────
  perform public.record_incoming_sms(k_her, 'STOP');
  select can_text into v_bool from public.sms_consent_numbers
   where client_id = v_client and phone = k_her;
  if coalesce(v_bool, false) then
    failures := failures || 'FAILED: a STOP from a contact''s number was not honoured'::text;
  end if;
  select can_text into v_bool from public.sms_consent_numbers
   where client_id = v_client and phone = k_work;
  if not coalesce(v_bool, false) then
    failures := failures || 'FAILED: a STOP from a contact''s number withdrew the client''s consent too'::text;
  else
    raise notice 'ok  a STOP stops that number, and only that number';
  end if;

  -- ── and a contact off the record keeps their name on it ────
  perform public.remove_client_contact(v_contact, 'Asked not to be contacted again');
  select active into v_bool from public.client_contacts where id = v_contact;
  select count(*) into v_n from public.client_numbers where client_id = v_client and phone = k_her;
  select m.sender_label into v_label
    from public.messages m
    join public.sms_messages s on s.id = m.source_sms_id
   where s.phone = k_her and s.direction = 'Incoming'
   order by m.seq desc limit 1;
  if coalesce(v_bool, true) then
    failures := failures || 'FAILED: a contact taken off the record is still on it'::text;
  elsif v_n <> 0 then
    failures := failures || 'FAILED: a contact taken off the record still offers their number'::text;
  elsif coalesce(v_label, '') not like 'ZZ Her%' then
    failures := failures || 'FAILED: what a contact sent lost their name when they came off the record'::text;
  else
    raise notice 'ok  a contact off the record keeps their name on what they sent';
  end if;

  perform set_config('request.jwt.claims', '', true);

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, chr(10));
  end if;
end $$;

rollback;
