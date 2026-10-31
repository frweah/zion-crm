-- Zion Vocational Rehab CRM — the week, the month, and the order they go in (0260, 0261)
--
-- What has to hold, each tried from the direction that would break it:
--
--   A week starts on a Monday, and a confirmed week carries who confirmed it.
--
--   A month goes Draft, Reviewed, Signed, Sent and does not skip the
--   signature. "Drafts are never sent unsigned" is the brief's wording and
--   this is where it is true rather than where it is intended: a report sent
--   from a draft is refused, a report sent with nobody to send it to is
--   refused, a report sent with no PDF is refused, and a report that has gone
--   cannot be changed afterwards.
--
--   A signed month holds its weeks still, including the week that straddles
--   the month boundary — five times a year one week belongs to two months,
--   and it is the overlap that is tested rather than the easy case.
--
--   Reopening a signed report says why.
--
--   A report is as readable as what is in it: the person whose client it is
--   reads it whatever their role, a role the content is not for does not, and
--   Admin does.
--
--   Nobody signed in inserts one. The drafts are made by the scheduler, and a
--   report that exists because somebody typed it is not built from the record.
--
--   `zion-reports` is scheduled and active, because a draft nobody makes is
--   the whole feature missing and nothing else here would notice.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_client   uuid;
  v_owner    uuid; v_owner_uid uuid := gen_random_uuid();
  v_other    uuid; v_other_uid uuid := gen_random_uuid();
  v_admin    uuid; v_admin_uid uuid := gen_random_uuid();
  v_week     uuid;
  v_straddle uuid;
  v_free     uuid;   -- a week in a month nobody has signed
  v_month    uuid;
  v_pdf      uuid;
  -- A Monday, and the month it sits in. Fixed rather than taken from today,
  -- so this suite says the same thing whatever day it is run.
  v_monday   date := date '2026-10-19';
  v_mon_next date := date '2026-10-26';   -- the week straddling October and November
  v_oct      date := date '2026-10-01';
  v_n        integer;
  v_mark     integer;
  failures   text[] := '{}';
