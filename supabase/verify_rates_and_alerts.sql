-- Zion Vocational Rehab CRM — the rate schedule, and one alert per record
-- (0169, 0170 — Billing Simplification Brief §§11, 13.11, 13.13)
--
-- What has to hold, each tried from the direction that would break it:
--
--   Every service the practice can pick has a rate in the schedule, and the
--   schedule is the only place a rate comes from. A service it does not price
--   returns nothing rather than a guess, so the form asks.
--
--   Job Development + HQ Indicator is 1,120. It is the one the workbook
--   expresses as a sum, it is what the practice has billed twelve times, and a
--   hard-coded copy in the code said 560 - so it is named here by number.
--
--   Changing a rate in the schedule changes what the form offers, with no
--   deploy. That is the whole point of it being a table.
--
--   One authorization raises one alert, never two, however many things are
--   wrong with it at once - and the sentence in the alert is the sentence on
--   the record and in the working list.
--
--   An authorization out of hours says so before anything else except that it
--   cannot be submitted, and Job Search hears about that one.
--
--   A kept placeholder raises nothing: it is history.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_client  uuid;
  v_auth    uuid;
  v_ph      uuid;
  v_fee     numeric;
  v_kind    text;
  v_n       int;
  v_text    text;
  v_urgency int;
  v_roles   text[];
  svc       text;
  failures  text[] := '{}';
