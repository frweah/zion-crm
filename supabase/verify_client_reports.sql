-- A report is one of five (0276, 0277)
--
-- What has to hold:
--
--   The five templates are the five, and one report exists per client per
--   template per period - not one per month, which is what the old key said
--   and which would have refused a Job Coaching Update for a month that
--   already had a monthly report.
--
--   A weekly report's period is a Monday and the other four start a month.
--
--   Draft, Reviewed, Signed, Sent, in that order. A counselor only ever
--   receives a signed report, a sent one cannot be changed, and a signed one
--   is reopened - saying why - rather than edited.
--
--   The cover note says which period it covers, through both of the functions
--   that fill it in.
--
--   A records request says which of the five each report is.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_admin uuid; v_admin_uid uuid := gen_random_uuid();
  v_client uuid; v_counselor uuid;
  v_month uuid; v_coaching uuid; v_week uuid;
  v_body text; v_n integer; v_bundle jsonb; v_pdf uuid;
  failures text[] := '{}';
begin
  insert into public.staff (name, email, role, active)
  values ('ZZ Report Admin', 'zz-report-admin@example.test', 'Admin', true) returning id into v_admin;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_admin_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-report-admin@example.test', '{}', '{}', now(), now());

  insert into public.counselors (name, email) values ('ZQ Report Counselor', 'zq-counselor@example.test')
  returning id into v_counselor;
  insert into public.clients (name, stage, status, counselor_id, assigned_staff_id)
  values ('ZZ Report Client', 'Job Search', 'Active', v_counselor, v_admin) returning id into v_client;

  -- A signed report has a PDF, which client_reports_sent_pdf insists on. The
  -- assertions about the trigger below need every constraint on the row
  -- satisfied, or the constraint answers for the trigger.
  insert into public.attachments (client_id, storage_path, filename, mime_type, size_bytes,
                                  category, uploaded_by, uploaded_by_name, source)
  values (v_client, 'clients/zz/zz-report.pdf', 'zz-report.pdf', 'application/pdf', 2048,
          'Monthly report', v_admin, 'ZZ Report Admin', 'Staff')
  returning id into v_pdf;

  -- ── the five are the five ─────────────────────────────────
  select count(*) into v_n
    from (values ('Monthly client report'), ('Weekly job search update'), ('Job search report'),
                 ('Job Development Update'), ('Job Coaching Update')) t(k)
   where not exists (
     select 1 from pg_constraint
      where conrelid = 'public.client_reports'::regclass
        and conname = 'client_reports_template'
        and pg_get_constraintdef(oid) like '%' || t.k || '%');
  if v_n > 0 then
    failures := failures || format('FAILED: %s of the five templates are not accepted by the database', v_n);
  else
    raise notice 'ok  all five templates are accepted';
  end if;

  begin
    insert into public.client_reports (client_id, template, period, due_on, status)
    values (v_client, 'Something else', date_trunc('month', current_date)::date,
            current_date, 'Draft');
    failures := failures || 'FAILED: a template that is not one of the five was accepted'::text;
  exception when check_violation then
    raise notice 'ok  and nothing else is';
  end;

  -- ── one per client, per template, per period ──────────────
  insert into public.client_reports (client_id, template, period, due_on, status, owner_id)
  values (v_client, 'Monthly client report', '2026-09-01', '2026-10-07', 'Draft', v_admin)
  returning id into v_month;

  insert into public.client_reports (client_id, template, period, due_on, status, owner_id)
  values (v_client, 'Job Coaching Update', '2026-09-01', '2026-10-07', 'Draft', v_admin)
  returning id into v_coaching;
  raise notice 'ok  two different reports can cover the same month';

  begin
    insert into public.client_reports (client_id, template, period, due_on, status)
    values (v_client, 'Monthly client report', '2026-09-01', '2026-10-07', 'Draft');
    failures := failures || 'FAILED: the same report was made twice for the same month'::text;
  exception when unique_violation then
    raise notice 'ok  and the same one cannot be made twice';
  end;

  -- ── what a period may be ──────────────────────────────────
  begin
    insert into public.client_reports (client_id, template, period, due_on, status)
    values (v_client, 'Monthly client report', '2026-09-15', '2026-10-07', 'Draft');
    failures := failures || 'FAILED: a monthly report was made for the middle of a month'::text;
  exception when check_violation then null;
  end;

  -- 7 September 2026 is a Monday; the 8th is not.
  insert into public.client_reports (client_id, template, period, due_on, status, owner_id)
  values (v_client, 'Weekly job search update', '2026-09-07', '2026-09-14', 'Draft', v_admin)
  returning id into v_week;
  begin
    insert into public.client_reports (client_id, template, period, due_on, status)
    values (v_client, 'Weekly job search update', '2026-09-08', '2026-09-15', 'Draft');
    failures := failures || 'FAILED: a weekly report was made for a Tuesday'::text;
  exception when check_violation then
    raise notice 'ok  a month starts on the first and a week begins on a Monday';
  end;

  -- ── the order the statuses go in ──────────────────────────
  begin
    update public.client_reports set status = 'Sent', sent_at = now(), sent_to = 'zq@example.test'
     where id = v_month;
    failures := failures || 'FAILED: an unsigned report was sent to a counselor'::text;
  exception when check_violation then null;
  end;

  -- Signing and sending in one step is refused as well, with every column a
  -- Sent row needs filled in.
  --
  -- Worth saying what this does and does not prove. The row's own constraints
  -- do most of the work here - a Sent report must have a signed_at, a
  -- sent_to and a PDF - and when the trigger's "sign it before sending it"
  -- branch was removed, a constraint still refused this. So this assertion is
  -- about the rule holding, not about which of the two holds it; the
  -- assertion that the trigger is there at all is below. The first version of
  -- this script claimed the trigger and was wrong about it.
  begin
    update public.client_reports
       set status = 'Sent', sent_at = now(), sent_to = 'zq@example.test',
           signed_at = now(), signed_by = v_admin, pdf_attachment_id = v_pdf
     where id = v_month;
    failures := failures || 'FAILED: a report was signed and sent in one step, with nothing refusing it'::text;
  exception when check_violation then
    raise notice 'ok  a counselor only ever receives a signed report, with every column filled in';
  end;

  update public.client_reports set status = 'Reviewed', reviewed_at = now(), reviewed_by = v_admin
   where id = v_month;
  update public.client_reports set status = 'Signed', signed_at = now(), signed_by = v_admin
   where id = v_month;

  -- A signed one is reopened, saying why, rather than edited.
  begin
    update public.client_reports set note = 'ZQ changed after signing' where id = v_month;
    failures := failures || 'FAILED: a signed report was edited'::text;
  exception when check_violation then null;
  end;
  begin
    update public.client_reports set status = 'Draft' where id = v_month;
    failures := failures || 'FAILED: a signed report went back to draft with no reason given'::text;
  exception when check_violation then
    raise notice 'ok  a signed report is reopened, saying why, rather than edited';
  end;

  -- Reopening clears the signature, which is what the screen's own action
  -- does and what the constraint insists on: a report in draft with a
  -- signature on it would be a signed report somebody could edit.
  update public.client_reports
     set status = 'Draft', signed_at = null, signed_by = null,
         reopen_reason = 'ZQ the hours were wrong', reopened_by = v_admin
   where id = v_month;
  if (select reopened_at from public.client_reports where id = v_month) is null then
    failures := failures || 'FAILED: reopening did not record when'::text;
  else
    raise notice 'ok  and reopening records who and when';
  end if;

  -- ── and the rule has a trigger behind it as well ──────────
  -- The constraints cannot express "a step out of order" on their own: they
  -- see one row, not the row it was. So the trigger has to be there, and
  -- renaming the table in 0276 is exactly the kind of change that leaves a
  -- trigger behind on nothing.
  if not exists (
    select 1 from pg_trigger t join pg_proc p on p.oid = t.tgfoid
     where t.tgrelid = 'public.client_reports'::regclass and not t.tgisinternal
       and p.proname = 'report_moves_forward'
  ) then
    failures := failures || 'FAILED: nothing guards the order the statuses go in'::text;
  else
    raise notice 'ok  and a trigger guards the order, which a constraint on one row cannot';
  end if;

  -- ── the cover note says the period ────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_admin_uid, 'role', 'authenticated')::text, true);

  select body into v_body
    from public.mail_template_for('progress_report', v_client, null, '2026-09-01'::date);
  if v_body not like '%September 2026%' then
    failures := failures || format('FAILED: the cover note does not say the period: %s', left(v_body, 120));
  else
    raise notice 'ok  the cover note says which period it covers';
  end if;

  -- And through the pass-through the Compose screen actually calls, which is
  -- where it read "——" until 0277.
  select body into v_body
    from public.mail_templates_for(v_client, null, '2026-09-01'::date)
   where key = 'progress_report';
  if v_body not like '%September 2026%' then
    failures := failures || 'FAILED: the period does not reach the cover note through mail_templates_for'::text;
  else
    raise notice 'ok  and says it on the screen that offers the templates';
  end if;

  -- A cover note with no period says so rather than reading as though it had
  -- one.
  select body into v_body
    from public.mail_template_for('progress_report', v_client, null, null);
  if v_body like '%September%' or v_body not like '%——%' then
    failures := failures || 'FAILED: a cover note with no period does not show the gap'::text;
  else
    raise notice 'ok  and shows a gap when nothing said which period';
  end if;

  -- ── and only one of each function ─────────────────────────
  perform set_config('role', 'postgres', true);
  for v_body in select t from unnest(array['mail_template_for', 'mail_templates_for',
                                           'report_moves_forward']) t loop
    select count(*) into v_n from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = v_body;
    if v_n <> 1 then
      failures := failures || format('FAILED: %s exists %s times, not once', v_body, v_n);
    end if;
  end loop;
  raise notice 'ok  each of the three functions exists once, so a defaulted parameter made no second one';

  -- ── a records request says which of the five ──────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_admin_uid, 'role', 'authenticated')::text, true);
  v_bundle := public.records_request_bundle(v_client, 'ZQ checking the sections');

  if not (v_bundle ? 'reports') then
    failures := failures || 'FAILED: the bundle has no reports section'::text;
  elsif jsonb_array_length(v_bundle->'reports') < 3 then
    failures := failures || format('FAILED: the bundle discloses %s reports and the client has at least three',
                                   jsonb_array_length(v_bundle->'reports'));
  elsif not exists (
    select 1 from jsonb_array_elements(v_bundle->'reports') r
     where r->>'report' = 'Job Coaching Update'
  ) then
    failures := failures || 'FAILED: the bundle does not say which of the five each report is'::text;
  else
    raise notice 'ok  a records request discloses every report and says which of the five it is';
  end if;

  perform set_config('role', 'postgres', true);

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- CLIENT REPORTS VERIFIED ---';
end $$;

rollback;
