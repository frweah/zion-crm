-- Zion Vocational Rehab CRM — the client record at the centre (0109, 0110)
--
-- What has to hold, each tried from the direction that would break it:
--
--   Finding somebody is finding somebody you are allowed to find, and the
--   people you had open lately come first. A number typed with dashes finds
--   the record that stores it without them.
--
--   What is next for a client is the due things and only the due things: a
--   form holding up billing, an authorization running out with hours on it,
--   a text nobody answered, consent never recorded, a retention check that
--   has come round.
--
--   A signature is the means of signing as a person. Its owner reads it and
--   nobody else does - not Admin either.
--
--   The invoice a completed form has earned is raised once, as a Draft, for
--   what the hours come to, and never while a form is still outstanding.
--
--   The two moments the CRP billing pathway turns on say so when they
--   arrive: five shifts kept means the placement may be billed on USOR 92,
--   and thirty days of stability means the High Quality Indicators may be.
--   Neither can be dated before the placement started.
--
-- Uses made-up staff, clients and authorizations (ZZ). Runs inside a
-- transaction that is rolled back.

begin;

do $$
declare
  v_admin  uuid; v_admin_uid  uuid := gen_random_uuid();
  v_worker uuid; v_worker_uid uuid := gen_random_uuid();
  v_client uuid;
  v_other  uuid;
  v_auth   uuid;
  v_invoice uuid;
  v_again  uuid;
  v_placement uuid;
  v_n      integer;
  v_amount numeric;
  failures text[] := '{}';
