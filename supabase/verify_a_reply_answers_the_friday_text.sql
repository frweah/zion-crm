-- Zion Vocational Rehab CRM — the Friday text lists, and a reply answers (0387, 0388)
--
-- What has to hold, end to end:
--
--   the client's Friday text numbers this week's places and ends with the one
--   line that asks, and a contact's copy still gets the count;
--
--   the numbers are written down as they are sent, so "3 NO" is answerable a
--   week later even if somebody logs another application on the Saturday;
--
--   a reply of "<number> YES/NO" from the client's own number, inside seven
--   days, is that client's answer on that application, in their own words,
--   and counts as a contact;
--
--   a reply that is not that stays a message and nothing else: a bare YES is
--   still the carrier's opt-in, a bare NO is still just a message, a number
--   that was not on the list is not an answer, and "YES 3" is not one either;
--
--   "3 YES" is a rating and NOT consent, which is the thing this could most
--   easily have got wrong - before 0388 that reply reduced to "YES" and was
--   recorded as consent given by text;
--
--   the text fits: a seven-application week is three parts and stays GSM-7,
--   whatever typographic punctuation an employer's name is spelled with;
--
--   and a No is findable when the next application to that employer starts.
--
-- Everything is rolled back.

begin;

do $$
declare
  failures  text[] := array[]::text[];
  v_mark    integer;
  v_admin   uuid; v_admin_uid uuid := gen_random_uuid();
  v_client  uuid;
  v_contact uuid;
  v_emp_a   uuid; v_emp_b uuid; v_emp_c uuid;
  v_lead    uuid;
  v_match1  uuid; v_match2 uuid; v_match3 uuid; v_match4 uuid; v_later uuid;
  v_monday  date := date_trunc('week', public.practice_today()::timestamp)::date;
  v_update  uuid;
  v_body    text;
  v_cbody   text;
  v_n       integer;
  v_sms     uuid;
  v_out     uuid;
  v_answer  text;
  v_said    text;
  v_rated   integer;
  v_segs    integer;
  v_phone   text := '+13855550101';
  v_act     text;