begin
  -- ── every service the form offers has a rate ───────────────
  foreach svc in array array['Job Coaching', 'Job Development', 'Job Development + HQ Indicator',
                             'Job Placement', 'Job Placement (SE)', 'WSA Tier 1', 'WSA Tier 2',
                             'HQ Indicator', 'Life Skills', 'CRP Group Training',
                             'Temporary Work Experience'] loop
    select fee into v_fee from public.service_rate(svc);
    if v_fee is null or v_fee <= 0 then
      failures := failures || format('FAILED: the rate schedule does not price %s', svc);
    end if;
  end loop;
  if failures = '{}' then
    raise notice 'ok  every service the practice can pick has a rate in the schedule';
  end if;

  -- ── the one that was wrong in the code ─────────────────────
  select fee into v_fee from public.service_rate('Job Development + HQ Indicator');
  if v_fee <> 1120 then
    failures := failures || format('FAILED: Job Development + HQ Indicator is %s, and it is 1120 (560 + 560)', v_fee);
  else
    raise notice 'ok  Job Development + HQ Indicator is 1,120, which is what the practice bills';
  end if;

  -- ── a service with no rate asks rather than guessing ───────
  if exists (select 1 from public.service_rate('Other')) then
    failures := failures || 'FAILED: a service the schedule does not price was given a rate anyway'::text;
  else
    raise notice 'ok  a service the schedule does not price returns nothing, so the form asks';
  end if;

  -- ── changing the schedule changes the rate ─────────────────
  update public.rate_schedule set fee = 50 where crm_service = 'Job Coaching';
  select fee into v_fee from public.service_rate('Job Coaching');
  if v_fee <> 50 then
    failures := failures || format('FAILED: the schedule says 50 and the rate came back %s', v_fee);
  else
    raise notice 'ok  a rate changed in the schedule is the rate the form offers, with no deploy';
  end if;
  update public.rate_schedule set fee = 45 where crm_service = 'Job Coaching';

  -- ── one alert per authorization ────────────────────────────
  insert into public.clients (name, stage, status) values ('ZZ Alert Client', 'Placement', 'Active')
  returning id into v_client;

  -- Everything wrong at once: overdue to bill, ending within the fortnight,
  -- and under a tenth of its hours left. Three alerts, once.
  insert into public.authorizations
    (client_id, number, service_type, rate_type, rate, total_hours, carried_used,
     start_date, end_date, status, bill_by)
  values (v_client, 'V0000980', 'Job Coaching', 'Hourly', 45, 20, 19,
          public.practice_today() - 60, public.practice_today() + 7, 'Due',
          public.practice_today() - 10)
  returning id into v_auth;

  select count(*) into v_n from public.authorization_attention(v_auth);
  if v_n <> 1 then
    failures := failures || format('FAILED: the attention line came back %s times', v_n);
  end if;
  select attention, urgency into v_text, v_urgency from public.authorization_attention(v_auth);
  if v_text not like 'Overdue%' then
    failures := failures || format('FAILED: overdue should outrank ending soon and low hours (%s)', v_text);
  else
    raise notice 'ok  three things wrong at once is one line, and it is the most pressing of them';
  end if;

  perform public.generate_notifications();
  select count(*) into v_n from public.notifications
   where dedupe_key like 'authorization:' || v_auth || ':%' and resolved_at is null;
  if v_n <> 1 then
    failures := failures || format('FAILED: one authorization raised %s alerts', v_n);
  end if;
  select text into v_text from public.notifications
   where dedupe_key like 'authorization:' || v_auth || ':%' and resolved_at is null;
  if v_text is null or v_text not like '%Overdue%' then
    failures := failures || format('FAILED: the alert does not say what the record says (%s)', v_text);
  else
    raise notice 'ok  the alert carries the same sentence as the record and the list';
  end if;

  -- And no authorization anywhere has two.
  select count(*) into v_n from (
    select split_part(dedupe_key, ':', 2) a, count(*) c
      from public.notifications
     where kind = 'authorization' and resolved_at is null
     group by 1 having count(*) > 1) d;
  if v_n > 0 then
    failures := failures || format('FAILED: %s authorization(s) have more than one alert', v_n);
  else
    raise notice 'ok  no authorization anywhere raises more than one alert';
  end if;

  -- ── out of hours outranks the rest, and reaches Job Search ──
  update public.authorizations set carried_used = 20 where id = v_auth;
  select attention, urgency into v_text, v_urgency from public.authorization_attention(v_auth);
  if v_urgency <> 1 or v_text not like 'No hours left%' then
    failures := failures || format('FAILED: out of hours did not come first (%s, urgency %s)', v_text, v_urgency);
  end if;
  perform public.generate_notifications();
  select roles into v_roles from public.notifications
   where dedupe_key like 'authorization:' || v_auth || ':%' and resolved_at is null;
  if not ('Job Search' = any (v_roles)) then
    failures := failures || 'FAILED: an authorization out of hours did not reach the people serving the client'::text;
  else
    raise notice 'ok  out of hours comes first, and the people serving the client hear about it';
  end if;

  -- ── a kept placeholder raises nothing ──────────────────────
  insert into public.authorizations
    (client_id, number, service_type, rate_type, rate, total_hours, status,
     start_date, end_date, bill_by, is_placeholder)
  values (v_client, 'coaching ZZ99', 'Job Coaching', 'Hourly', 45, 10, 'Due',
          public.practice_today() - 60, public.practice_today() + 7,
          public.practice_today() - 10, true)
  returning id into v_ph;
  perform public.generate_notifications();
  if exists (select 1 from public.notifications
              where dedupe_key like 'authorization:' || v_ph || ':%' and resolved_at is null) then
    failures := failures || 'FAILED: a kept placeholder raised an alert'::text;
  else
    raise notice 'ok  a kept placeholder is history: no alert, and not on the working list';
  end if;
  if exists (select 1 from public.billing_worklist() w where w.id = v_ph) then
    failures := failures || 'FAILED: a kept placeholder is on the working list'::text;
  end if;

  -- ── and nobody signed out reads any of it ──────────────────
  if has_function_privilege('anon', 'public.service_rate(text)', 'execute')
     or has_function_privilege('anon', 'public.authorization_attention(uuid, date)', 'execute') then
    failures := failures || 'FAILED: somebody not signed in can read the rates or the alerts'::text;
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
