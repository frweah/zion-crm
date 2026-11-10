-- Zion Vocational Rehab CRM — the weekly update (0338, 0339)
--
-- What has to hold:
--
--   **Nothing a member of staff wrote about a client can reach the text.**
--   This is the one that matters: the draft is assembled from counts and
--   dates, so there is no path from a note, a contact log entry, a report or
--   an authorization into a text a client reads. The case below puts a
--   distinctive sentence in a note, a contact log entry and a report, and
--   asserts that none of them is in the body.
--
--   One draft per active client and per contact who receives updates, and
--   none for a closed client or a contact who does not.
--
--   Running the sweep again leaves an edited draft alone.
--
--   A week with nothing in it asks a question rather than reporting an
--   absence.
--
--   Only an approved draft can be recorded as sent, only the text that was
--   actually for it counts, and a sent one cannot be rewritten.
--
--   A draft nobody acted on is logged as not sent once its week has ended,
--   with the reason, and this week's are left alone.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_admin uuid; v_admin_uid uuid := gen_random_uuid();
  v_coach uuid; v_coach_uid uuid := gen_random_uuid();
  v_active uuid; v_closed uuid;
  v_gets uuid; v_not uuid;
  v_week date; v_last date;
  v_draft uuid; v_contact_draft uuid; v_old uuid;
  v_body text; v_text text; v_n integer; v_state text;
  v_sms uuid;
  k_secret text := 'ZQ-SECRET-NOT-FOR-A-CLIENT';
  failures text[] := '{}';