begin
  insert into public.staff (name, email, role, active) values ('ZZ Centre Admin', 'zz-centre-admin@example.test', 'Admin', true) returning id into v_admin;
  insert into public.staff (name, email, role, active) values ('ZZ Centre Worker', 'zz-centre-worker@example.test', 'Job Search', true) returning id into v_worker;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_admin_uid,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-centre-admin@example.test',  '{}', '{}', now(), now()),
         (v_worker_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-centre-worker@example.test', '{}', '{}', now(), now());

  insert into public.clients (name, phone, stage, status, assigned_staff_id)
  values ('ZZ Centre Client', '801-555-0311', 'Job Coaching', 'Active', v_worker) returning id into v_client;
  insert into public.clients (name, stage, status, assigned_staff_id)
  values ('ZZ Centre Other', 'Intake', 'Active', v_worker) returning id into v_other;

  -- Job Coaching bills on USOR 93 and 95, both monthly.
  insert into public.authorizations (client_id, number, service_type, total_hours, rate_type, rate, start_date, end_date, status)
  values (v_client, 'V0000111', 'Job Coaching', 20, 'Hourly', 45, public.practice_today() - 30, public.practice_today() + 10, 'Open')
  returning id into v_auth;
  insert into public.service_entries (auth_id, date, hours, notes, non_billable, primary_code, secondary_code, staff_id)
  values (v_auth, public.practice_today() - 2, 4, 'ZZ coaching visit', false, '', '', v_worker);

  -- ── finding somebody ───────────────────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_worker_uid, 'role', 'authenticated')::text, true);

  if not exists (select 1 from public.search_clients('ZZ Centre Client') where id = v_client) then
    failures := failures || 'FAILED: a client could not be found by name'::text;
  end if;
  -- The number as somebody would type it off a sticky note.
  if not exists (select 1 from public.search_clients('(801) 555-0311') where id = v_client) then
    failures := failures || 'FAILED: a phone number written with punctuation found nobody'::text;
  end if;
  if exists (select 1 from public.search_clients('') ) then
    failures := failures || 'FAILED: an empty search returned somebody before anything had been opened'::text;
  end if;

  perform public.note_client_opened(v_client);
  if not exists (select 1 from public.search_clients('') where id = v_client and recent) then
    failures := failures || 'FAILED: a record just opened is not offered before anything is typed'::text;
  else
    raise notice 'ok  a client is found by name and by a number however it was written, and the last one opened comes first';
  end if;

  -- ── what is next ───────────────────────────────────────────
  -- Hours logged, no form: billing is being held up, and it says so.
  if not exists (select 1 from public.client_next_actions(v_client) where kind = 'form') then
    failures := failures || 'FAILED: hours logged with no form did not show as holding up billing'::text;
  end if;
  -- The authorization ends inside a month and has hours on it.
  if not exists (select 1 from public.client_next_actions(v_client) where kind = 'authorization') then
    failures := failures || 'FAILED: an authorization ending with hours on it was not raised'::text;
  end if;
  -- Nobody has said whether they may be texted.
  if not exists (select 1 from public.client_next_actions(v_client) where kind = 'consent') then
    failures := failures || 'FAILED: a client with no texting consent recorded was not raised'::text;
  end if;
  -- And a client with nothing against them has nothing due but the consent.
  select count(*) into v_n from public.client_next_actions(v_other) where kind <> 'consent';
  if v_n <> 0 then
    failures := failures || format('FAILED: a client with nothing recorded had %s things due', v_n)::text;
  else
    raise notice 'ok  what is next is the due things only: the form, the authorization running out, the consent never recorded';
  end if;

  -- ── a signature is nobody else's ───────────────────────────
  perform public.set_my_signature('signatures/zz-worker.png');
  if not public.have_my_signature() then
    failures := failures || 'FAILED: a signature was uploaded and the system says there is none'::text;
  end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_admin_uid, 'role', 'authenticated')::text, true);
  if exists (select 1 from public.staff_signatures where staff_id = v_worker) then
    failures := failures || 'FAILED: Admin can read somebody else''s signature'::text;
  end if;
  if public.have_my_signature() then
    failures := failures || 'FAILED: Admin was told they have a signature that is somebody else''s'::text;
  else
    raise notice 'ok  a signature is read by its owner and by nobody else, Admin included';
  end if;

  -- ── the invoice the paperwork has earned ───────────────────
  -- Nothing yet: USOR 93 and 95 are both still outstanding.
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  if public.billing_gate_met(v_auth) then
    failures := failures || 'FAILED: the billing gate passed with both forms outstanding'::text;
  end if;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_worker_uid, 'role', 'authenticated')::text, true);
  if public.draft_invoice_for_authorization(v_auth) is not null then
    failures := failures || 'FAILED: an invoice was raised while a form was still outstanding'::text;
  end if;

  -- Both forms signed, and now it is owed.
  perform set_config('role', 'postgres', true);
  insert into public.forms (template_id, client_id, auth_id, month, status, data, created_by, created_by_name, completed_by, completed_by_name)
  values ('usor93', v_client, v_auth, to_char(public.practice_today(), 'YYYY-MM'), 'Completed', '{}', v_worker, 'ZZ Centre Worker', v_worker, 'ZZ Centre Worker'),
         ('usor95', v_client, v_auth, to_char(public.practice_today(), 'YYYY-MM'), 'Completed', '{}', v_worker, 'ZZ Centre Worker', v_worker, 'ZZ Centre Worker');
  if not public.billing_gate_met(v_auth) then
    failures := failures || 'FAILED: the gate is still shut with every form signed'::text;
  end if;

  perform set_config('role', 'authenticated', true);
  v_invoice := public.draft_invoice_for_authorization(v_auth);
  if v_invoice is null then
    failures := failures || 'FAILED: no invoice was raised once the paperwork was complete'::text;
  else
    select amount into v_amount from public.invoices where id = v_invoice;
    -- Four hours at forty-five.
    if v_amount <> 180 then
      failures := failures || format('FAILED: the invoice was for %s, and the hours come to 180', v_amount)::text;
    end if;
    if (select status from public.invoices where id = v_invoice) <> 'Draft' then
      failures := failures || 'FAILED: the invoice was raised as something other than a Draft'::text;
    end if;
  end if;

  -- Asking again does not raise a second one.
  v_again := public.draft_invoice_for_authorization(v_auth);
  if v_again is not null then
    failures := failures || 'FAILED: asking twice raised two invoices for the same hours'::text;
  end if;
  select count(*) into v_n from public.invoices where auth_id = v_auth;
  if v_n <> 1 then
    failures := failures || format('FAILED: the authorization ended up with %s invoices', v_n)::text;
  else
    raise notice 'ok  the invoice the paperwork earned is raised once, as a Draft, for what the hours come to - and not before';
  end if;

  -- ── the two moments the pathway turns on (0111) ───────────
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  insert into public.placements (client_id, employer, title, start_date, wage, hours_week)
  values (v_client, 'ZZ Centre Employer', 'ZZ Job', public.practice_today() - 60, 15, 32)
  returning id into v_placement;

  -- A placement cannot be stable, or have worked its fifth shift, before it
  -- started.
  begin
    update public.placements set fifth_shift_on = public.practice_today() - 90 where id = v_placement;
    failures := failures || 'FAILED: a fifth shift was dated before the placement began'::text;
  exception when check_violation then null;
  end;
  begin
    update public.placements set stability_on = public.practice_today() - 90 where id = v_placement;
    failures := failures || 'FAILED: a placement was stable before it began'::text;
  exception when check_violation then null;
  end;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_worker_uid, 'role', 'authenticated')::text, true);
  if exists (select 1 from public.client_next_actions(v_client) where kind = 'placement') then
    failures := failures || 'FAILED: the placement was billable before any shift was recorded'::text;
  end if;

  perform set_config('role', 'postgres', true);
  update public.placements
     set shifts_worked = 5, fifth_shift_on = public.practice_today() - 40,
         stability_on = public.practice_today() - 31, stability_basis = 'SJBT'
   where id = v_placement;
  perform set_config('role', 'authenticated', true);

  if not exists (select 1 from public.client_next_actions(v_client) where kind = 'placement') then
    failures := failures || 'FAILED: five shifts kept did not make the placement billable'::text;
  end if;
  if not exists (select 1 from public.client_next_actions(v_client) where kind = 'stability') then
    failures := failures || 'FAILED: thirty days of stability did not raise the indicators'::text;
  else
    raise notice 'ok  five shifts kept and thirty days of stability each say so, and neither can predate the placement';
  end if;

  -- ── nobody signed in ───────────────────────────────────────
  perform set_config('request.jwt.claims', '', true);
  if has_function_privilege('anon', 'public.search_clients(text, integer)', 'execute')
     or has_function_privilege('anon', 'public.client_next_actions(uuid)', 'execute')
     or has_function_privilege('anon', 'public.set_my_signature(text)', 'execute')
     or has_function_privilege('anon', 'public.draft_invoice_for_authorization(uuid)', 'execute')
     or has_table_privilege('anon', 'public.staff_signatures', 'select')
     or has_table_privilege('anon', 'public.client_recents', 'select') then
    failures := failures || 'FAILED: somebody not signed in can reach the record centre'::text;
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- CLIENT RECORD CENTRE VERIFIED ---';
end $$;

rollback;
