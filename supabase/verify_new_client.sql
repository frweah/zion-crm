-- Zion Vocational Rehab CRM — what a new client record has to answer (0314)
--
-- Part 2a of the owner's list of 3 November 2026, and part 2b beside it
-- because both are about the same record being findable afterwards.
--
-- What has to hold:
--
--   A person adding a client gives a phone number, or ticks "No phone" and
--   says why. Neither is not an option.
--
--   And an invented person is not asked, which is why the people in this
--   script are not called ZZ anything. The rule exempts fixture names, the
--   way the directory log has since 0179, so a script that tried it on a ZZ
--   client would be watching the exemption rather than the rule - and both
--   halves are tried below.
--
--   A number and a reason cannot both be true, and the reason is the one that
--   gives way.
--
--   The intake agent is not asked. A referral that arrives without a phone
--   number on it is still a referral, and a record that refuses to hold what
--   the paper says jams the inbox instead of improving the data.
--
--   Texting consent has three answers. Granted needs to say how it was given,
--   because that is the whole evidence; declined needs nothing, because the
--   answer is the record. Not asked is no event at all. Texting is allowed on
--   Granted alone.
--
--   And an inactive or closed client is still findable, with their status on
--   the row, because the reason somebody searches for one is usually that
--   they have come back.
--
-- Runs inside a transaction that is rolled back. Nothing here is left behind.

begin;

do $$
declare
  v_admin   uuid;
  v_uid     uuid := gen_random_uuid();
  v_with    uuid;
  v_without uuid;
  v_both    uuid;
  v_fixture uuid;
  v_agent   uuid;
  v_gone    uuid;
  v_closed  uuid;
  v_n       integer;
  r         record;
  failures  text[] := '{}';
