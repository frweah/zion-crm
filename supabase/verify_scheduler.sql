-- The scheduler, as the database actually holds it (0278)
--
-- `check-scheduler.mjs` asks the repository whether every cron route has a
-- schedule written down. This asks the database whether the schedule is
-- really there - which is the half that cannot be checked in prebuild, and the
-- half that goes wrong in the way nobody notices: an `enable_*.sql` that was
-- written, committed, reviewed and never run.
--
-- What has to hold:
--
--   Every job named in an enable script or a migration is in `cron.job`, and
--   active.
--
--   Every job posts to this app rather than to a placeholder somebody forgot
--   to replace.
--
--   The Monday health run is on a Monday, twice, so one of the two firings is
--   07:00 Mountain whichever half of the year it is.
--
--   And the health summary answers, because an email built on a function that
--   errors is an email nobody gets and nothing says so.
--
-- Read-only: it changes nothing and so needs no transaction. It is in the
-- suite rather than run by hand because the suite is what the Monday email
-- reports on, and a scheduler that has stopped is exactly what it should say.

do $$
declare
  r record;
  v_expected text[] := array[
    'zion-intake', 'zion-chase', 'zion-reports', 'zion-outlook-sync',
    'zion-messages-digest', 'zion-scheduled-texts', 'zion-sms-reminders',
    'zion-nightly-alerts', 'zion-nightly-digest', 'zion-monday-health',
    'zion-clock-sweep'
  ];
  v_name text;
  v_n integer;
  v_stuck integer;
  v_life numeric;
  failures text[] := '{}';
begin
  -- ── every job the practice expects is there, and active ───
  foreach v_name in array v_expected loop
    if not exists (select 1 from cron.job where jobname = v_name) then
      failures := failures || format(
        'FAILED: %s is not scheduled. The enable_*.sql for it was written and never run.', v_name);
    elsif not (select active from cron.job where jobname = v_name) then
      failures := failures || format('FAILED: %s is scheduled and switched off', v_name);
    end if;
  end loop;
  if array_length(failures, 1) is null then
    raise notice 'ok  all % scheduled jobs are there and active', array_length(v_expected, 1);
  end if;

  -- ── and nothing else is ───────────────────────────────────
  -- A job somebody added by hand and nobody wrote down is a thing that runs
  -- for years without appearing in any file.
  for r in select jobname from cron.job where jobname like 'zion-%' and not (jobname = any (v_expected)) loop
    failures := failures || format(
      'FAILED: %s is scheduled and is in no enable script or migration', r.jobname);
  end loop;

  -- ── no placeholders ───────────────────────────────────────
  -- The enable scripts ship with YOUR-APP-URL and YOUR-CRON-SECRET in them,
  -- which is right - they are not secrets in the repository - and a job
  -- scheduled with either still in it posts nowhere, successfully, for ever.
  select count(*) into v_n from cron.job
   where command like '%YOUR-APP-URL%' or command like '%YOUR-CRON-SECRET%';
  if v_n > 0 then
    failures := failures || format(
      'FAILED: %s job(s) still hold a placeholder instead of the address or the secret', v_n);
  else
    raise notice 'ok  no job posts to a placeholder';
  end if;

  -- ── and each one posts to the practice ──────────────
  --
  -- A placeholder is not the only address that goes nowhere.
  -- zion-monday-health was scheduled against http://localhost:3000, and there
  -- is no localhost from inside Supabase: it fired every Monday, reached
  -- nothing, and said nothing. This script checked that job's *schedule* and
  -- never its address - the fault CLAUDE.md names, a question asked merely
  -- near the rule, and it passed for as long as the job has existed.
  --
  -- Asked of every job that posts rather than of a list of the ones that
  -- should, so a tenth job added next month is covered without anybody
  -- remembering to add it here.
  for r in
    select jobname, (regexp_match(command, 'url\s*:=\s*''([^'']*)'''))[1] as url
      from cron.job
     where command like '%net.http_post%'
  loop
    if r.url is null then
      failures := failures || format(
        'FAILED: %s posts over http and no address can be read out of it', r.jobname);
    elsif r.url not like 'https://crm.zionvocrehab.com/%' then
      failures := failures || format(
        'FAILED: %s posts to %s, which is not the practice - it will fire and reach nothing',
        r.jobname, r.url);
    end if;
  end loop;
  if array_length(failures, 1) is null then
    raise notice 'ok  every scheduled job posts to crm.zionvocrehab.com';
  end if;

  -- ── the Monday run ────────────────────────────────────────
  if exists (select 1 from cron.job where jobname = 'zion-monday-health') then
    select schedule into v_name from cron.job where jobname = 'zion-monday-health';
    if v_name <> '0 13,14 * * 1' then
      failures := failures || format(
        'FAILED: the Monday health run is scheduled "%s" and not "0 13,14 * * 1", so it is not 07:00 Mountain all year',
        v_name);
    else
      raise notice 'ok  the Monday health run fires at 13:00 and 14:00 UTC on a Monday';
    end if;
  end if;

  -- ── and the summary it is built on answers ────────────────
  begin
    perform public.practice_health_summary();
    raise notice 'ok  the health summary answers, so the Monday email has something to say';
  exception when others then
    failures := failures || format('FAILED: the health summary errors (%s): %s', sqlstate, sqlerrm);
  end;

  -- ── a threshold below what the thing it measures does ─────
  -- 0278 called a Graph subscription "expiring" with less than three days
  -- left. Microsoft's maximum lifetime for one is 70 hours, so that threshold
  -- sat above the longest a healthy subscription can live and reported all
  -- four as about to lapse - in the subject line of the first dry run.
  --
  -- Asserted against the subscriptions actually on file rather than against
  -- the number 70, so a change at Microsoft's end shows up here as a
  -- threshold that has stopped making sense rather than as a weekly false
  -- alarm nobody can explain.
  select max(extract(epoch from (expires_at - coalesce(renewed_at, created_at))) / 3600)
    into v_life from public.microsoft_subscriptions;
  select count(*) into v_n from public.microsoft_subscriptions;

  if v_n = 0 then
    raise notice 'note  no subscriptions on file, so the expiry threshold cannot be checked against one';
  elsif v_life is null then
    raise notice 'note  no subscription says how long it was given';
  else
    -- The function's own answer, not the same question asked again here.
    -- Written the second way first, and faulting the function to three days
    -- changed nothing: the assertion was measuring its own copy of the rule.
    select h.graph_expiring into v_stuck from public.practice_health_summary() h;
    if v_stuck = v_n and v_n > 1 then
      failures := failures || format(
        'FAILED: every one of the %s subscriptions counts as stuck, which means the threshold is above the %s-hour life they are given',
        v_n, round(v_life, 1));
    else
      raise notice 'ok  the expiry threshold is below the % hours a subscription is given, so a healthy one does not trip it',
        round(v_life, 1);
    end if;
  end if;

  -- ── the two things only a person can record ───────────────
  -- Not a failure: an empty record is a true answer on a new database, and
  -- the email reports its age. Said out loud so a reader of this suite knows
  -- which way round it is.
  for v_name in select k from unnest(array['verify', 'backup']) k loop
    if not exists (select 1 from public.practice_health where kind = v_name) then
      raise notice 'note  nothing has recorded a % run; the Monday email will say so', v_name;
    else
      raise notice 'ok  the last % run was recorded %', v_name,
        (select to_char(at, 'FMMon FMDD') from public.practice_health where kind = v_name);
    end if;
  end loop;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- SCHEDULER VERIFIED ---';
end $$;
