-- Zion Vocational Rehab CRM — the intake rules (0181, 0182)
--
-- The brief's own list, each tried from the direction that would break it:
--
--   a referral creates the client once;
--   a second referral for the same person attaches and says "re-sent";
--   an ambiguous name creates nothing at all;
--   an authorization attaches to the client on file, and to the number on
--   file rather than making a second;
--   an authorization for somebody not on file creates no client;
--   placement work notifies Rei as well, coaching does not;
--   every notification lands in all three places.
--
-- The sender rule - only @utah.gov is processed - is not here, because it is
-- not in the database: the route decides it before anything is read. Its cases
-- are in scripts/check-intake.mjs, against the same expression the route uses.
--
-- Run as the service role, which is what the intake is: add_authorization
-- admits it by that name (0182) and would refuse a caller with nobody signed
-- in, which is what this script would otherwise be.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_margaret uuid;
  v_rei      uuid;
  v_doc1     uuid;
  v_doc2     uuid;
  v_doc3     uuid;
  v_doc4     uuid;
  v_doc5     uuid;
  v_doc6     uuid;
  v_doc7     uuid;
  v_doc8     uuid;
  v_doc9     uuid;
  v_twin_a   uuid;
  v_twin_b   uuid;
  v_client   uuid;
  v_before   bigint;
  v_n        bigint;
  v_res      jsonb;
  v_text     text;
  failures   text[] := '{}';

