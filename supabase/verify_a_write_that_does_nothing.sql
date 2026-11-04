-- A write that does nothing (0285)
--
-- What has to hold:
--
--   A staff member on a screen can record that a text went, that it did not,
--   and can call back one written for later - and each of those really
--   happens, rather than matching no rows and reporting success.
--
--   None of it is a way to rewrite a text. The words, the number and the
--   client stay as they were, and a text the provider has taken cannot be
--   recorded as failed.
--
--   Replacing a document on a staff file moves the row, and says which path it
--   replaced, so the caller only removes the old bytes once the row has
--   really moved.
--
--   And the direct writes those functions exist to replace still do nothing,
--   so nobody reaches for them again.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_uid uuid := gen_random_uuid();
  v_staff uuid; v_client uuid;
  v_sent uuid; v_failed uuid; v_later uuid; v_took uuid; v_in uuid;
  v_file uuid; v_other uuid; v_was text;
  v_n integer; v_body text;
  failures text[] := '{}';
begin
  insert into public.staff (name, email, role, active)
  values ('ZZ Write Sender', 'zz-write@example.test', 'Job Search', true) returning id into v_staff;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-write@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_uid where id = v_staff;

  insert into public.clients (name, stage, status, phone, assigned_staff_id)
  values ('ZZ Write Client', 'Job Search', 'Active', '+13850000781', v_staff) returning id into v_client;
  insert into public.sms_consent_events (client_id, state, phone, method, note)
  values (v_client, 'Granted', '+13850000781', 'Intake form', 'ZQ agreed at intake');

  -- ── writing an outgoing text at any hour ──────────────────
  --
  -- The gate (0050) refuses an immediate outgoing text outside 8am-9pm Utah,
  -- which is the rule and is right. It also made this script pass only during
  -- office hours: the suite failed at 9:13 one evening because of it, and a
  -- check that depends on when it runs is a check somebody will learn to
  -- ignore.
  --
  -- So each fixture is written as scheduled for the next window, which the
  -- gate accepts at any hour, and then put back to the state it is about. The
  -- gate is BEFORE INSERT, so the second statement is not refused - and the
  -- state being tested is a row that is already queued and already old, which
  -- is not something the gate has any view about.

  insert into public.sms_messages (client_id, direction, phone, body, kind, status, created_by, send_after)
  values (v_client, 'Outgoing', '+13850000781', 'ZQ this one went', 'Manual', 'Scheduled', v_staff, public.next_text_window(now()))
  returning id into v_sent;
  update public.sms_messages set status = 'Queued', send_after = null where id = v_sent;
  insert into public.sms_messages (client_id, direction, phone, body, kind, status, created_by, send_after)
  values (v_client, 'Outgoing', '+13850000781', 'ZQ this one did not', 'Manual', 'Scheduled', v_staff, public.next_text_window(now()))
  returning id into v_failed;
  update public.sms_messages set status = 'Queued', send_after = null where id = v_failed;
  insert into public.sms_messages (client_id, direction, phone, body, kind, status, created_by, send_after)
  values (v_client, 'Outgoing', '+13850000781', 'ZQ in the morning', 'Manual', 'Scheduled', v_staff,
          public.next_text_window(now() + interval '1 hour'))
  returning id into v_later;
  insert into public.sms_messages (client_id, direction, phone, body, kind, status, created_by,
                                   provider_message_id, send_after)
  values (v_client, 'Outgoing', '+13850000781', 'ZQ the provider has this', 'Manual', 'Scheduled', v_staff,
          'ghl-zq-1', public.next_text_window(now()))
  returning id into v_took;
  update public.sms_messages set status = 'Queued', send_after = null where id = v_took;
  insert into public.sms_messages (client_id, direction, phone, body, kind, status)
  values (v_client, 'Incoming', '+13850000781', 'ZQ hello', 'Reply', 'Received')
  returning id into v_in;

  -- ── as the staff member, on a screen ──────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);

  -- The fault put back: this is the write the old code made directly, and it
  -- has to go on doing nothing, or the functions are decoration.
  update public.sms_messages set status = 'Sent' where id = v_sent;
  get diagnostics v_n = row_count;
  if v_n <> 0 then
    failures := failures || 'FAILED: a screen can write to sms_messages directly after all, so the rules are optional'::text;
  else
    raise notice 'ok  a screen still cannot write to sms_messages directly';
  end if;

  perform public.record_text_sent(v_sent, 'ghl-zq-2');
  if (select status from public.sms_messages where id = v_sent) <> 'Sent' then
    failures := failures || 'FAILED: a text that went was not recorded as sent'::text;
  elsif (select provider_message_id from public.sms_messages where id = v_sent) <> 'ghl-zq-2' then
    failures := failures || 'FAILED: the provider''s receipt for the text was not kept'::text;
  elsif (select sent_at from public.sms_messages where id = v_sent) is null then
    failures := failures || 'FAILED: a text that went does not say when'::text;
  else
    raise notice 'ok  a text that went is recorded as sent, with the provider''s receipt';
  end if;

  perform public.record_text_failed(v_failed, 'GoHighLevel did not answer within 20 seconds.');
  if (select status from public.sms_messages where id = v_failed) <> 'Failed' then
    failures := failures || 'FAILED: a text that did not go still reads as going'::text;
  elsif (select error from public.sms_messages where id = v_failed) = '' then
    failures := failures || 'FAILED: a text that did not go does not say why'::text;
  else
    raise notice 'ok  and one that did not says so, in the provider''s words';
  end if;

  -- A text the provider took is not a failure, whatever the caller believes
  -- happened next.
  perform public.record_text_failed(v_took, 'ZQ the caller thought this failed');
  if (select status from public.sms_messages where id = v_took) = 'Failed' then
    failures := failures || 'FAILED: a text the provider took was recorded as failed, which invites sending it twice'::text;
  else
    raise notice 'ok  one the provider took cannot be recorded as failed';
  end if;

  -- None of this is a way to rewrite a text.
  select body into v_body from public.sms_messages where id = v_sent;
  if v_body <> 'ZQ this one went' then
    failures := failures || 'FAILED: recording a status changed what the text said'::text;
  else
    raise notice 'ok  recording a status leaves the words alone';
  end if;

  begin
    perform public.record_text_sent(v_in, 'ghl-zq-3');
    failures := failures || 'FAILED: a text that came in was recorded as sent'::text;
  exception when check_violation then
    raise notice 'ok  and a text that came in is not something the practice sent';
  end;

  -- ── a text called back ────────────────────────────────────
  delete from public.sms_messages where id = v_later;
  get diagnostics v_n = row_count;
  if v_n <> 0 then
    failures := failures || 'FAILED: a screen can delete from sms_messages directly'::text;
  end if;

  perform public.cancel_scheduled_text(v_later);
  if exists (select 1 from public.sms_messages where id = v_later) then
    failures := failures || 'FAILED: a text called back is still there, so it still goes out'::text;
  else
    raise notice 'ok  a text written for later can be called back, and is really gone';
  end if;

  begin
    perform public.cancel_scheduled_text(v_sent);
    failures := failures || 'FAILED: a text that has gone was called back, so the record lost it'::text;
  exception when check_violation then
    raise notice 'ok  and one that has already gone cannot be';
  end;

  -- ── a document replaced ───────────────────────────────────
  perform set_config('role', 'postgres', true);
  insert into public.staff_files (staff_id, storage_path, filename, mime_type, size_bytes, category, note)
  values (v_staff, v_staff::text || '/zq-old.pdf', 'zq-old.pdf', 'application/pdf', 1000,
          (select key from public.staff_file_categories
            where not system_only and active order by sort_order limit 1), '')
  returning id into v_file;

  perform set_config('role', 'authenticated', true);
  update public.staff_files set filename = 'zq-direct.pdf' where id = v_file;
  get diagnostics v_n = row_count;
  if v_n <> 0 then
    failures := failures || 'FAILED: a screen can write to staff_files directly'::text;
  else
    raise notice 'ok  a screen still cannot write to staff_files directly';
  end if;

  v_was := public.replace_staff_document(v_file, v_staff::text || '/zq-new.pdf', 'zq-new.pdf',
                                         'application/pdf', 2000);
  if v_was <> v_staff::text || '/zq-old.pdf' then
    failures := failures || 'FAILED: replacing a document did not say which file it replaced, so the old bytes are removed on trust'::text;
  elsif (select storage_path from public.staff_files where id = v_file) <> v_staff::text || '/zq-new.pdf' then
    failures := failures || 'FAILED: the document row still points at the file that is about to be deleted'::text;
  elsif (select size_bytes from public.staff_files where id = v_file) <> 2000 then
    failures := failures || 'FAILED: the replaced document kept the old size'::text;
  else
    raise notice 'ok  a replaced document moves, and names the file it replaced';
  end if;

  -- Somebody else's file, and not an Admin.
  perform set_config('role', 'postgres', true);
  insert into public.staff (name, email, role, active)
  values ('ZZ Write Other', 'zz-write-other@example.test', 'Job Search', true) returning id into v_other;
  insert into public.staff_files (staff_id, storage_path, filename, mime_type, size_bytes, category, note)
  values (v_other, v_other::text || '/zq-theirs.pdf', 'zq-theirs.pdf', 'application/pdf', 1000,
          (select key from public.staff_file_categories
            where not system_only and active order by sort_order limit 1), '')
  returning id into v_file;
  perform set_config('role', 'authenticated', true);
  begin
    perform public.replace_staff_document(v_file, v_other::text || '/zq-mine.pdf', 'zq-mine.pdf',
                                          'application/pdf', 2000);
    failures := failures || 'FAILED: somebody replaced a document on a colleague''s file'::text;
  exception when insufficient_privilege then
    raise notice 'ok  and nobody replaces a document on a colleague''s file';
  end;

  perform set_config('role', 'postgres', true);
  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- WRITES VERIFIED ---';
end $$;

rollback;
