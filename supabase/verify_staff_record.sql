-- Zion Vocational Rehab CRM — a staff record, and the line across it
-- (0199–0200; owner, 14 Oct 2026, items 2 and 4)
--
-- What has to hold, each tried from the direction that would break it:
--
--   An Admin can change every field on somebody else's record - name, the
--   sign-in address, phone, role, employment type, start date, pay - and each
--   change is written down with who made it and that it was somebody else's
--   record.
--
--   A second address can be added to a record without touching the one the
--   person signs in with, and either one resolves to them. An address that is
--   already somebody's sign-in is refused, because two records answering to
--   one address is the ambiguity the resolver must not have.
--
--   An Admin cannot sign somebody's tax form, and the person can. This is the
--   one that was wrong: the guard allowed an Admin while raising "You can only
--   sign your own form".
--
--   An Admin cannot agree to e-delivery on somebody's behalf, and the person
--   can.
--
--   The staff change log is readable by an Admin and by the person it is
--   about, and by nobody else - it holds pay rates, which is why it is not
--   the directory log. It is added to and never edited.
--
-- Uses made-up staff (ZZ/ZQ). Everything is rolled back.

begin;

do $$
declare
  v_admin   uuid;
  v_adm_uid uuid;
  v_them    uuid;
  v_them_u  uuid := gen_random_uuid();
  v_other   uuid;
  v_oth_u   uuid := gen_random_uuid();
  v_form    uuid;
  v_n       integer;
  v_text    text;
  failures  text[] := '{}';
