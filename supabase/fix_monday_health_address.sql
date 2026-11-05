-- Zion Vocational Rehab CRM — point the Monday health run at the practice
--
--   node --env-file=.env.local scripts/run-sql.mjs supabase/fix_monday_health_address.sql
--
-- `zion-monday-health` was scheduled against http://localhost:3000, which is
-- what enable_monday_health.sql looks like when somebody substitutes the
-- address they were developing against. There is no localhost from inside
-- Supabase, so every Monday since it was scheduled the job has fired, reached
-- nothing, and reported nothing - and verify_scheduler checked the job's
-- schedule and never its address, so it passed the whole time. The address
-- check is in verify_scheduler now; this is the repair.
--
-- The bearer is read out of a job that already carries it rather than typed
-- in. The secret lives in cron.job and in Vercel, and a repair script that
-- takes it as a parameter is a repair script somebody pastes it into.

do $$
declare
  v_secret text;
  v_was    text;
  v_host   text := 'https://crm.zionvocrehab.com';
begin
  select (regexp_match(command, 'Bearer ([^'' ]+)'))[1]
    into v_secret
    from cron.job
   where jobname = 'zion-intake';
  if v_secret is null or length(v_secret) < 8 then
    raise exception 'no bearer could be read from zion-intake, so nothing was changed';
  end if;

  select (regexp_match(command, 'url\s*:=\s*''([^'']*)'''))[1]
    into v_was from cron.job where jobname = 'zion-monday-health';
  if v_was is null then
    raise exception 'zion-monday-health is not scheduled, so run enable_monday_health.sql instead';
  end if;
  if v_was like v_host || '%' then
    raise notice 'ok  zion-monday-health already posts to %, so nothing was changed', v_was;
    return;
  end if;

  -- Same name, so this replaces the job rather than adding a second one, and
  -- the same schedule: 13:00 and 14:00 UTC on a Monday is 07:00 Mountain all
  -- year, which is why there are two hours and not one.
  perform cron.schedule(
    'zion-monday-health',
    '0 13,14 * * 1',
    format(
      $q$select net.http_post(
      url     := %L,
      headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', %L),
      body    := '{}'::jsonb
    );$q$,
      v_host || '/api/cron/health',
      'Bearer ' || v_secret));

  raise notice 'zion-monday-health was posting to % and now posts to the practice', v_was;
end $$;
