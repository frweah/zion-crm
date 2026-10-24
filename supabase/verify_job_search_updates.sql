-- Zion Vocational Rehab CRM — a job search update is everybody's to add (0250)
--
-- Margaret's bug, asserted as the rule it turned out to be: every role that
-- can see a client can add a job search update, and the row says who added it.
--
-- Asked once per role, as that role, because "the policy allows five roles"
-- is a sentence about an array and what broke was a role being outside it.
-- Each of the five gets a staff row of its own with a login, adds the
-- employer, the job and the client against it - all three, because a job
-- added from a client's record writes to all three and the panel fails if any
-- one of them refuses.
--
-- Billing is asked too, and must be refused: it is the one active role that
-- is not in the list, so without it this script would pass on a policy that
-- allowed everybody.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_client   uuid;
  v_staff    uuid;
  v_uid      uuid;
  v_employer uuid;
  v_lead     uuid;
  v_match    uuid;
  v_role     text;
  v_n        integer;
  v_by       uuid;
  failures   text[] := '{}';
  ROLES      text[] := array['Admin', 'Job Search', 'Reports', 'Job Coach', 'Case Manager'];
begin
  insert into public.clients (name, status, stage) values ('ZZ Job Search Client', 'Active', 'Job Search')
  returning id into v_client;

  foreach v_role in array ROLES || array['Billing']
  loop
    -- Cleared first. Left over from the round before, a lead id makes a
    -- refused role look as though it added somebody else's row, which is a
    -- second failure about the wrong thing.
    v_employer := null;
    v_lead := null;
    v_match := null;

    -- A person of that role, with a login, who has signed the policies.
    insert into public.staff (name, email, role, active)
    values ('ZZ ' || v_role || ' Jobs', 'zz-jobs-' || lower(replace(v_role, ' ', '-')) || '@example.test', v_role, true)
    returning id into v_staff;

    insert into auth.users (id, instance_id, aud, role, email,
                            raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
            'authenticated', 'authenticated',
            'zz-jobs-' || lower(replace(v_role, ' ', '-')) || '@example.test',
            '{}', '{}', now(), now())
    returning id into v_uid;
    update public.staff set user_id = v_uid where id = v_staff;

    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_uid::text, 'role', 'authenticated')::text, true);

    begin
      insert into public.employers (name, created_by)
      values ('ZZ Employer for ' || v_role, v_staff)
      returning id into v_employer;

      insert into public.job_leads (employer_id, title, source, owner_staff_id, created_by)
      values (v_employer, 'ZZ Dishwasher', 'Client profile', v_staff, v_staff)
      returning id into v_lead;

      insert into public.lead_matches (lead_id, client_id, status, created_by)
      values (v_lead, v_client, 'Applied', v_staff)
      returning id into v_match;

      if v_role = 'Billing' then
        failures := failures || 'FAILED: Billing added a job search update, so the rule is not a rule'::text;
      else
        raise notice 'ok  % adds the employer, the job and the client against it', v_role;
      end if;
    exception when insufficient_privilege then
      if v_role = 'Billing' then
        raise notice 'ok  and Billing is refused, so the five are five and not everybody';
      else
        failures := failures ||
          format('FAILED: %s cannot add a job search update - this is Margaret''s bug', v_role)::text;
      end if;
    end;

    -- The row says who added it, and will not be written saying anybody else.
    if v_role <> 'Billing' and v_lead is not null then
      select created_by into v_by from public.job_leads where id = v_lead;
      if v_by is distinct from v_staff then
        failures := failures || format('FAILED: the job %s added records %s as having added it', v_role, v_by)::text;
      end if;

      begin
        insert into public.job_leads (employer_id, title, source, owner_staff_id, created_by)
        values (v_employer, 'ZZ Not mine to claim', 'Client profile', v_staff, null);
        failures := failures ||
          format('FAILED: %s added a job with nobody recorded as having added it', v_role)::text;
      exception when insufficient_privilege then
        null;  -- which is the rule: a row that does not say who added it cannot be added
      end;
    end if;

    perform set_config('request.jwt.claims', '', true);
    perform set_config('role', 'postgres', true);
  end loop;

  raise notice 'ok  and none of them can add one without their own name on it';

  -- What the client's record now shows: one job per role that may add one.
  select count(*)::int into v_n
    from public.lead_matches m where m.client_id = v_client;
  if v_n <> array_length(ROLES, 1) then
    failures := failures ||
      format('FAILED: %s of the %s roles got a job onto the client', v_n, array_length(ROLES, 1))::text;
  else
    raise notice 'ok  all % of them land on the client''s record', v_n;
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- JOB SEARCH UPDATES VERIFIED ---';
end $$;

rollback;