begin
  insert into public.staff (name, email, role, active)
  values ('ZZ Intake Person', 'zz-intake-person@example.test', 'Admin', true) returning id into v_admin;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-intake-person@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_uid where id = v_admin;

  -- ── as a person adding a client ────────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);

  begin
    insert into public.clients (name, stage, status) values ('Teodora Intake Testperson', 'Intake', 'Active');
    failures := failures || 'FAILED: a client went in with no phone number and no reason'::text;
  exception when check_violation then
    raise notice 'ok  a new client needs a phone number, or the reason there is not one';
  end;

  insert into public.clients (name, stage, status, no_phone_reason)
  values ('Marlow Noreach Testperson', 'Intake', 'Active', '  Staying at a shelter, reachable through her counselor  ')
  returning id into v_without;
  if (select no_phone_reason from public.clients where id = v_without)
     <> 'Staying at a shelter, reachable through her counselor' then
    failures := failures || 'FAILED: the reason there is no phone was not kept, or not tidied'::text;
  else
    raise notice 'ok  and the reason is kept, without the spaces somebody typed around it';
  end if;

  insert into public.clients (name, stage, status, phone, no_phone_reason)
  values ('Hollis Reached Testperson', 'Intake', 'Active', '(801) 555-0144', 'ZZ said both things')
  returning id into v_both;
  if coalesce((select no_phone_reason from public.clients where id = v_both), '') <> '' then
    failures := failures || 'FAILED: a client has a phone number and a reason for not having one'::text;
  else
    raise notice 'ok  a number and a reason cannot both be true, and the reason gives way';
  end if;

  -- An invented person is not asked, which is what lets 133 fixtures across
  -- the suite go on creating a client to test something else.
  insert into public.clients (name, stage, status) values ('ZZ Invented Person', 'Intake', 'Active')
  returning id into v_fixture;
  if v_fixture is null then
    failures := failures || 'FAILED: a fixture client could not be created'::text;
  else
    raise notice 'ok  and somebody invented to try something out is not asked';
  end if;

  -- ── texting, which has three answers ──────────────────────
  begin
    perform public.set_sms_consent(v_both, 'Granted', 'Verbal', '');
    failures := failures || 'FAILED: consent was granted with nothing saying how'::text;
  exception when check_violation then
    raise notice 'ok  granting consent has to say how it was given';
  end;

  perform public.set_sms_consent(v_both, 'Declined', 'Intake form', '');
  if (select state from public.client_sms_consent where client_id = v_both) <> 'Declined' then
    failures := failures || 'FAILED: declining was not recorded as declining'::text;
  elsif (select can_text from public.client_sms_consent where client_id = v_both) then
    failures := failures || 'FAILED: a client who said no may be texted'::text;
  else
    raise notice 'ok  asked and declined is its own answer, and it blocks texting';
  end if;

  perform public.set_sms_consent(v_both, 'Granted', 'Verbal', 'ZZ said yes at intake, 6 November');
  if not (select can_text from public.client_sms_consent where client_id = v_both) then
    failures := failures || 'FAILED: a client who said yes may not be texted'::text;
  else
    raise notice 'ok  and saying yes afterwards is the later answer, which allows it';
  end if;

  -- Not asked is no event at all, and nothing can be consented to without a
  -- number to consent about.
  if (select state from public.client_sms_consent where client_id = v_without) is not null
     or (select can_text from public.client_sms_consent where client_id = v_without) then
    failures := failures || 'FAILED: a client nobody asked has an answer on file'::text;
  else
    raise notice 'ok  not asked is no event at all, which is what it is';
  end if;

  begin
    perform public.set_sms_consent(v_without, 'Granted', 'Verbal', 'ZZ trying it on');
    failures := failures || 'FAILED: consent was recorded for a client with no phone number'::text;
  exception when check_violation then
    raise notice 'ok  and there is nothing to consent to without a number';
  end;

  -- ── the agent is not asked ────────────────────────────────
  perform set_config('role', 'service_role', true);
  perform set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
  insert into public.clients (name, stage, status) values ('Odile Referred Testperson', 'Intake', 'Active')
  returning id into v_agent;
  if v_agent is null then
    failures := failures || 'FAILED: a referral with no phone number on it did not land'::text;
  else
    raise notice 'ok  a referral the agent files is not asked for what the paper does not say';
  end if;

  -- ── and they stay findable ────────────────────────────────
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  insert into public.clients (name, stage, status, phone)
  values ('Verity Quiet Testperson', 'Job Coaching', 'Inactive', '(801) 555-0145') returning id into v_gone;
  insert into public.clients (name, stage, status, phone)
  values ('Rowan Finished Testperson', 'Job Placement', 'Closed', '(801) 555-0146') returning id into v_closed;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);

  select count(*) into v_n from public.search_clients('Verity Quiet Testperson', 50) where id = v_gone;
  if v_n <> 1 then
    failures := failures || 'FAILED: an inactive client cannot be found by name'::text;
  elsif (select status from public.search_clients('Verity Quiet Testperson', 50) where id = v_gone) <> 'Inactive' then
    failures := failures || 'FAILED: an inactive client is found without saying so'::text;
  else
    raise notice 'ok  an inactive client is found by name, and the row says Inactive';
  end if;

  select count(*) into v_n from public.search_clients('Rowan Finished Testperson', 50) where id = v_closed;
  if v_n <> 1 then
    failures := failures || 'FAILED: a closed client cannot be found by name'::text;
  elsif (select status from public.search_clients('Rowan Finished Testperson', 50) where id = v_closed) <> 'Closed' then
    failures := failures || 'FAILED: a closed client is found without saying so'::text;
  else
    raise notice 'ok  so is a closed one, and the row says Closed';
  end if;

  -- By number and by phone too, which is how somebody who has come back is
  -- usually looked for: they give a number, not a spelling.
  select count(*) into v_n from public.search_clients('555-0146', 50) where id = v_closed;
  if v_n <> 1 then
    failures := failures || 'FAILED: a closed client cannot be found by their phone number'::text;
  else
    raise notice 'ok  and by the number they ring from';
  end if;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  if array_length(failures, 1) > 0 then
    raise notice '';
    raise notice '%  PROBLEM(S):', array_length(failures, 1);
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '';
  raise notice '--- A NEW CLIENT RECORD ANSWERS FOR ITSELF ---';
end $$;

rollback;