begin
  insert into public.staff (name, email, role, active)
  values ('ZZ Reply Admin', 'zz-reply-admin@example.test', 'Admin', true) returning id into v_admin;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_admin_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-reply-admin@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_admin_uid where id = v_admin;

  insert into public.clients (name, stage, status, phone, assigned_staff_id, language)
  values ('ZZ Reply Client', 'Job Search', 'Active', v_phone, v_admin, 'en') returning id into v_client;
  insert into public.sms_consent_events (client_id, state, phone, method, note)
  values (v_client, 'Granted', public.normalize_phone(v_phone), 'Verbal', 'ZZ verify fixture');

  -- Three places applied for this week. The second employer is spelled with a
  -- typographic apostrophe, which is the one on file that would otherwise
  -- turn every Friday text in the practice into UCS-2.
  insert into public.employers (name) values ('ZZ Mountain Hardware') returning id into v_emp_a;
  insert into public.employers (name) values (U&'ZZ Benson\2019s Market') returning id into v_emp_b;
  insert into public.employers (name) values ('ZZ Canyon Freight') returning id into v_emp_c;

  insert into public.job_leads (employer_id, title, status)
  values (v_emp_a, 'Stock associate', 'Open') returning id into v_lead;
  insert into public.lead_matches (lead_id, client_id, status, applied_on)
  values (v_lead, v_client, 'Applied', v_monday + 1) returning id into v_match1;

  insert into public.job_leads (employer_id, title, status)
  values (v_emp_b, 'Cashier', 'Open') returning id into v_lead;
  insert into public.lead_matches (lead_id, client_id, status, applied_on)
  values (v_lead, v_client, 'Applied', v_monday + 2) returning id into v_match2;

  insert into public.job_leads (employer_id, title, status)
  values (v_emp_c, 'Warehouse picker with a very long title that nobody would ever read to the end of in a text message', 'Open')
  returning id into v_lead;
  insert into public.lead_matches (lead_id, client_id, status, applied_on)
  values (v_lead, v_client, 'Applied', v_monday + 3) returning id into v_match3;

  -- A second application to the same employer in the same week, which is the
  -- only case where the role is printed - and so the only case where the
  -- 104-character title above can reach the text at all. A fault proved the
  -- cap was untested without it.
  insert into public.job_leads (employer_id, title, status)
  values (v_emp_c, 'Forklift operator, swing shift, weekends included', 'Open') returning id into v_lead;
  insert into public.lead_matches (lead_id, client_id, status, applied_on)
  values (v_lead, v_client, 'Applied', v_monday + 4) returning id into v_match4;

  insert into public.client_contacts (client_id, name, relationship, phone, receives_updates, active)
  values (v_client, 'ZZ Reply Sister', 'Sister', '+13855550102', true, true) returning id into v_contact;

  -- ── 1. the body lists, and ends with the line that asks ──────
  v_mark := coalesce(array_length(failures, 1), 0);
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin_uid, 'role', 'authenticated')::text, true);

  v_body := public.weekly_update_body(v_client, null,
              public.weekly_update_facts(v_client, v_monday, v_monday + 6));
  v_cbody := public.weekly_update_body(v_client, v_contact,
              public.weekly_update_facts(v_client, v_monday, v_monday + 6));
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  if position('1. ZZ Mountain Hardware' in v_body) = 0 then
    failures := failures || 'FAILED: the first place is not numbered in the body'::text;
  end if;
  if position('2. ZZ Benson''s Market' in v_body) = 0 then
    failures := failures || format('FAILED: the second place is missing or not folded to plain text: %s', v_body)::text;
  end if;
  if position('3. ZZ Canyon Freight' in v_body) = 0 then
    failures := failures || 'FAILED: the third place is not numbered in the body'::text;
  end if;
  if position('You applied for 4 jobs this week:' in v_body) = 0 then
    failures := failures || 'FAILED: the body does not count the list it printed'::text;
  end if;
  -- The owner's words, written out here rather than read from the function
  -- the body also reads. A fault that changed the line passed this twice.
  if position('Reply with the number and YES or NO to tell us if you''d want to work there' in v_body) = 0
     or position('or text us a place you''d like us to try.' in v_body) = 0 then
    failures := failures || format('FAILED: the client''s text does not end with the line that asks: %s', v_body)::text;
  end if;
  if position(public.weekly_update_invitation() in v_body) = 0 then
    failures := failures || 'FAILED: the body and the invitation function disagree'::text;
  end if;
  if position('If anything has changed' in v_body) > 0 then
    failures := failures || 'FAILED: the client''s text asks twice, which is how somebody answers neither'::text;
  end if;

  -- A contact gets the count, and no invitation to answer a list they cannot see.
  if position('applied for 4 jobs this week.' in v_cbody) = 0 then
    failures := failures || format('FAILED: a contact''s copy no longer counts the week: %s', v_cbody)::text;
  end if;
  if position('1. ZZ' in v_cbody) > 0 then
    failures := failures || 'FAILED: a contact''s copy lists where somebody else''s client applied'::text;
  end if;
  if position('Reply with the number and YES or NO' in v_cbody) > 0 then
    failures := failures || 'FAILED: a contact is asked to rate the client''s applications'::text;
  end if;
  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  the client''s text numbers the places and asks; a contact''s counts them and does not';
  end if;

  /**
   * And the seat that actually drafts it gets the list.
   *
   * The Friday draft runs at 2pm as the service role, not as a person. If
   * `reader_may_answer()` refused that seat, `weekly_update_list` would
   * return nothing and the body would fall back to the count - a Friday text
   * with no numbers in it and nothing anywhere saying why.
   */
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
  if position('1. ZZ Mountain Hardware' in
      public.weekly_update_body(v_client, null,
        public.weekly_update_facts(v_client, v_monday, v_monday + 6))) = 0 then
    failures := failures || 'FAILED: the Friday sweep''s own seat drafts a text with no list in it'::text;
  else
    raise notice '  ok  the service role, which is what drafts at 2pm on Friday, gets the list';
  end if;
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  -- ── 2. it fits, and stays GSM-7 ──────────────────────────────
  v_mark := coalesce(array_length(failures, 1), 0);
  if v_body <> public.sms_plain(v_body) then
    failures := failures || 'FAILED: the body holds a character that would send it as UCS-2'::text;
  end if;
  v_segs := public.sms_segments(v_body);
  if v_segs > 3 then
    failures := failures || format('FAILED: a three-application week is %s parts (%s characters)', v_segs, length(v_body))::text;
  end if;
  -- And the longest title on file cannot push a line past its cap.
  if (select max(length(label)) from public.weekly_update_list(v_client, v_monday, v_monday + 6)) > 37 then
    failures := failures || 'FAILED: a label is longer than its cap, so one job title can run away with the text'::text;
  end if;
  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  % characters, % part(s), and nothing in it that is not GSM-7', length(v_body), v_segs;
  end if;

  -- ── 3. the numbers are written down as sent ──────────────────
  v_mark := coalesce(array_length(failures, 1), 0);
  -- Sent, the way the practice records a send: an outgoing message, and the
  -- update pointing at it. `weekly_updates_sent_says_so` requires both.
  insert into public.sms_messages (client_id, direction, phone, body, kind, status, sent_at)
  values (v_client, 'Outgoing', public.normalize_phone(v_phone), v_body, 'Weekly update', 'Sent', now() - interval '1 hour')
  returning id into v_out;

  insert into public.weekly_updates (week_start, client_id, contact_id, phone, language, body, facts, state, sent_at, sms_id)
  values (v_monday, v_client, null, public.normalize_phone(v_phone), 'en', v_body,
          public.weekly_update_facts(v_client, v_monday, v_monday + 6), 'Sent', now() - interval '1 hour', v_out)
  returning id into v_update;

  insert into public.weekly_update_items (update_id, item_no, match_id, label)
  select v_update, item_no, match_id, label
    from public.weekly_update_list(v_client, v_monday, v_monday + 6);

  select count(*) into v_n from public.weekly_update_items where update_id = v_update;
  if v_n <> 4 then
    failures := failures || format('FAILED: %s of 4 numbers were written down', v_n)::text;
  end if;
  if (select match_id from public.weekly_update_items where update_id = v_update and item_no = 2) is distinct from v_match2 then
    failures := failures || 'FAILED: number 2 does not point at the second place applied for'::text;
  end if;

  -- Another application logged afterwards must not renumber what was sent.
  insert into public.job_leads (employer_id, title, status) values (v_emp_a, 'Night shift', 'Open') returning id into v_lead;
  insert into public.lead_matches (lead_id, client_id, status, applied_on)
  values (v_lead, v_client, 'Applied', v_monday) returning id into v_later;
  if (select match_id from public.weekly_update_items where update_id = v_update and item_no = 1) is distinct from v_match1 then
    failures := failures || 'FAILED: a later application renumbered a list that had already gone out'::text;
  end if;
  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  the list is kept as it was sent, and a later application does not renumber it';
  end if;

  -- ── 4. "2 no too far by bus" is an answer ────────────────────
  v_mark := coalesce(array_length(failures, 1), 0);
  select action into v_act from public.record_incoming_sms(v_phone, '2 no too far by bus');
  if v_act is distinct from 'rated' then
    failures := failures || format('FAILED: the reply was recorded as "%s" rather than a rating', coalesce(v_act, 'nothing'))::text;
  end if;

  select count(*) into v_n from public.application_feedback where match_id = v_match2;
  if v_n <> 1 then
    failures := failures || format('FAILED: %s rating(s) landed on the second place', v_n)::text;
  end if;
  select answer, said into v_answer, v_said from public.application_feedback where match_id = v_match2;
  if v_answer is distinct from 'No' then
    failures := failures || format('FAILED: the answer reads "%s"', coalesce(v_answer, 'nothing'))::text;
  end if;
  if v_said is distinct from '2 no too far by bus' then
    failures := failures || format('FAILED: the client''s words were not kept whole: "%s"', coalesce(v_said, ''))::text;
  end if;
  -- Nothing landed on the other two.
  if (select count(*) from public.application_feedback where match_id in (v_match1, v_match3)) <> 0 then
    failures := failures || 'FAILED: one answer rated more than one application'::text;
  end if;
  -- It is on the thread, as every text is.
  if (select count(*) from public.sms_messages where client_id = v_client and direction = 'Incoming') <> 1 then
    failures := failures || 'FAILED: the reply is not on the thread'::text;
  end if;
  -- And it counts as a contact.
  select count(*) into v_n from public.contact_log
   where client_id = v_client and method = 'Text' and public.is_real_contact(method);
  if v_n <> 1 then
    failures := failures || format('FAILED: %s contact-log line(s) for a reply that answered', v_n)::text;
  end if;
  -- No consent event: a rating is not a consent decision.
  if (select count(*) from public.sms_consent_events where client_id = v_client) <> 1 then
    failures := failures || 'FAILED: the rating moved the client''s consent'::text;
  end if;
  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  the answer lands on that application, in their words, counted as a contact';
  end if;

  -- ── 5. "3 YES" is a rating and not consent ───────────────────
  v_mark := coalesce(array_length(failures, 1), 0);
  select action into v_act from public.record_incoming_sms(v_phone, '3 YES');
  if v_act is distinct from 'rated' then
    failures := failures || format('FAILED: "3 YES" was recorded as "%s" - before 0388 it read as consent', coalesce(v_act, 'nothing'))::text;
  end if;
  if (select count(*) from public.sms_consent_events where client_id = v_client) <> 1 then
    failures := failures || 'FAILED: "3 YES" was recorded as consent given by text'::text;
  end if;
  if (select answer from public.application_feedback f
       join public.weekly_update_items i on i.match_id = f.match_id and i.update_id = v_update
      where i.item_no = 3) is distinct from 'Yes' then
    failures := failures || 'FAILED: "3 YES" did not answer the third place'::text;
  end if;
  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  "3 YES" answers the third place and leaves consent alone';
  end if;

  -- ── 6. and a bare YES is still the carrier's opt-in ──────────
  v_mark := coalesce(array_length(failures, 1), 0);
  select count(*) into v_n from public.application_feedback where client_id = v_client;
  select action into v_act from public.record_incoming_sms(v_phone, 'YES');
  if v_act is distinct from 'granted' then
    failures := failures || format('FAILED: a bare YES was recorded as "%s", and the carrier rules are about that word', coalesce(v_act, 'nothing'))::text;
  end if;
  if (select count(*) from public.application_feedback where client_id = v_client) <> v_n then
    failures := failures || 'FAILED: a bare YES rated something'::text;
  end if;
  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  a bare YES is still consent, and rates nothing';
  end if;

  -- ── 7. what is not an answer ─────────────────────────────────
  v_mark := coalesce(array_length(failures, 1), 0);
  select count(*) into v_n from public.application_feedback where client_id = v_client;

  -- a number that was not on the list
  perform public.record_incoming_sms(v_phone, '9 no');
  -- the reversed form, which cannot be told from "number 3"
  perform public.record_incoming_sms(v_phone, 'YES 3');
  perform public.record_incoming_sms(v_phone, 'NO 3');
  -- a number on its own, and a word that is not yes or no
  perform public.record_incoming_sms(v_phone, '2');
  perform public.record_incoming_sms(v_phone, '2 maybe');
  perform public.record_incoming_sms(v_phone, 'The bus does not run that early');
  if (select count(*) from public.application_feedback where client_id = v_client) <> v_n then
    failures := failures || 'FAILED: something that is not "<number> yes/no" was read as an answer'::text;
  end if;

  -- a reply from a contact's number
  perform public.record_incoming_sms('+13855550102', '1 no');
  if (select count(*) from public.application_feedback where client_id = v_client) <> v_n then
    failures := failures || 'FAILED: a contact''s reply was recorded as the client''s answer'::text;
  end if;

  -- and the same reply outside seven days
  update public.weekly_updates set sent_at = now() - interval '8 days' where id = v_update;
  perform public.record_incoming_sms(v_phone, '1 no');
  if (select count(*) from public.application_feedback where client_id = v_client) <> v_n then
    failures := failures || 'FAILED: a reply to an update from more than seven days ago was still an answer'::text;
  end if;
  update public.weekly_updates set sent_at = now() - interval '1 hour' where id = v_update;
  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  a stray number, the reversed form, a contact and a late reply are all just messages';
  end if;

  -- ── 8. several answers in one message, and a change of mind ──
  v_mark := coalesce(array_length(failures, 1), 0);
  select action into v_act from public.record_incoming_sms(v_phone, '1 yes, 2 yes and 3no');
  if v_act is distinct from 'rated' then
    failures := failures || 'FAILED: a message with three answers in it was not read as a rating'::text;
  end if;
  if (select count(*) from public.application_feedback where match_id = v_match1 and answer = 'Yes') <> 1 then
    failures := failures || 'FAILED: the first answer in a multiple reply did not land'::text;
  end if;
  if (select count(*) from public.application_feedback where match_id = v_match2) <> 2 then
    failures := failures || 'FAILED: a change of mind did not append beside the first answer'::text;
  end if;
  -- By seq, not by `at`: two answers in one message share the transaction's
  -- timestamp, which is what 0389 is for.
  if (select answer from public.application_feedback where match_id = v_match2 order by seq desc limit 1) is distinct from 'Yes' then
    failures := failures || 'FAILED: the newest answer is not the one that reads last'::text;
  end if;
  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  three answers in one message all land, and a change of mind appends';
  end if;

  -- ── 9. and a No is there when the next application starts ────
  v_mark := coalesce(array_length(failures, 1), 0);
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin_uid, 'role', 'authenticated')::text, true);
  select said into v_said from public.client_said_no_to(v_client, v_emp_c);
  if v_said is null then
    failures := failures || 'FAILED: the No on that employer cannot be found when a new application starts'::text;
  end if;
  if (select count(*) from public.client_said_no_to(v_client, v_emp_a)) <> 0 then
    failures := failures || 'FAILED: an employer the client said yes to reads as a No'::text;
  end if;
  perform set_config('request.jwt.claims', '', true);
  perform set_config('role', 'anon', true);
  begin
    if (select count(*) from public.client_said_no_to(v_client, v_emp_c)) <> 0 then
      failures := failures || 'FAILED: somebody signed out can read what a client said about an employer'::text;
    end if;
  exception when insufficient_privilege then null;
  end;
  perform set_config('role', 'postgres', true);
  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  a No is findable by employer, a Yes is not a No, and a stranger reads neither';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception E'\n%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- A REPLY ANSWERS THE FRIDAY TEXT, VERIFIED ---';
end $$;

rollback;
