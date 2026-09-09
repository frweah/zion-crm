-- Zion Vocational Rehab CRM — onboarding checklist and staff report
--
-- A checklist is only worth having if it cannot say "done" about something
-- that is not. So the rules here are: an automatic item cannot be ticked at
-- all, it turns true only when the underlying fact turns true, and nobody sees
-- anybody else's — least of all a derived answer computed from rows they
-- cannot read, which would come back false and look like a finding.
--
-- Runs inside a transaction that is rolled back. Nothing here is left behind.

begin;

do $$
declare
  v_admin    uuid;
  v_adm_uid  uuid;
  v_rei      uuid;
  v_rei_uid  uuid;
  v_marg     uuid;
  v_auto     uuid;
  v_manual   uuid;
  v_count    int;
  v_hours    numeric;
  v_paid     numeric;
  failures   text[] := '{}';
begin
  select id, user_id into v_admin, v_adm_uid from public.staff where legacy_id = 's1';
  select id, user_id into v_rei,  v_rei_uid  from public.staff where legacy_id = 's2';
  select id             into v_marg          from public.staff where legacy_id = 's3';

  select id into v_auto   from public.checklist_tasks where auto_key = 'tax_form_signed';
  select id into v_manual from public.checklist_tasks
   where auto_key is null and phase = 'Onboarding' order by sort_order limit 1;

  -- The tax-form checks below describe a person who has not yet signed one.
  -- Rei has now signed hers for real, so the fixture starts by clearing the
  -- forms inside this transaction — which is rolled back, leaving her real
  -- W-8BEN untouched. Asserting "starts undone" against live data was only
  -- ever going to hold until somebody used the feature.
  delete from public.tax_form_submissions where staff_id = v_rei;
  update public.contractor_profiles
     set w8ben_received_on = null, w9_received_on = null
   where staff_id = v_rei;

  -- ── an automatic item cannot be ticked ─────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);

  begin
    perform public.set_checklist_item(v_rei, v_auto, true, 'not true');
    failures := failures || 'FAILED: an automatic item was ticked by hand'::text;
  exception when check_violation then
    raise notice 'ok  an automatic item cannot be ticked, even by Admin';
  end;

  -- ── it turns true when the fact turns true ─────────────────
  if (select auto_done from public.staff_checklist
       where staff_id = v_rei and task_id = v_auto) then
    failures := failures || 'FAILED: the tax form item was already done'::text;
  else
    raise notice 'ok  the tax form item starts undone, because no form is signed';
  end if;

  insert into public.contractor_profiles (staff_id, tax_status)
  values (v_rei, 'Foreign person')
  on conflict (staff_id) do update set tax_status = 'Foreign person', w9_received_on = null;

  insert into public.tax_form_submissions (staff_id, form_type, status, data)
  values (v_rei, 'W-8BEN', 'Draft', '{}'::jsonb);

  if (select auto_done from public.staff_checklist
       where staff_id = v_rei and task_id = v_auto) then
    failures := failures || 'FAILED: an unsigned draft counted as a signed form'::text;
  else
    raise notice 'ok  a draft does not count — only a signed form does';
  end if;

  update public.tax_form_submissions
     set status = 'Signed', signed_at = now(), signer_name = 'ZZ Verify'
   where staff_id = v_rei and status = 'Draft';

  if not (select auto_done from public.staff_checklist
           where staff_id = v_rei and task_id = v_auto) then
    failures := failures || 'FAILED: signing the form did not complete the item'::text;
  else
    raise notice 'ok  signing the form completes the item, with nobody ticking anything';
  end if;

  -- The right form for the engagement, not merely any signed form.
  update public.contractor_profiles set tax_status = 'US person', w8ben_received_on = null
   where staff_id = v_rei;
  if (select auto_done from public.staff_checklist
       where staff_id = v_rei and task_id = v_auto) then
    failures := failures || 'FAILED: a W-8BEN counted for somebody who now owes a W-9'::text;
  else
    raise notice 'ok  the item follows the form required, not any form signed';
  end if;

  -- ── a manual item is Admin's to tick ───────────────────────
  perform public.set_checklist_item(v_rei, v_manual, true, 'checked with them');
  if (select done_on from public.staff_checklist
       where staff_id = v_rei and task_id = v_manual) is null then
    failures := failures || 'FAILED: a manual item could not be ticked'::text;
  else
    raise notice 'ok  a manual item can be ticked, and records who and when';
  end if;

  perform public.set_checklist_item(v_rei, v_manual, false, '');
  if (select done_on from public.staff_checklist
       where staff_id = v_rei and task_id = v_manual) is not null then
    failures := failures || 'FAILED: a manual item could not be unticked'::text;
  else
    raise notice 'ok  a manual item can be unticked, because people get it wrong';
  end if;

  -- ── the owner is not onboarded by anybody ──────────────────
  if exists (select 1 from public.staff_checklist
              where staff_id = v_admin and auto_key = 'tax_form_signed') then
    failures := failures || 'FAILED: the owner is being asked for a W-9'::text;
  else
    raise notice 'ok  the owner is not asked to file a form with themselves';
  end if;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  -- ── nobody sees anybody else's ─────────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_rei_uid, 'role', 'authenticated')::text, true);

  select count(distinct staff_id) into v_count from public.staff_checklist;
  if v_count <> 1 then
    failures := failures || format('FAILED: a contractor saw %s people''s checklists', v_count);
  else
    raise notice 'ok  a contractor sees only their own checklist';
  end if;

  if exists (select 1 from public.staff_checklist where staff_id = v_marg) then
    failures := failures || 'FAILED: a colleague''s checklist was visible'::text;
  else
    raise notice 'ok  a colleague''s checklist is not visible, right or wrong';
  end if;

  begin
    perform public.set_checklist_item(v_rei, v_manual, true, 'signing myself off');
    failures := failures || 'FAILED: a contractor ticked their own checklist'::text;
  exception when insufficient_privilege then
    raise notice 'ok  nobody signs off their own checklist';
  end;

  -- ── the staff report answers per caller ────────────────────
  select count(*) into v_count from public.staff_activity(
    make_date(2020, 1, 1), make_date(2035, 12, 31));
  if v_count = 0 then
    failures := failures || 'FAILED: the staff report returned nothing to a contractor'::text;
  else
    raise notice 'ok  a contractor gets a staff report';
  end if;

  select amount_paid into v_paid from public.staff_activity(
    make_date(2020, 1, 1), make_date(2035, 12, 31)) where staff_id = v_marg;
  if coalesce(v_paid, 0) <> 0 then
    failures := failures || format('FAILED: a contractor saw %s of a colleague''s pay', v_paid);
  else
    raise notice 'ok  a contractor sees nothing of a colleague''s pay';
  end if;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  -- ── hours are counted where they were worked ───────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);

  insert into public.work_sessions (staff_id, worked_on, hours, description, created_by)
  values (v_rei, make_date(2033, 3, 10), 4.5, 'ZZ verify', v_admin),
         (v_rei, make_date(2033, 3, 10), 2.0, 'ZZ verify same day', v_admin),
         (v_rei, make_date(2033, 7, 1),  3.0, 'ZZ verify later', v_admin);

  select hours into v_hours from public.staff_activity(
    make_date(2033, 1, 1), make_date(2033, 6, 30)) where staff_id = v_rei;
  if v_hours is distinct from 6.5 then
    failures := failures || format('FAILED: the period total came to %s, expected 6.5', v_hours);
  else
    raise notice 'ok  hours fall in the period the work was done, not the period asked about';
  end if;

  select days_worked into v_count from public.staff_activity(
    make_date(2033, 1, 1), make_date(2033, 12, 31)) where staff_id = v_rei;
  if v_count <> 2 then
    failures := failures || format('FAILED: days worked came to %s, expected 2', v_count);
  else
    raise notice 'ok  two sessions on one day is one day worked';
  end if;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  if failures = '{}' then
    raise notice '';
    raise notice '--- CHECKLIST AND STAFF REPORT VERIFIED ---';
  else
    raise notice '';
    raise notice '%  PROBLEM(S):', array_length(failures, 1);
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