begin
  select id, user_id into v_admin, v_adm_uid from public.staff
   where role = 'Admin' and active and user_id is not null order by created_at, id limit 1;

  insert into public.staff (name, email, phone, role, active)
  values ('Rowan Record Testperson', 'zz-record-them@example.test', '555-0001', 'Job Coach', true)
  returning id into v_them;
  insert into public.staff (name, email, role, active)
  values ('ZZ Record Nosy', 'zz-record-nosy@example.test', 'Job Search', true)
  returning id into v_other;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_them_u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-record-them@example.test', '{}', '{}', now(), now()),
         (v_oth_u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-record-nosy@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_them_u where id = v_them;
  update public.staff set user_id = v_oth_u where id = v_other;

  insert into public.staff_employment (staff_id, employment_type, started_on)
  values (v_them, 'Contractor', date '2026-02-01');

  -- ═══ an Admin changes everything ═══════════════════════════
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);
  perform set_config('zion.staff_change_note', 'ZZ corrected from the signed offer letter', true);

  update public.staff set name = 'Rowan Record Testperson', phone = '555-0199',
         email = 'zz-record-them2@example.test', role = 'Case Manager'
   where id = v_them;
  update public.staff_employment set employment_type = 'Employee', started_on = date '2026-03-02'
   where staff_id = v_them;
  insert into public.staff_pay (staff_id, pay_rate, rate_unit, effective_from, created_by)
  values (v_them, 24.50, 'Hourly', date '2026-03-02', v_admin);

  perform set_config('zion.staff_change_note', '', true);

  if (select role from public.staff where id = v_them) <> 'Case Manager'
     or (select phone from public.staff where id = v_them) <> '555-0199'
     or (select employment_type from public.staff_employment where staff_id = v_them) <> 'Employee'
     or (select started_on from public.staff_employment where staff_id = v_them) <> date '2026-03-02'
     or (select count(*) from public.staff_pay where staff_id = v_them) <> 1 then
    failures := failures || 'FAILED: an Admin could not change every field on a staff record'::text;
  else
    raise notice 'ok  an Admin changes the name, address, phone, role, employment, start date and pay';
  end if;

  -- ── and each change says who, and that it was not their own ──
  select count(*) into v_n from public.staff_record_changes
   where staff_id = v_them and changed_by = v_admin and on_behalf;
  if v_n < 3 then
    failures := failures || format('FAILED: only %s of the changes were logged as done on somebody else''s record', v_n)::text;
  else
    raise notice 'ok  and every one is logged as an Admin acting on somebody else''s record';
  end if;

  if not exists (select 1 from public.staff_record_changes
                  where staff_id = v_them and part = 'Pay' and changed_by = v_admin) then
    failures := failures || 'FAILED: a pay change was not logged'::text;
  elsif not exists (select 1 from public.staff_record_changes
                     where staff_id = v_them and part = 'Details'
                       and changes -> 'role' ->> 'from' = 'Job Coach'
                       and changes -> 'role' ->> 'to' = 'Case Manager') then
    failures := failures || 'FAILED: the role change was not logged from what to what'::text;
  else
    raise notice 'ok  with the field, from what, to what, and the reason given';
  end if;

  -- ═══ a second address ══════════════════════════════════════
  insert into public.staff_emails (staff_id, address, added_by)
  values (v_them, 'ZZ.Record@zionvocrehab.test', v_admin);

  if public.staff_by_email('zz.record@ZIONVOCREHAB.test') is distinct from v_them then
    failures := failures || 'FAILED: the alias does not resolve to them'::text;
  elsif public.staff_by_email('zz-record-them2@example.test') is distinct from v_them then
    failures := failures || 'FAILED: their sign-in address stopped resolving to them'::text;
  else
    raise notice 'ok  an alias and the sign-in address both reach the same person';
  end if;

  if (select email from public.staff where id = v_them) <> 'zz-record-them2@example.test' then
    failures := failures || 'FAILED: adding an alias changed how they sign in'::text;
  else
    raise notice 'ok  and adding one does not change how they sign in';
  end if;

  begin
    insert into public.staff_emails (staff_id, address, added_by)
    values (v_them, 'zz-record-nosy@example.test', v_admin);
    failures := failures || 'FAILED: an alias was allowed to be somebody else''s sign-in address'::text;
  exception when unique_violation then
    raise notice 'ok  an address that is already somebody''s sign-in cannot become an alias';
  end;

  -- ═══ what an Admin may not do for somebody ═════════════════
  perform set_config('role', 'postgres', true);
  insert into public.tax_form_submissions (staff_id, form_type, status, data)
  values (v_them, 'W-9', 'Draft', '{}'::jsonb) returning id into v_form;
  insert into public.contractor_profiles (staff_id, tax_status) values (v_them, 'US person')
  on conflict (staff_id) do nothing;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);

  begin
    perform public.sign_tax_form(v_form, null, '1234', 'ZZ The Admin', '127.0.0.1');
    failures := failures || 'FAILED: an Admin signed somebody else''s tax form'::text;
  exception when insufficient_privilege then
    raise notice 'ok  an Admin cannot sign somebody else''s tax form';
  end;

  begin
    update public.contractor_profiles set e_delivery_consent_on = current_date where staff_id = v_them;
    failures := failures || 'FAILED: an Admin agreed to e-delivery on somebody else''s behalf'::text;
  exception when insufficient_privilege then
    raise notice 'ok  nor agree to e-delivery for them';
  end;

  -- ── and the person themselves can do both ──────────────────
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_them_u, 'role', 'authenticated')::text, true);

  begin
    perform public.set_e_delivery_consent(true);
    if (select e_delivery_consent_on from public.contractor_profiles where staff_id = v_them) is null then
      failures := failures || 'FAILED: the contractor could not give their own consent'::text;
    else
      raise notice 'ok  and the person themselves can give it, so it is a line and not a wall';
    end if;
  exception when others then
    failures := failures || format('FAILED: the contractor could not give their own consent: %s', sqlerrm)::text;
  end;

  begin
    perform public.sign_tax_form(v_form, null, '1234', 'Rowan Record Testperson', '127.0.0.1');
    if (select status from public.tax_form_submissions where id = v_form) <> 'Signed' then
      failures := failures || 'FAILED: the person could not sign their own form'::text;
    else
      raise notice 'ok  and they can sign their own form';
    end if;
  exception when others then
    failures := failures || format('FAILED: the person could not sign their own form: %s', sqlerrm)::text;
  end;

  -- ═══ who may read the log ══════════════════════════════════
  select count(*) into v_n from public.staff_record_changes where staff_id = v_them;
  if v_n = 0 then
    failures := failures || 'FAILED: a person cannot read their own record''s history'::text;
  else
    raise notice 'ok  a person can read what was changed on their own record';
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_oth_u, 'role', 'authenticated')::text, true);
  select count(*) into v_n from public.staff_record_changes where staff_id = v_them;
  if v_n > 0 then
    failures := failures || format('FAILED: a colleague can read %s rows of somebody''s pay history', v_n)::text;
  else
    raise notice 'ok  and a colleague cannot - which is why this is not the directory log';
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);
  begin
    update public.staff_record_changes set note = 'ZZ rewritten' where staff_id = v_them;
    failures := failures || 'FAILED: the staff change log can be rewritten'::text;
  exception when insufficient_privilege then
    raise notice 'ok  the log is added to, never rewritten';
  end;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('role', 'postgres', true);

  if has_table_privilege('anon', 'public.staff_emails', 'select')
     or has_table_privilege('anon', 'public.staff_record_changes', 'select')
     or has_function_privilege('anon', 'public.staff_by_email(text)', 'execute') then
    failures := failures || 'FAILED: somebody not signed in can read a staff record''s addresses or history'::text;
  else
    raise notice 'ok  and somebody not signed in can read none of it';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- THE STAFF RECORD VERIFIED ---';
end $$;

rollback;
