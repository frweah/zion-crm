-- Zion Vocational Rehab CRM — chasing what has not arrived (0184)
--
-- Rules 6, 7 and 8 of the Intake Automation Brief, each tried from the
-- direction that would break it:
--
--   6. A referral is nudged on day seven and day fourteen and on no other day,
--      never twice for the same day, and never once an authorization exists.
--      A client who has been waiting three months gets the task and no email,
--      which is what "after that, task only" means - and what stops the day
--      this goes live being a morning of thank-yous.
--
--   7. An authorization inside thirty days of its end, with hours left or a
--      flat fee not yet submitted, reaches Margaret and Billing with a draft.
--      One that is finished, paid, closed, or has no hours left reaches
--      nobody, and nothing is emailed to the counselor from here.
--
--   8. A hire records its date, starts the placement, sets the four-week
--      retention milestone as the match's own follow-up (which the existing
--      reminder sync turns into a task and a calendar entry), and puts the
--      first day of work on the placement authorization - from which its
--      bill-by is computed rather than written. USOR 60 and 92 are already
--      outstanding for a placement, so that is asserted rather than written.
--
--      The two dates are deliberately different numbers now (0188): bill-by is
--      the first day of work plus seven, and the retention milestone is plus
--      twenty-eight. They were the same number once, so both are asserted
--      here - a change to either must not quietly move the other.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_margaret uuid;
  v_rei      uuid;
  v_billing  uuid;
  v_counsel  uuid;
  v_waiting  uuid;
  v_fresh    uuid;
  v_covered  uuid;
  v_old      uuid;
  v_auth     uuid;
  v_place_c  uuid;
  v_lead     uuid;
  v_employer uuid;
  v_match    uuid;
  v_place    uuid;
  v_res      jsonb;
  v_n        bigint;
  v_text     text;
  v_date     date;
  v_today    date := public.practice_today();
  failures   text[] := '{}';
  r          record;
