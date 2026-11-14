-- Zion Vocational Rehab CRM — the recordings are read every quarter hour
--
-- `/api/cron/recordings` sends the recordings nobody has sent and asks about
-- the jobs already running at Azure. This schedules it.
--
-- Every fifteen minutes, which is more often than anything else about a
-- recording needs: a batch job takes minutes and nobody is waiting at a
-- screen. The reason for the frequency is the second half of the route - a
-- job that has finished is not read until somebody asks, and a person who has
-- just uploaded a meeting should find the draft waiting rather than find out
-- tomorrow. Each run with nothing to do is one query that returns no rows.
--
-- The secret is not written here. 0183 set that rule and every scheduled job
-- since has followed it: the command is built from the one
-- `zion-clock-sweep` already carries, so the only copy of the shared bearer
-- token stays the one in `cron.job`.
--
-- The clock sweep rather than the nightly digest, because the sweep is the
-- other quarter-hourly job and its command already carries whatever pg_net
-- options a quarter-hourly call wants.

begin;

do $$
declare
  v_source  text;
  v_command text;
  v_job     bigint;
begin
  select command into v_source
    from cron.job where jobname = 'zion-clock-sweep';

  if v_source is null then
    raise exception 'zion-clock-sweep is not scheduled, so there is no command to build this one from.'
      using hint = 'Schedule the clock sweep first, or add zion-recordings by hand with the secret.';
  end if;

  -- Asserted rather than assumed: if the sweep's command is not the shape
  -- this expects, swapping the path would produce something that does not
  -- run, and a job that silently calls nothing is worse than no job.
  if position('/api/cron/clock' in v_source) = 0 then
    raise exception 'zion-clock-sweep does not call /api/cron/clock, so the recordings command cannot be built from it.'
      using hint = 'Add zion-recordings by hand with cron.schedule.';
  end if;

  v_command := replace(v_source, '/api/cron/clock', '/api/cron/recordings');

  /*
   * Four minutes, because this one waits on somebody else.
   *
   * The route submits to Azure and asks Azure about jobs, and a slow answer
   * from a service in another region is the ordinary case rather than a
   * fault. The route is maxDuration = 300 and finishes either way; this stops
   * pg_net logging a timeout every quarter of an hour.
   */
  if position('timeout_milliseconds' in v_command) = 0 then
    if v_command !~ '\)\s*;?\s*$' then
      raise exception 'The clock sweep command does not end in a function call, so the timeout cannot be appended.'
        using hint = 'Add zion-recordings by hand with cron.schedule.';
    end if;
    v_command := regexp_replace(v_command, '\)\s*;?\s*$', ', timeout_milliseconds := 240000);');
  end if;

  select jobid into v_job from cron.job where jobname = 'zion-recordings';
  if v_job is null then
    perform cron.schedule('zion-recordings', '*/15 * * * *', v_command);
    raise notice 'zion-recordings scheduled every fifteen minutes';
  else
    perform cron.alter_job(v_job, schedule := '*/15 * * * *', command := v_command, active := true);
    raise notice 'zion-recordings was already scheduled; schedule and command set';
  end if;
end $$;

commit;