begin
  -- The Monday of this week, and of last week.
  v_week := (public.practice_today()
             - ((extract(isodow from public.practice_today())::integer - 1) * interval '1 day'))::date;
  v_last := v_week - 7;

  insert into public.staff (name, email, role, active)
  values ('ZZ Updates Admin', 'zz-updates-admin@example.test', 'Admin', true) returning id into v_admin;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_admin_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-updates-admin@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_admin_uid where id = v_admin;

  insert into public.staff (name, email, role, active)
  values ('ZZ Updates Coach', 'zz-updates-coach@example.test', 'Job Coach', true) returning id into v_coach;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_coach_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-updates-coach@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_coach_uid where id = v_coach;

  insert into public.clients (name, stage, status, assigned_staff_id, phone)
  values ('ZZ Updated Person', 'Job Search', 'Active', v_admin, '+13855550301') returning id into v_active;
  insert into public.clients (name, stage, status, assigned_staff_id, phone)
  values ('ZZ Finished Person', 'Job Search', 'Closed', v_admin, '+13855550302') returning id into v_closed;

  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_admin_uid, 'role', 'authenticated')::text, true);

  v_gets := public.add_client_contact(v_active, 'ZZ Her', 'daughter-in-law',
                                      '+13855550303', 'Mobile', '', true, false);
  v_not  := public.add_client_contact(v_active, 'ZZ Him', 'brother',
                                      '+13855550304', 'Mobile', '', false, false);

  -- ── everything a member of staff wrote about them ──────────
  insert into public.notes (client_id, staff_id, staff_name, text, type, visible_roles)
  values (v_active, v_admin, 'ZZ Updates Admin', k_secret, 'General', array['Admin']);
  insert into public.contact_log (client_id, date, method, topic, outcome, staff_id)
  values (v_active, public.practice_today() - 1, 'Phone call', k_secret, k_secret, v_admin);
  insert into public.client_weekly_reports (client_id, week_start, owner_id, status, due_on, content, note)
  values (v_active, v_week, v_admin, 'Draft', v_week + 6,
          jsonb_build_object('sections', jsonb_build_array(jsonb_build_object('lines',
            jsonb_build_array(jsonb_build_object('text', k_secret))))), k_secret);

  -- ── the sweep ──────────────────────────────────────────────
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  v_n := public.draft_weekly_updates(v_week);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_admin_uid, 'role', 'authenticated')::text, true);

  select id, body into v_draft, v_body from public.weekly_updates
   where week_start = v_week and client_id = v_active and contact_id is null;
  select id into v_contact_draft from public.weekly_updates
   where week_start = v_week and contact_id = v_gets;

  if v_draft is null then
    failures := failures || 'FAILED: an active client got no draft'::text;
  elsif v_contact_draft is null then
    failures := failures || 'FAILED: a contact who receives updates got no draft'::text;
  elsif exists (select 1 from public.weekly_updates where contact_id = v_not) then
    failures := failures || 'FAILED: a contact who does not receive updates got one'::text;
  elsif exists (select 1 from public.weekly_updates where client_id = v_closed) then
    failures := failures || 'FAILED: a closed client got a draft'::text;
  else
    raise notice 'ok  one draft per active client and per contact who receives them, and no others';
  end if;

  -- ── and nothing anybody wrote is in it ─────────────────────
  if v_body like '%' || k_secret || '%' then
    failures := failures || 'FAILED: something a member of staff wrote reached the text'::text;
  elsif (select body from public.weekly_updates where id = v_contact_draft) like '%' || k_secret || '%' then
    failures := failures || 'FAILED: something a member of staff wrote reached the contact''s text'::text;
  else
    raise notice 'ok  nothing a member of staff wrote about the client is in the text';
  end if;

  -- ── a week with nothing in it asks a question ──────────────
  if v_body not like '%?%' then
    failures := failures || format('FAILED: a week with nothing in it reads "%s"', v_body)::text;
  else
    raise notice 'ok  a week with nothing in it asks rather than reporting an absence';
  end if;

  -- ── a week with something in it says what ──────────────────
  declare
    v_lead uuid; v_match uuid; v_employer uuid;
  begin
    insert into public.employers (name) values ('ZZ Employer') returning id into v_employer;
    insert into public.job_leads (employer_id, title, status, created_by)
    values (v_employer, 'ZZ Shelf stacker', 'Open', v_admin) returning id into v_lead;
    insert into public.lead_matches (lead_id, client_id, status, applied_on, created_by)
    values (v_lead, v_active, 'Applied', v_week + 1, v_admin) returning id into v_match;

    v_text := public.weekly_update_body(v_active, null,
                public.weekly_update_facts(v_active, v_week, v_week + 6));
    if v_text not like '%applied for one job%' then
      failures := failures || format('FAILED: one application this week reads "%s"', v_text)::text;
    else
      raise notice 'ok  a week with an application in it says so, and counts it';
    end if;
  end;

  -- ── the sweep does not overwrite an edit ───────────────────
  perform public.edit_weekly_update(v_draft, 'ZZ this is the wording somebody chose');
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  perform public.draft_weekly_updates(v_week);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_admin_uid, 'role', 'authenticated')::text, true);
  select body into v_body from public.weekly_updates where id = v_draft;
  if v_body <> 'ZZ this is the wording somebody chose' then
    failures := failures || 'FAILED: running the sweep again overwrote an edited draft'::text;
  else
    raise notice 'ok  running the sweep again leaves an edited draft alone';
  end if;

  -- ── a coach does not approve a text to a client ────────────
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_coach_uid, 'role', 'authenticated')::text, true);
  v_text := '';
  begin
    perform public.approve_weekly_update(v_draft, true);
    v_text := 'allowed';
  exception when insufficient_privilege then
    v_text := sqlerrm;
  end;
  if v_text = 'allowed' then
    failures := failures || 'FAILED: a Job Coach approved a text to a client'::text;
  else
    raise notice 'ok  approving a text to a client is for the roles that keep the records';
  end if;
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_admin_uid, 'role', 'authenticated')::text, true);

  -- ── only an approved one is recorded as sent ───────────────
  perform public.set_sms_consent(v_active, '+13855550301', 'Granted', 'Verbal', 'ZZ said yes');
  insert into public.sms_messages (client_id, direction, phone, body, kind, status, created_by, send_after)
  values (v_active, 'Outgoing', '+13855550301', 'ZZ the update as sent', 'Weekly update', 'Scheduled',
          v_admin, public.next_text_window(now()))
  returning id into v_sms;

  v_text := '';
  begin
    perform public.weekly_update_sent(v_draft, v_sms);
    v_text := 'allowed';
  exception when check_violation then
    v_text := sqlerrm;
  end;
  if v_text = 'allowed' then
    failures := failures || 'FAILED: a draft nobody approved was recorded as sent'::text;
  elsif v_text not like '%approved%' then
    failures := failures || format('FAILED: refused, but not in a sentence: %s', v_text)::text;
  else
    raise notice 'ok  only an approved update is recorded as sent';
  end if;

  -- ── and only by the text that was for it ───────────────────
  perform public.approve_weekly_update(v_draft, true);
  v_text := '';
  begin
    perform public.weekly_update_sent(v_contact_draft, v_sms);
    v_text := 'allowed';
  exception when check_violation then
    v_text := sqlerrm;
  end;
  if v_text = 'allowed' then
    failures := failures || 'FAILED: a text to the client was recorded as the contact''s update'::text;
  else
    raise notice 'ok  a text counts for the update it was for and no other';
  end if;

  perform public.weekly_update_sent(v_draft, v_sms);
  select state into v_state from public.weekly_updates where id = v_draft;
  if v_state <> 'Sent' then
    failures := failures || format('FAILED: a sent update reads as %s', v_state)::text;
  else
    raise notice 'ok  and the one it was for is sent';
  end if;

  -- ── a sent one cannot be rewritten ─────────────────────────
  v_text := '';
  begin
    perform public.edit_weekly_update(v_draft, 'ZZ changing what somebody already read');
    v_text := 'allowed';
  exception when check_violation then
    v_text := sqlerrm;
  end;
  if v_text = 'allowed' then
    failures := failures || 'FAILED: a text that has gone out was rewritten'::text;
  else
    raise notice 'ok  a text that has gone out cannot be rewritten';
  end if;

  -- ── not sending one says why ───────────────────────────────
  v_text := '';
  begin
    perform public.discard_weekly_update(v_contact_draft, '   ');
    v_text := 'allowed';
  exception when check_violation then
    v_text := sqlerrm;
  end;
  if v_text = 'allowed' then
    failures := failures || 'FAILED: an update was closed with no reason'::text;
  else
    raise notice 'ok  not sending one says why';
  end if;

  -- ── and the week ends on Sunday night ──────────────────────
  insert into public.weekly_updates (week_start, client_id, contact_id, phone, body, state)
  values (v_last, v_active, null, '+13855550301', 'ZZ last week''s news', 'Approved')
  returning id into v_old;

  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  v_n := public.expire_weekly_updates();
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_admin_uid, 'role', 'authenticated')::text, true);

  select state, reason into v_state, v_text from public.weekly_updates where id = v_old;
  if v_state <> 'Not sent' then
    failures := failures || format('FAILED: last week''s approved update is still %s', v_state)::text;
  elsif coalesce(btrim(v_text), '') = '' then
    failures := failures || 'FAILED: an expired update does not say why it was not sent'::text;
  elsif (select state from public.weekly_updates where id = v_contact_draft) = 'Not sent' then
    failures := failures || 'FAILED: this week''s draft was closed with last week''s'::text;
  else
    raise notice 'ok  last week''s drafts are logged as not sent, with the reason, and this week''s are not';
  end if;

  perform set_config('request.jwt.claims', '', true);

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, chr(10));
  end if;
end $$;

rollback;