begin
  select intake_staff_id, placement_staff_id, billing_notify_staff_id
    into v_margaret, v_rei, v_billing from public.org_settings limit 1;
  if v_margaret is null or v_rei is null or v_billing is null then
    raise exception 'FAILED: org_settings does not say who hears about intake, placements and billing';
  end if;

  insert into public.counselors (name, email, office)
  values ('ZQ Chase Counselor', 'zq-chase@example.test', 'Salt Lake City')
  returning id into v_counsel;

  -- ── Rule 6: the day it is nudged ───────────────────────────
  -- Four clients at Referral, waiting different lengths of time. The dates are
  -- put on the contact log, which is what referral_received_on reads first.
  insert into public.clients (name, stage, status, counselor_id)
  values ('ZZ Waiting Seven', 'Referral', 'Active', v_counsel) returning id into v_waiting;
  insert into public.clients (name, stage, status, counselor_id)
  values ('ZZ Waiting Three', 'Referral', 'Active', v_counsel) returning id into v_fresh;
  insert into public.clients (name, stage, status, counselor_id)
  values ('ZZ Waiting Covered', 'Referral', 'Active', v_counsel) returning id into v_covered;
  insert into public.clients (name, stage, status, counselor_id)
  values ('ZZ Waiting Months', 'Referral', 'Active', v_counsel) returning id into v_old;

  insert into public.contact_log (client_id, counselor_id, date, method, topic, outcome)
  values (v_waiting, v_counsel, v_today - 7, 'Email', 'Referral received', 'ZZ seven days ago'),
         (v_fresh, v_counsel, v_today - 3, 'Email', 'Referral received', 'ZZ three days ago'),
         (v_covered, v_counsel, v_today - 9, 'Email', 'Referral received', 'ZZ nine days ago'),
         (v_old, v_counsel, v_today - 95, 'Email', 'Referral received', 'ZZ months ago');

  -- The covered one has an authorization, so it is not waiting on anything.
  insert into public.authorizations
    (client_id, number, service_type, rate_type, rate, status, start_date, end_date)
  values (v_covered, 'ZZ-CH-1', 'Job Development', 'Flat Fee', 560, 'Authorized',
          v_today - 9, v_today + 80);

  if public.referral_received_on(v_waiting) <> v_today - 7 then
    failures := failures || format('FAILED: the referral date reads %s, not seven days ago',
                                   public.referral_received_on(v_waiting))::text;
  else
    raise notice 'ok  a referral''s date is read off the contact log the intake wrote';
  end if;

  -- Day seven: nudged.
  for r in select * from public.referrals_without_authorization(v_today) loop
    if r.client_id = v_waiting then
      if not r.send or r.nth <> 1 then
        failures := failures || format('FAILED: day seven is not nudged (send=%s nth=%s)', r.send, r.nth)::text;
      elsif position('ZZ Waiting Seven' in r.body) = 0 or position('Hi ZQ' in r.body) = 0 then
        failures := failures || format('FAILED: the nudge does not read right: %s', r.body)::text;
      else
        raise notice 'ok  day seven is nudged, and the words name the client and greet the counselor';
      end if;
    elsif r.client_id = v_old then
      if r.send then
        failures := failures || 'FAILED: a client waiting three months was emailed'::text;
      elsif r.nth <> 2 then
        failures := failures || 'FAILED: a long wait is not counted as past the second nudge'::text;
      else
        raise notice 'ok  a client waiting months gets the task and no email - "after that, task only"';
      end if;
    elsif r.client_id = v_fresh then
      failures := failures || 'FAILED: a referral three days old is being chased'::text;
    elsif r.client_id = v_covered then
      failures := failures || 'FAILED: a client who has an authorization is being chased for one'::text;
    end if;
  end loop;

  if not exists (select 1 from public.referrals_without_authorization(v_today)
                  where client_id = v_fresh) then
    raise notice 'ok  a referral three days old is not on the list at all';
  end if;
  if not exists (select 1 from public.referrals_without_authorization(v_today)
                  where client_id = v_covered) then
    raise notice 'ok  a client with an authorization is off the list';
  end if;

  -- Day fourteen is the second nudge, and day eight is neither.
  if (select nth from public.referrals_without_authorization(v_today + 7)
       where client_id = v_waiting) <> 2 then
    failures := failures || 'FAILED: day fourteen is not the second nudge'::text;
  elsif not (select send from public.referrals_without_authorization(v_today + 7)
              where client_id = v_waiting) then
    failures := failures || 'FAILED: day fourteen is not sent'::text;
  elsif (select send from public.referrals_without_authorization(v_today + 1)
          where client_id = v_waiting) then
    failures := failures || 'FAILED: day eight is being emailed; only seven and fourteen are'::text;
  else
    raise notice 'ok  day fourteen is the second nudge, and the days between are not emailed';
  end if;

  -- ── and it is sent once ────────────────────────────────────
  if not public.record_referral_nudge(v_waiting, 1, 'zq-chase@example.test') then
    failures := failures || 'FAILED: the first nudge was not claimed'::text;
  elsif public.record_referral_nudge(v_waiting, 1, 'zq-chase@example.test') then
    failures := failures || 'FAILED: the same nudge was claimed twice'::text;
  elsif (select send from public.referrals_without_authorization(v_today)
          where client_id = v_waiting) then
    failures := failures || 'FAILED: a nudge already sent is still offered for sending'::text;
  elsif not exists (select 1 from public.contact_log
                     where client_id = v_waiting and topic = 'Authorization chased') then
    failures := failures || 'FAILED: the nudge was not logged on the client'::text;
  else
    raise notice 'ok  a nudge is claimed once, logged on the client, and not offered again';
  end if;

  -- ── Rule 7: ending soon, with work left ───────────────────
  -- Assigned to Rei, as a client who reaches placement would be: the reminder
  -- sync puts the milestone on somebody's calendar and that column is not null.
  insert into public.clients (name, stage, status, counselor_id, assigned_staff_id)
  values ('ZZ Ending Testperson', 'Job Coaching', 'Active', v_counsel, v_rei)
  returning id into v_place_c;

  insert into public.authorizations
    (client_id, number, service_type, rate_type, rate, total_hours, status, start_date, end_date)
  values (v_place_c, 'ZZ-CH-2', 'Job Coaching', 'Hourly', 45, 40, 'Authorized',
          v_today - 60, v_today + 20)
  returning id into v_auth;

  if not exists (select 1 from public.authorizations_ending_soon(v_today) where auth_id = v_auth) then
    failures := failures || 'FAILED: an authorization ending in twenty days with hours left is not chased'::text;
  else
    select body into v_text
      from public.authorizations_ending_soon(v_today) where auth_id = v_auth;
    if position('renewal' in lower(v_text)) = 0 or position('ZZ Ending Testperson' in v_text) = 0 then
      failures := failures || format('FAILED: the renewal draft does not read right: %s', v_text)::text;
    else
      raise notice 'ok  an authorization ending soon with hours left is chased, with a draft to send';
    end if;
  end if;

  -- One ending outside thirty days is not.
  update public.authorizations set end_date = v_today + 45 where id = v_auth;
  if exists (select 1 from public.authorizations_ending_soon(v_today) where auth_id = v_auth) then
    failures := failures || 'FAILED: an authorization forty-five days out is being chased'::text;
  else
    raise notice 'ok  one outside thirty days is left alone';
  end if;

  -- And one with its hours used up is not, however close the end date.
  update public.authorizations set end_date = v_today + 10 where id = v_auth;
  insert into public.service_entries (auth_id, date, hours, notes)
  values (v_auth, v_today - 1, 40, 'ZZ all of them');
  if exists (select 1 from public.authorizations_ending_soon(v_today) where auth_id = v_auth) then
    failures := failures || 'FAILED: an authorization with no hours left is being chased for a renewal'::text;
  else
    raise notice 'ok  one with no hours left is not chased - there is nothing to continue';
  end if;

  -- ── Rule 8: the hire starts the clock ─────────────────────
  insert into public.employers (name) values ('ZZ Chase Employer') returning id into v_employer;
  insert into public.job_leads (employer_id, title) values (v_employer, 'ZZ Shelf Stacker')
  returning id into v_lead;

  insert into public.authorizations
    (client_id, number, service_type, rate_type, rate, status, start_date, end_date)
  values (v_place_c, 'ZZ-CH-3', 'Job Placement', 'Flat Fee', 1500, 'Authorized',
          v_today - 30, v_today + 120);

  insert into public.lead_matches (lead_id, client_id, status)
  values (v_lead, v_place_c, 'Applied') returning id into v_match;

  update public.lead_matches set status = 'Hired', decided_on = v_today - 2 where id = v_match;

  select follow_up_on into v_date from public.lead_matches where id = v_match;
  if v_date <> v_today - 2 + 28 then
    failures := failures || format('FAILED: the retention milestone is %s, expected %s (it is four weeks, and not the bill-by)',
                                   v_date, v_today - 2 + 28)::text;
  elsif not exists (select 1 from public.calendar_events
                     where source_match_id = v_match and source_kind = 'Follow-up') then
    failures := failures ||
      'FAILED: the milestone did not reach the calendar through the existing reminder sync'::text;
  else
    raise notice 'ok  a hire sets the four-week milestone, and the existing sync puts it on the calendar';
  end if;

  -- Not called here: the AFTER trigger ran it when the status changed.
  select placement_id into v_place from public.lead_matches where id = v_match;

  if v_place is null then
    failures := failures || 'FAILED: no placement was started'::text;
  elsif (select start_date from public.placements where id = v_place) <> v_today - 2 then
    failures := failures || 'FAILED: the placement did not start on the hire date'::text;
  elsif (select placement_id from public.lead_matches where id = v_match) <> v_place then
    failures := failures || 'FAILED: the match was not linked to its placement'::text;
  else
    raise notice 'ok  the placement starts on the hire date, and the match points at it';
  end if;

  select first_work_day into v_date from public.authorizations where number = 'ZZ-CH-3';
  if v_date <> v_today - 2 then
    failures := failures || format('FAILED: the first day of work is %s', v_date)::text;
  else
    select bill_by into v_date from public.authorizations where number = 'ZZ-CH-3';
    if v_date <> v_today - 2 + 7 then
      failures := failures ||
        format('FAILED: bill-by is %s, not the first work day plus 7 (0188)', v_date)::text;
    else
      raise notice 'ok  the first day of work is recorded, and bill-by follows from it (+7)';
    end if;
  end if;

  -- The forms are already outstanding, by the service rules. Asserted rather
  -- than written, because writing them again is a second place to be wrong.
  select public.authorization_missing_forms(
           (select id from public.authorizations where number = 'ZZ-CH-3'))
    into v_text;
  if v_text is null or position('60' in v_text) = 0 or position('92' in v_text) = 0 then
    failures := failures ||
      format('FAILED: USOR 60 and 92 are not outstanding on the placement: %s',
             coalesce(v_text, '(none)'))::text;
  else
    raise notice 'ok  USOR 60 and 92 are already outstanding on a placement: %', v_text;
  end if;

  -- Rei hears, with the milestone date.
  if not exists (select 1 from public.notifications
                  where staff_id = v_rei and client_id = v_place_c
                    and text like '%four-week milestone%') then
    failures := failures || 'FAILED: Rei was not told the milestone date'::text;
  elsif not exists (select 1 from public.tasks
                     where assigned_staff_id = v_rei and client_id = v_place_c and status = 'Open') then
    failures := failures || 'FAILED: nothing reached Rei''s My day'::text;
  else
    raise notice 'ok  Rei hears about the hire, with the milestone date, in all three places';
  end if;

  -- ── and a hire does not conjure an authorization ───────────
  insert into public.clients (name, stage, status, counselor_id, assigned_staff_id)
  values ('ZZ No Placement Auth', 'Placement', 'Active', v_counsel, v_rei)
  returning id into v_place_c;
  insert into public.lead_matches (lead_id, client_id, status)
  values (v_lead, v_place_c, 'Applied') returning id into v_match;
  select count(*) into v_n from public.authorizations;
  update public.lead_matches set status = 'Hired', decided_on = v_today where id = v_match;

  if (select count(*) from public.authorizations) <> v_n then
    failures := failures || 'FAILED: a hire created an authorization'::text;
  elsif not exists (select 1 from public.tasks
                     where assigned_staff_id = v_margaret and client_id = v_place_c
                       and title like 'Request a placement authorization%') then
    failures := failures || 'FAILED: Margaret was not asked to request a placement authorization'::text;
  else
    raise notice 'ok  a hire with no placement authorization creates none, and asks Margaret for one';
  end if;

  -- An edit to a match already hired does not reset the clock to today.
  update public.lead_matches set notes = 'ZZ edited later' where id = v_match;
  if (select decided_on from public.lead_matches where id = v_match) <> v_today then
    failures := failures || 'FAILED: editing a hired match moved the hire date'::text;
  else
    raise notice 'ok  editing a match that was already hired does not restart the clock';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- THE CHASING RULES VERIFIED ---';
end $$;

rollback;
