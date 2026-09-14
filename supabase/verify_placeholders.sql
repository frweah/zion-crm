-- Zion Vocational Rehab CRM — a placeholder authorization takes its real number
--
-- What has to hold:
--
--   Replacing a "(workbook)" placeholder keeps the same authorization - its id,
--   its carried hours - gives it the real number and the PDF, fills blank dates,
--   and makes no second authorization. It is logged with what the number was.
--
--   Only a placeholder is replaced, only the same client's, and never with a
--   number already on file. Only Admin and Billing do it; anonymous callers
--   cannot call it at all.
--
--   The correction log accepts a document taken off an authorization, and a
--   file can carry a review note.
--
-- Runs inside a transaction that is rolled back. Nothing here is left behind.

begin;

do $$
declare
  v_admin   uuid;
  v_adm_uid uuid;
  v_js      uuid;
  v_js_uid  uuid;
  v_a       uuid;
  v_b       uuid;
  v_ph      uuid;
  v_phB     uuid;
  v_real    uuid;
  v_doc     uuid;
  v_doc2    uuid;
  v_count   int;
  r         record;
  failures  text[] := '{}';
begin
  select id, user_id into v_admin, v_adm_uid from public.staff where role = 'Admin' and active order by created_at limit 1;
  select id, user_id into v_js, v_js_uid from public.staff where active and role = 'Job Search' order by created_at limit 1;

  insert into public.clients (name, stage, status, assigned_staff_id)
  values ('ZZ Placeholder One', 'Job Coaching', 'Active', v_admin) returning id into v_a;
  insert into public.clients (name, stage, status, assigned_staff_id)
  values ('ZZ Placeholder Two', 'Job Coaching', 'Active', v_admin) returning id into v_b;

  insert into public.authorizations (client_id, number, service_type, rate_type, rate, total_hours, carried_used, status)
  values (v_a, '(workbook) coaching ZZ01', 'Job Coaching', 'Hourly', 45, 40, 12.5, 'Open') returning id into v_ph;
  insert into public.authorizations (client_id, number, service_type, rate_type, rate, total_hours, status)
  values (v_b, '(workbook) coaching ZZ02', 'Job Coaching', 'Hourly', 45, 40, 'Open') returning id into v_phB;
  insert into public.authorizations (client_id, number, service_type, rate_type, rate, total_hours, status)
  values (v_a, 'ZQ9700001', 'Job Coaching', 'Hourly', 45, 20, 'Open') returning id into v_real;

  insert into public.inbox_documents (sha256, folder_name, relative_path, filename, client_id, kind, state, storage_path)
  values ('zx' || repeat('1', 62), 'ZZ Placeholder One', 'ZZ Placeholder One/a.pdf', 'Job coaching auth.pdf', v_a,
          'Authorization', 'Pending', 'inbox/zx/1.pdf') returning id into v_doc;
  insert into public.inbox_documents (sha256, folder_name, relative_path, filename, client_id, kind, state, storage_path)
  values ('zx' || repeat('2', 62), 'ZZ Placeholder One', 'ZZ Placeholder One/b.pdf', 'other auth.pdf', v_a,
          'Authorization', 'Pending', 'inbox/zx/2.pdf') returning id into v_doc2;

  if has_function_privilege('anon', 'public.replace_placeholder_authorization(uuid, uuid, text, date, date)', 'execute') then
    failures := failures || 'FAILED: an anonymous caller may replace a placeholder'::text;
  else
    raise notice 'ok  replacing a placeholder is not open to anonymous callers';
  end if;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);

  select count(*) into v_count from public.authorizations where client_id = v_a;

  select * into r from public.replace_placeholder_authorization(v_doc, v_ph, 'ZQ9700999', date '2025-05-07', date '2025-11-03');

  if r.authorization_id is distinct from v_ph then
    failures := failures || 'FAILED: replacing a placeholder did not keep the same authorization'::text;
  elsif (select number from public.authorizations where id = v_ph) <> 'ZQ9700999'
     or (select carried_used from public.authorizations where id = v_ph) <> 12.5 then
    failures := failures || 'FAILED: the placeholder did not take the real number, or lost its carried hours'::text;
  elsif (select count(*) from public.authorizations where client_id = v_a) <> v_count then
    failures := failures || 'FAILED: replacing a placeholder made a second authorization'::text;
  elsif (select start_date from public.authorizations where id = v_ph) is distinct from date '2025-05-07' or not r.end_filled then
    failures := failures || 'FAILED: the confirmed dates were not filled on the replaced placeholder'::text;
  else
    raise notice 'ok  a placeholder takes its real number and dates, keeps its id and carried hours, and nothing is duplicated';
  end if;

  if not exists (select 1 from public.attachments where storage_path = 'inbox/zx/1.pdf' and auth_id = v_ph and category = 'Authorization')
     or (select state from public.inbox_documents where id = v_doc) <> 'Filed' then
    failures := failures || 'FAILED: the PDF did not end up on the replaced authorization, or the inbox still shows it waiting'::text;
  elsif not exists (select 1 from public.authorization_corrections
                     where auth_id = v_ph and field = 'Number' and was_value = '(workbook) coaching ZZ01'
                       and new_value = 'ZQ9700999' and staff_id = v_admin) then
    failures := failures || 'FAILED: the number change was not logged with what it was'::text;
  else
    raise notice 'ok  the PDF goes on it, the inbox shows it done, and the log says the number was the placeholder';
  end if;

  begin
    perform public.replace_placeholder_authorization(v_doc2, v_real, 'ZQ9700998');
    failures := failures || 'FAILED: a real authorization was renumbered as if it were a placeholder'::text;
  exception when check_violation then
    raise notice 'ok  only a "(workbook)" placeholder is replaced, never a real authorization';
  end;

  begin
    perform public.replace_placeholder_authorization(v_doc2, v_phB, 'ZQ9700997');
    failures := failures || 'FAILED: another client''s placeholder was replaced'::text;
  exception when check_violation then
    raise notice 'ok  a placeholder is replaced only from the same client''s document';
  end;

  insert into public.authorizations (client_id, number, service_type, rate_type, rate, total_hours, status)
  values (v_a, '(workbook) coaching ZZ03', 'Job Coaching', 'Hourly', 45, 40, 'Open') returning id into v_phB;
  begin
    perform public.replace_placeholder_authorization(v_doc2, v_phB, 'zq-970 0001');
    failures := failures || 'FAILED: a placeholder was given a number already on file'::text;
  exception when check_violation then
    raise notice 'ok  a number already on file, however it is written, is refused';
  end;

  if v_js is not null then
    perform set_config('request.jwt.claims', json_build_object('sub', v_js_uid, 'role', 'authenticated')::text, true);
    begin
      perform public.replace_placeholder_authorization(v_doc2, v_phB, 'ZQ9700996');
      failures := failures || 'FAILED: Job Search replaced a placeholder'::text;
    exception when insufficient_privilege then
      raise notice 'ok  only Admin and Billing replace a placeholder';
    end;
  end if;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  begin
    insert into public.authorization_corrections (auth_id, auth_number, field, was_value, new_value, reason)
    values (v_real, 'ZQ9700001', 'Document', 'scan.pdf', 'taken off', 'OCR shows another number');
    update public.attachments set review_note = 'OCR reads a different number' where storage_path = 'inbox/zx/1.pdf';
    raise notice 'ok  the log takes a document taken off an authorization, and a file takes a review note';
  exception when others then
    failures := failures || format('FAILED: the log or the review note refused a valid entry (%s)', sqlerrm);
  end;

  if failures = '{}' then
    raise notice '';
    raise notice '--- PLACEHOLDER REPLACEMENT VERIFIED ---';
  else
    raise notice '';
    raise notice '%  PROBLEM(S):', array_length(failures, 1);
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