begin
  insert into public.staff (name, email, role, active)
  values ('ZZ Report Owner', 'zz-report-owner@example.test', 'Job Coach', true) returning id into v_owner;
  insert into public.staff (name, email, role, active)
  values ('ZZ Report Other', 'zz-report-other@example.test', 'Billing', true) returning id into v_other;
  insert into public.staff (name, email, role, active)
  values ('ZZ Report Admin', 'zz-report-admin@example.test', 'Admin', true) returning id into v_admin;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_owner_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-report-owner@example.test', '{}', '{}', now(), now()),
         (v_other_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-report-other@example.test', '{}', '{}', now(), now()),
         (v_admin_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-report-admin@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_owner_uid where id = v_owner;
  update public.staff set user_id = v_other_uid where id = v_other;
  update public.staff set user_id = v_admin_uid where id = v_admin;

  insert into public.clients (name, funding_source, status, stage, assigned_staff_id)
  values ('ZZ Reported Client', 'Utah VR', 'Active', 'Job Coaching', v_owner)
  returning id into v_client;

  -- ── 1. a week is a Monday, and confirming it is signing it ──
  begin
    insert into public.client_weekly_reports (client_id, week_start, owner_id, due_on)
    values (v_client, v_monday + 1, v_owner, v_monday + 10);
    failures := failures || 'FAILED: a week was allowed to start on a Tuesday'::text;
  exception when check_violation then null;
  end;

  begin
    insert into public.client_weekly_reports (client_id, week_start, owner_id, due_on, status)
    values (v_client, v_monday, v_owner, v_monday + 9, 'Confirmed');
    failures := failures || 'FAILED: a week was confirmed with nobody confirming it'::text;
  exception when check_violation then null;
  end;

  insert into public.client_weekly_reports (client_id, week_start, owner_id, due_on, content)
  values (v_client, v_monday, v_owner, v_monday + 9,
          jsonb_build_object('from', v_monday, 'to', v_monday + 6, 'sections', '[]'::jsonb, 'withheld', 0, 'hours', 0))
  returning id into v_week;

  -- The week that is in October and November at once.
  insert into public.client_weekly_reports (client_id, week_start, owner_id, due_on)
  values (v_client, v_mon_next, v_owner, v_mon_next + 9)
  returning id into v_straddle;

  -- December, which no month below is signed for. The readability tests need a
  -- week that can still be changed: the freeze is what sections 3 and 5 are
  -- about and testing one rule through another leaves both unclear.
  insert into public.client_weekly_reports (client_id, week_start, owner_id, due_on)
  values (v_client, date '2026-12-07', v_owner, date '2026-12-16')
  returning id into v_free;

  if array_length(failures, 1) is null then
    raise notice 'ok  a week starts on a Monday and carries who confirmed it';
  end if;

  -- ── 2. and a month goes one way ───────────────────────────
  --
  -- The PDF exists before any of this is tried, which matters more than it
  -- looks. The first version of this section attempted Sent from Draft with
  -- no PDF, and passed with the status trigger dropped: the row was refused
  -- by `client_reports_sent_pdf` and the test could not tell the
  -- difference between "it would not skip the signature" and "it had no PDF".
  -- Everything else about the attempt below is right, so the only rule it
  -- breaks is the order.
  v_mark := coalesce(array_length(failures, 1), 0);
  insert into public.attachments (client_id, storage_path, filename, mime_type, size_bytes, category, uploaded_by)
  values (v_client, 'zz/report.pdf', 'ZZ October report.pdf', 'application/pdf', 1024, 'Monthly report', v_owner)
  returning id into v_pdf;

  insert into public.client_reports (client_id, period, owner_id, due_on)
  values (v_client, v_oct, v_owner, public.monthly_report_due_on(v_oct))
  returning id into v_month;

  if (select due_on from public.client_reports where id = v_month) <> date '2026-11-05' then
    failures := failures || 'FAILED: October is not due on 5 November'::text;
  end if;

  -- Sent straight from a draft: the one the brief names.
  begin
    update public.client_reports
       set status = 'Sent', sent_at = now(), sent_to = 'zq-counselor@example.test',
           signed_at = now(), signed_by = v_owner, pdf_attachment_id = v_pdf
     where id = v_month;
    failures := failures || 'FAILED: a draft was sent without being signed'::text;
    -- Put it back. Without this the row is left Sent, the next statement in
    -- this section raises a constraint error of its own, and a dropped
    -- trigger is reported as a database message instead of as the sentence
    -- above - which is the difference between a check that names the fault
    -- and one that merely stops.
    update public.client_reports
       set status = 'Draft', sent_at = null, sent_to = '',
           signed_at = null, signed_by = null, pdf_attachment_id = null
     where id = v_month;
  exception when check_violation then null;
  end;

  update public.client_reports set status = 'Reviewed', reviewed_at = now(), reviewed_by = v_owner
   where id = v_month;
  update public.client_reports set status = 'Signed', signed_at = now(), signed_by = v_owner
   where id = v_month;

  -- Signed with nothing to send it to, and signed with no PDF.
  begin
    update public.client_reports set status = 'Sent', sent_at = now() where id = v_month;
    failures := failures || 'FAILED: a report was sent to nobody'::text;
  exception when check_violation then null;
  end;

  begin
    update public.client_reports
       set status = 'Sent', sent_at = now(), sent_to = 'zq-counselor@example.test'
     where id = v_month;
    failures := failures || 'FAILED: a report was sent with no PDF attached'::text;
  exception when check_violation then null;
  end;

  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice 'ok  a month is signed before it is sent, to somebody, with the PDF that was signed';
  end if;

  -- ── 3. a signed month holds its weeks still ───────────────
  v_mark := coalesce(array_length(failures, 1), 0);
  begin
    update public.client_weekly_reports set note = 'ZZ changed after signing' where id = v_week;
    failures := failures || 'FAILED: a week inside a signed month was changed'::text;
  exception when check_violation then null;
  end;

  begin
    update public.client_weekly_reports set note = 'ZZ changed after signing' where id = v_straddle;
    failures := failures || 'FAILED: the week straddling the signed month was changed'::text;
  exception when check_violation then null;
  end;

  begin
    delete from public.client_weekly_reports where id = v_week;
    failures := failures || 'FAILED: a week inside a signed month was deleted'::text;
  exception when check_violation then null;
  end;

  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice 'ok  a signed month freezes its weeks, the straddling one included';
  end if;

  -- ── 4. reopening says why ─────────────────────────────────
  v_mark := coalesce(array_length(failures, 1), 0);
  begin
    update public.client_reports set status = 'Draft', signed_at = null, signed_by = null
     where id = v_month;
    failures := failures || 'FAILED: a signed report was reopened without a reason'::text;
  exception when check_violation then null;
  end;

  update public.client_reports
     set status = 'Draft', signed_at = null, signed_by = null,
         reopen_reason = 'ZZ the hours for the 14th were logged against the wrong authorization'
   where id = v_month;
  if (select reopened_at from public.client_reports where id = v_month) is null then
    failures := failures || 'FAILED: reopening a report was not recorded'::text;
  end if;

  -- And the weeks move again, which is the point of reopening.
  update public.client_weekly_reports set note = 'ZZ fixed after reopening' where id = v_week;
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    failures := failures || 'FAILED: reopening the month did not release its weeks'::text;
  end if;

  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice 'ok  reopening a signed report says why, and releases the weeks it held';
  end if;

  -- ── 5. a sent report is finished ──────────────────────────
  v_mark := coalesce(array_length(failures, 1), 0);
  update public.client_reports
     set status = 'Signed', signed_at = now(), signed_by = v_owner, pdf_attachment_id = v_pdf
   where id = v_month;
  update public.client_reports
     set status = 'Sent', sent_at = now(), sent_by = v_owner, sent_to = 'zq-counselor@example.test'
   where id = v_month;

  begin
    update public.client_reports set note = 'ZZ changed after sending' where id = v_month;
    failures := failures || 'FAILED: a report was changed after it had been sent'::text;
  exception when check_violation then null;
  end;

  begin
    update public.client_reports set status = 'Draft', signed_at = null, signed_by = null,
           reopen_reason = 'ZZ with a reason, which should not be enough'
     where id = v_month;
    failures := failures || 'FAILED: a sent report was reopened'::text;
  exception when check_violation then null;
  end;

  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice 'ok  a report that has gone to the counselor is finished';
  end if;

  -- ── 6. as readable as what is in it ───────────────────────
  --
  -- The owner's role is Job Coach, which is not one of the four roles an
  -- ordinary note is visible to - so this is the case the read policy's second
  -- half exists for, and it is tested as the role rather than asserted as a
  -- policy.
  v_mark := coalesce(array_length(failures, 1), 0);
  update public.client_weekly_reports
     set visible_roles = array['Admin', 'Job Search', 'Reports', 'Billing']
   where id = v_free;

  perform set_config('role', 'authenticated', true);

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner_uid, 'role', 'authenticated')::text, true);
  select count(*) into v_n from public.client_weekly_reports where id = v_free;
  if v_n <> 1 then
    failures := failures || 'FAILED: the person whose client it is cannot read their own week'::text;
  end if;

  -- Nobody signed in makes one.
  begin
    insert into public.client_weekly_reports (client_id, week_start, owner_id, due_on)
    values (v_client, v_monday - 7, v_owner, v_monday + 2);
    failures := failures || 'FAILED: somebody signed in wrote a weekly report by hand'::text;
  exception when insufficient_privilege or check_violation then null;
  end;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_other_uid, 'role', 'authenticated')::text, true);
  update public.client_weekly_reports set note = 'ZZ not mine to change' where id = v_free;
  get diagnostics v_n = row_count;
  if v_n <> 0 then
    failures := failures || 'FAILED: somebody changed a week that is not theirs'::text;
  end if;

  -- The same person, now with the content narrowed away from their role.
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  update public.client_weekly_reports set visible_roles = array['Admin'] where id = v_free;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_other_uid, 'role', 'authenticated')::text, true);
  select count(*) into v_n from public.client_weekly_reports where id = v_free;
  if v_n <> 0 then
    failures := failures || 'FAILED: a report narrowed away from somebody''s role was still readable'::text;
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin_uid, 'role', 'authenticated')::text, true);
  select count(*) into v_n from public.client_weekly_reports where id = v_free;
  if v_n <> 1 then
    failures := failures || 'FAILED: Admin cannot read a report'::text;
  end if;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice 'ok  a report is read by its owner and by Admin, and not by a role it is not for';
  end if;

  -- ── 7. and nobody not signed in is anywhere near it ───────
  v_mark := coalesce(array_length(failures, 1), 0);
  for v_n in 1..1 loop
    if has_table_privilege('anon', 'public.client_weekly_reports', 'select')
       or has_table_privilege('anon', 'public.client_reports', 'select') then
      failures := failures || 'FAILED: anon can read the reports'::text;
    end if;
    if has_table_privilege('authenticated', 'public.client_weekly_reports', 'insert')
       or has_table_privilege('authenticated', 'public.client_reports', 'insert') then
      failures := failures || 'FAILED: authenticated holds INSERT on a report table'::text;
    end if;
    if has_table_privilege('authenticated', 'public.client_weekly_reports', 'truncate')
       or has_table_privilege('authenticated', 'public.client_reports', 'truncate') then
      failures := failures || 'FAILED: authenticated holds TRUNCATE on a report table'::text;
    end if;
  end loop;
  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice 'ok  anon reads neither table and authenticated inserts into neither';
  end if;

  -- ── 8. the drafts are actually made ──────────────────────
  --
  -- Everything above is about a report that exists. This is the one that
  -- notices if none ever does: `zion-reports` scheduled, daily, and switched
  -- on. It is asked of the catalogue because a job can be turned off from the
  -- dashboard without any migration changing.
  v_mark := coalesce(array_length(failures, 1), 0);
  select count(*) into v_n
    from cron.job
   where jobname = 'zion-reports' and active
     and command like '%/api/cron/reports%';
  if v_n <> 1 then
    failures := failures || 'FAILED: zion-reports is not scheduled and active, so no report is ever drafted'::text;
  end if;

  -- The note gate's meaning depends on this default. If an ordinary note
  -- stops being visible to these four, `REPORT_ROLES` in
  -- lib/report-period.ts is holding back the wrong things and nothing else
  -- would say so.
  if (select pg_get_expr(d.adbin, d.adrelid)
        from pg_attrdef d
        join pg_attribute a on a.attrelid = d.adrelid and a.attnum = d.adnum
       where d.adrelid = 'public.notes'::regclass and a.attname = 'visible_roles')
     is distinct from 'ARRAY[''Admin''::text, ''Job Search''::text, ''Reports''::text, ''Billing''::text]'
  then
    failures := failures ||
      'FAILED: an ordinary note is no longer visible to the four roles REPORT_ROLES names'::text;
  end if;

  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice 'ok  zion-reports is scheduled and the note gate still matches the note default';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- MONTHLY AND WEEKLY REPORTS VERIFIED ---';
end $$;

rollback;