begin
  select intake_staff_id, placement_staff_id into v_margaret, v_rei
    from public.org_settings limit 1;
  if v_margaret is null or v_rei is null then
    raise exception 'FAILED: org_settings does not say who intake addresses';
  end if;

  -- Five documents in the inbox, as the route would have stored them.
  insert into public.inbox_documents (sha256, folder_name, relative_path, filename, size_bytes, kind, storage_path)
  values (repeat('a', 64), 'service@ mail', 'mail/zz/zz-referral.pdf', 'zz-referral.pdf', 1000, 'USOR form', 'inbox/zz-a.pdf')
  returning id into v_doc1;
  insert into public.inbox_documents (sha256, folder_name, relative_path, filename, size_bytes, kind, storage_path)
  values (repeat('b', 64), 'service@ mail', 'mail/zz/zz-referral-again.pdf', 'zz-referral-again.pdf', 1000, 'USOR form', 'inbox/zz-b.pdf')
  returning id into v_doc2;
  insert into public.inbox_documents (sha256, folder_name, relative_path, filename, size_bytes, kind, storage_path)
  values (repeat('c', 64), 'service@ mail', 'mail/zz/zz-auth.pdf', 'zz-auth.pdf', 1000, 'Authorization', 'inbox/zz-c.pdf')
  returning id into v_doc3;
  insert into public.inbox_documents (sha256, folder_name, relative_path, filename, size_bytes, kind, storage_path)
  values (repeat('d', 64), 'service@ mail', 'mail/zz/zz-auth-again.pdf', 'zz-auth-again.pdf', 1000, 'Authorization', 'inbox/zz-d.pdf')
  returning id into v_doc4;
  insert into public.inbox_documents (sha256, folder_name, relative_path, filename, size_bytes, kind, storage_path)
  values (repeat('e', 64), 'service@ mail', 'mail/zz/zz-placement.pdf', 'zz-placement.pdf', 1000, 'Authorization', 'inbox/zz-e.pdf')
  returning id into v_doc5;

  -- One document per case. Reusing one would collide with its own dedupe key
  -- and the rules would correctly say nothing a second time - which is the
  -- behaviour being relied on elsewhere in this script, not a reason to make
  -- the fixtures share.
  insert into public.inbox_documents (sha256, folder_name, relative_path, filename, size_bytes, kind, storage_path)
  values (repeat('f', 64), 'service@ mail', 'mail/zz/zz-twin.pdf', 'zz-twin.pdf', 1000, 'USOR form', 'inbox/zz-f.pdf')
  returning id into v_doc6;
  insert into public.inbox_documents (sha256, folder_name, relative_path, filename, size_bytes, kind, storage_path)
  values (repeat('0', 64), 'service@ mail', 'mail/zz/zz-nobody.pdf', 'zz-nobody.pdf', 1000, 'Authorization', 'inbox/zz-g.pdf')
  returning id into v_doc7;
  insert into public.inbox_documents (sha256, folder_name, relative_path, filename, size_bytes, kind, storage_path)
  values (repeat('1', 64), 'service@ mail', 'mail/zz/zz-scan.pdf', 'zz-scan.pdf', 1000, 'Authorization', 'inbox/zz-h.pdf')
  returning id into v_doc8;
  insert into public.inbox_documents (sha256, folder_name, relative_path, filename, size_bytes, kind, storage_path)
  values (repeat('2', 64), 'service@ mail', 'mail/zz/zz-twice.pdf', 'zz-twice.pdf', 1000, 'Other', 'inbox/zz-i.pdf')
  returning id into v_doc9;

  perform set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);

  -- ── a referral creates the client, once ────────────────────
  select count(*) into v_before from public.clients;
  v_res := public.intake_referral(v_doc1, 'ZZ Intake Testperson', 'ZQ Dana Counselor',
                                  'Salt Lake City', public.practice_today(), '801-555-0142');
  v_client := (v_res ->> 'client_id')::uuid;

  if v_res ->> 'action' <> 'referral' or v_client is null then
    failures := failures || format('FAILED: a referral for somebody new did not create them: %s', v_res)::text;
  elsif (select count(*) from public.clients) <> v_before + 1 then
    failures := failures || 'FAILED: a referral created more than one client'::text;
  elsif (select stage from public.clients where id = v_client) <> 'Referral' then
    failures := failures || 'FAILED: the client was not created at Referral'::text;
  else
    raise notice 'ok  a referral for somebody not on file creates them, once, at Referral';
  end if;

  -- The things the brief asks to be set from the form.
  select format('%s / %s / %s',
                coalesce(referring_office, ''), coalesce(phone, ''),
                case when billing_staff_id = v_margaret then 'billing=Margaret' else 'billing=?' end)
    into v_text from public.clients where id = v_client;
  if v_text <> 'Salt Lake City / 801-555-0142 / billing=Margaret' then
    failures := failures || format('FAILED: the record reads "%s"', v_text)::text;
  else
    raise notice 'ok  office, phone and the billing staff member come off the form and the settings';
  end if;

  -- ── all three places ───────────────────────────────────────
  if not exists (select 1 from public.notifications
                  where staff_id = v_margaret and client_id = v_client and resolved_at is null) then
    failures := failures || 'FAILED: no notification was addressed to Margaret'::text;
  elsif not exists (select 1 from public.tasks
                     where assigned_staff_id = v_margaret and client_id = v_client and status = 'Open') then
    failures := failures || 'FAILED: nothing was put on Margaret''s My day'::text;
  elsif jsonb_array_length(v_res -> 'notify') = 0 then
    failures := failures || 'FAILED: no words were returned for the email'::text;
  else
    raise notice 'ok  the notification is in all three places - the bell, My day, and the words for the email';
  end if;

  -- Rule 5: the intake task and the My day item are one item, not two.
  select count(*) into v_n from public.tasks
   where client_id = v_client and assigned_staff_id = v_margaret and status = 'Open';
  if v_n <> 1 then
    failures := failures || format('FAILED: a referral raised %s items for Margaret rather than one', v_n)::text;
  else
    raise notice 'ok  the intake task and the My day item are the same item';
  end if;

  -- The PDF, the contact log.
  if not exists (select 1 from public.attachments where client_id = v_client and storage_path = 'inbox/zz-a.pdf') then
    failures := failures || 'FAILED: the referral PDF was not attached to the client'::text;
  elsif not exists (select 1 from public.contact_log where client_id = v_client and topic = 'Referral received') then
    failures := failures || 'FAILED: nothing was logged on the client''s contact log'::text;
  else
    raise notice 'ok  the form is on the client and the contact log says where it came from';
  end if;

  -- ── a second referral attaches and says re-sent ────────────
  select count(*) into v_before from public.clients;
  v_res := public.intake_referral(v_doc2, 'zz intake testperson', 'ZQ Dana Counselor',
                                  'Ogden', public.practice_today(), '');
  if v_res ->> 'action' <> 'referral re-sent' then
    failures := failures || format('FAILED: a second referral was not a re-send: %s', v_res ->> 'action')::text;
  elsif (select count(*) from public.clients) <> v_before then
    failures := failures || 'FAILED: a second referral created a second client'::text;
  elsif (v_res ->> 'client_id')::uuid <> v_client then
    failures := failures || 'FAILED: the re-send attached to a different client'::text;
  elsif (select referring_office from public.clients where id = v_client) <> 'Salt Lake City' then
    failures := failures || 'FAILED: the re-send overwrote the office already on the record'::text;
  else
    raise notice 'ok  a second referral attaches, says re-sent, creates nobody, and overwrites nothing';
  end if;

  -- ── an ambiguous name creates nothing ──────────────────────
  insert into public.clients (name, stage, status) values ('ZZ Twin Testperson', 'Referral', 'Active')
  returning id into v_twin_a;
  insert into public.clients (name, stage, status) values ('ZZ Twin Testperson', 'Intake', 'Active')
  returning id into v_twin_b;
  select count(*) into v_before from public.clients;
  v_res := public.intake_referral(v_doc6, 'ZZ Twin Testperson', 'ZQ Dana Counselor', '', null, '');
  if v_res ->> 'action' <> 'ambiguous name' then
    failures := failures || format('FAILED: two matching clients gave "%s"', v_res ->> 'action')::text;
  elsif (select count(*) from public.clients) <> v_before then
    failures := failures || 'FAILED: an ambiguous name created a client anyway'::text;
  elsif v_res ->> 'client_id' is not null then
    failures := failures || 'FAILED: an ambiguous name picked one of them'::text;
  elsif jsonb_array_length(v_res -> 'notify') = 0 then
    failures := failures || 'FAILED: nobody was told about the ambiguous name'::text;
  else
    raise notice 'ok  two clients of the same name creates nothing and asks somebody';
  end if;

  -- ── an authorization attaches to the client on file ────────
  v_res := public.intake_authorization(v_doc3, 'ZZ-V-900', 'ZZ Intake Testperson',
                                       'Job Coaching', public.practice_today(),
                                       public.practice_today() + 60, false);
  if v_res ->> 'action' <> 'authorization' then
    failures := failures || format('FAILED: an authorization for a client on file gave "%s"', v_res ->> 'action')::text;
  elsif (v_res ->> 'client_id')::uuid <> v_client then
    failures := failures || 'FAILED: the authorization went to the wrong client'::text;
  elsif not exists (select 1 from public.authorizations
                     where client_id = v_client and number = 'ZZ-V-900' and status = 'Authorized') then
    failures := failures || 'FAILED: the authorization is not on the client, unconfirmed'::text;
  elsif not exists (select 1 from public.attachments
                     where auth_id = (v_res ->> 'authorization_id')::uuid and category = 'Authorization') then
    failures := failures || 'FAILED: the PDF is not on the authorization'::text;
  else
    raise notice 'ok  an authorization lands on the client already on file, unconfirmed, with its PDF';
  end if;

  -- The same number again attaches rather than doubling.
  select count(*) into v_before from public.authorizations where client_id = v_client;
  v_res := public.intake_authorization(v_doc4, 'ZZ-V-900', 'ZZ Intake Testperson',
                                       'Job Coaching', public.practice_today(),
                                       public.practice_today() + 60, false);
  if v_res ->> 'action' <> 'authorization attached' then
    failures := failures || format('FAILED: the same number again gave "%s"', v_res ->> 'action')::text;
  elsif (select count(*) from public.authorizations where client_id = v_client) <> v_before then
    failures := failures || 'FAILED: a number already on file was created a second time'::text;
  else
    raise notice 'ok  a number already on file is attached to, not doubled';
  end if;

  -- ── and never creates a client ─────────────────────────────
  select count(*) into v_before from public.clients;
  v_res := public.intake_authorization(v_doc7, 'ZZ-V-901', 'ZZ Nobody Onfile',
                                       'Job Placement', null, null, false);
  if v_res ->> 'action' <> 'no client on file' then
    failures := failures || format('FAILED: an authorization for an unknown client gave "%s"', v_res ->> 'action')::text;
  elsif (select count(*) from public.clients) <> v_before then
    failures := failures || 'FAILED: an authorization created a client'::text;
  elsif jsonb_array_length(v_res -> 'notify') = 0 then
    failures := failures || 'FAILED: nobody was told the client was not on file'::text;
  else
    raise notice 'ok  an authorization never creates a client, and says so instead';
  end if;

  -- ── placement reaches Rei, coaching does not ───────────────
  -- The coaching one above is the other half of this: if Rei had been told
  -- about it, the count below would be two.
  select count(*) into v_n from public.notifications
   where staff_id = v_rei and client_id = v_client and resolved_at is null;
  if v_n <> 0 then
    failures := failures || format('FAILED: Rei was told about coaching work (%s notification(s))', v_n)::text;
  else
    raise notice 'ok  coaching work does not reach Rei';
  end if;

  v_res := public.intake_authorization(v_doc5, 'ZZ-V-902', 'ZZ Intake Testperson',
                                       'Job Placement', public.practice_today(),
                                       public.practice_today() + 90, false);
  select count(*) into v_n from public.notifications
   where staff_id = v_rei and client_id = v_client and resolved_at is null;
  if v_n <> 1 then
    failures := failures || format('FAILED: placement work gave Rei %s notification(s)', v_n)::text;
  elsif not exists (select 1 from public.tasks
                     where assigned_staff_id = v_rei and client_id = v_client and status = 'Open') then
    failures := failures || 'FAILED: placement work put nothing on Rei''s My day'::text;
  else
    raise notice 'ok  placement work reaches Rei as well, in all three places';
  end if;

  -- ── the scan warning the brief asks for ────────────────────
  v_res := public.intake_authorization(v_doc8, 'ZZ-V-903', 'ZZ Intake Testperson',
                                       'Job Coaching', public.practice_today(),
                                       public.practice_today() + 30, true);
  select message into v_text from jsonb_to_recordset(v_res -> 'notify') as x(message text) limit 1;
  if v_text is null or position('read from scan' in v_text) = 0 then
    failures := failures || format('FAILED: a reading from a scan is not marked: %s', coalesce(v_text, '(nothing)'))::text;
  else
    raise notice 'ok  an authorization read from a scan says so, as the queue already does';
  end if;

  -- ── one reply per document (Rule 4) ───────────────────────
  if not public.intake_record_mail('zz-message-1', 'dana@utah.gov', 'ZZ referral',
                                   now(), 'referral', '', repeat('a', 64), v_doc1, v_client, true) then
    failures := failures || 'FAILED: the first sight of a document did not claim the reply'::text;
  elsif public.intake_record_mail('zz-message-1', 'dana@utah.gov', 'ZZ referral',
                                  now(), 'referral', '', repeat('a', 64), v_doc1, v_client, true) then
    failures := failures || 'FAILED: a second poll over the same document replied again'::text;
  else
    raise notice 'ok  a document is replied to once, however many times it is seen';
  end if;

  -- ── and a repeated notification does not pile up ───────────
  select count(*) into v_before from public.notifications where staff_id = v_margaret;
  perform public.notify_person(v_margaret, 'intake', 'ZZ said twice', 'zz-same-ref',
                               null, v_client, 'ZZ task said twice', public.practice_today(),
                               'warn', v_doc9);
  perform public.notify_person(v_margaret, 'intake', 'ZZ said twice', 'zz-same-ref',
                               null, v_client, 'ZZ task said twice', public.practice_today(),
                               'warn', v_doc9);
  select count(*) into v_n from public.notifications where staff_id = v_margaret;
  if v_n <> v_before + 1 then
    failures := failures || format('FAILED: the same notification twice left %s rows', v_n - v_before)::text;
  elsif (select count(*) from public.tasks
                  where source_ref = v_doc9 and title = 'ZZ task said twice') <> 1 then
    failures := failures || 'FAILED: the same My day item was raised twice'::text;
  else
    raise notice 'ok  told twice, recorded once - a poll that overlaps the last one is harmless';
  end if;

  -- ── a scan is owed a second look ───────────────────────────
  -- The brief's Timing section: queue for OCR, run the rules when the text is
  -- there. A document the intake could not read is offered again once it has
  -- text; one it read and decided is not, because asking again forever is work
  -- that never ends.
  perform public.intake_record_mail('zz-scan-1', 'dana@utah.gov', 'ZZ scanned referral',
                                    now(), 'unreadable', 'no text in the file',
                                    repeat('3', 64), v_doc9, null, false);
  if exists (select 1 from public.intake_scans_now_readable() where document_id = v_doc9) then
    failures := failures || 'FAILED: a scan with no OCR yet is already being offered'::text;
  else
    update public.inbox_documents set ocr_text = 'ZZ the text the agent read', ocr_at = now()
     where id = v_doc9;
    if not exists (select 1 from public.intake_scans_now_readable() where document_id = v_doc9) then
      failures := failures || 'FAILED: a scan the agent has read is not offered for a second look'::text;
    else
      raise notice 'ok  a scan is offered again only once the agent has read it';
    end if;
  end if;

  -- And once the rules have run, it is not offered a third time.
  if not public.intake_rules_ran_late('zz-scan-1', repeat('3', 64), 'other', '', null, false) then
    if exists (select 1 from public.intake_scans_now_readable() where document_id = v_doc9) then
      failures := failures || 'FAILED: a scan already decided is still being offered'::text;
    else
      raise notice 'ok  and not again once the rules have run on it';
    end if;
  else
    failures := failures || 'FAILED: filing a scan that needed no reply claimed one'::text;
  end if;

  perform set_config('request.jwt.claims', '', true);

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- THE INTAKE RULES VERIFIED ---';
end $$;

rollback;
