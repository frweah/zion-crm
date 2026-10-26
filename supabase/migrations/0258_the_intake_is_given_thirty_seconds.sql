-- Zion Vocational Rehab CRM — the intake is given thirty seconds
--
-- `zion-intake` has been logging a pg_net error every fifteen minutes since
-- it was turned on:
--
--   Timeout of 5000 ms reached. Total time: 5009 ms
--   (DNS 67 ms, TCP/SSL handshake 68 ms, HTTP Request/Response 4874 ms)
--
-- Five seconds is pg_net's default, and reading the forty most recent
-- messages in service@ through Graph does not fit in it. Nothing was lost -
-- the route is `maxDuration = 300` and finishes on Vercel after pg_net has
-- stopped waiting for it - but an error logged every quarter of an hour is an
-- error nobody reads, and the next real one arrives in the middle of 96 of
-- these a day.
--
-- Thirty seconds, which the owner chose on 26 Oct 2026. `zion-outlook-sync`
-- and `zion-sms-reminders` already pass 240000 for the same reason, so this
-- is the third job to say how long it is prepared to wait rather than the
-- first.
--
-- The secret is not written here, for the reason 0183 gives: the command is
-- read back from the job that already carries it and handed to `alter_job`
-- with the timeout appended, so the only copy of the shared secret stays the
-- one in `cron.job`.

do $$
declare
  v_job     bigint;
  v_command text;
begin
  select jobid, command into v_job, v_command
    from cron.job where jobname = 'zion-intake';

  if v_job is null then
    raise exception 'zion-intake is not scheduled, so there is nothing to give thirty seconds to.'
      using hint = 'Schedule it with 0183 first.';
  end if;

  if position('timeout_milliseconds' in v_command) > 0 then
    raise notice 'zion-intake already says how long it will wait; left alone';
    return;
  end if;

  -- The call ends `);`, so the parameter goes in front of that closing
  -- bracket. Asserted rather than assumed: a command of another shape is left
  -- as it is rather than rewritten into something that would not run.
  if v_command !~ '\)\s*;?\s*$' then
    raise exception 'zion-intake does not end in a function call, so the timeout cannot be appended.'
      using hint = 'Set timeout_milliseconds by hand with cron.alter_job.';
  end if;

  v_command := regexp_replace(v_command, '\)\s*;?\s*$', ', timeout_milliseconds := 30000);');

  perform cron.alter_job(v_job, command := v_command);
  raise notice 'the intake now waits thirty seconds for the route to answer';
end $$;
