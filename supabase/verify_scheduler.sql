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
    'zion-nightly-alerts', 'zion-nightly-digest', 'zion-monday-health'
  ];
  v_name text;
  v_n integer;
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
