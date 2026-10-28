-- Zion Vocational Rehab CRM — 0261 the drafts are waiting on Monday
--
-- `/api/cron/reports` drafts a week on Monday and a month on the 1st. This
-- schedules it, and the schedule is daily.
--
-- Daily for a job that has something to do twice a month, because pg_cron
-- schedules in UTC and the practice lives in Mountain time. `0 12 1 * *` is
-- 06:00 on the 1st in summer and 05:00 in winter, and a job pinned to a UTC
-- day-of-month is a job that drafts March twice and skips November one year
-- in some number of years. Nobody would find that for a month. So the
-- schedule says "every day" and the route asks whether it is Monday in Utah,
-- or the 1st in Utah, where there is a timezone to ask about. The unique keys
-- on client and week and on client and month (0260) make the other runs cost
-- one query and write nothing.
--
-- 12:50 UTC is five past six in the morning in Utah in summer, five past
-- seven in winter — the same calendar day either way, which is the only thing
-- the route needs from the hour. It sits twenty minutes ahead of
-- `zion-nightly-digest` (13:05) on purpose: the drafts and the reports due
-- have to exist before the mail that tells somebody about them goes out.
--
-- The secret is not written here. 0183 set that rule and 0258 followed it:
-- the command is built from the one `zion-nightly-digest` already carries, so
-- the only copy of the shared bearer token stays the one in `cron.job`.

do $$
declare
  v_source  text;
  v_command text;
  v_job     bigint;
begin
  select command into v_source
    from cron.job where jobname = 'zion-nightly-digest';

  if v_source is null then
    raise exception 'zion-nightly-digest is not scheduled, so there is no command to build this one from.'
      using hint = 'Schedule the digest first, or add zion-reports by hand with the secret.';
  end if;

  -- Asserted rather than assumed: if the digest's command is not the shape
  -- this expects, swapping the path would produce something that does not
  -- run, and a job that silently calls nothing is worse than no job.
  if position('/api/cron/notify' in v_source) = 0 then
    raise exception 'zion-nightly-digest does not call /api/cron/notify, so the reports command cannot be built from it.'
      using hint = 'Add zion-reports by hand with cron.schedule.';
  end if;

  v_command := replace(v_source, '/api/cron/notify', '/api/cron/reports');

  -- Drafting twenty clients means twenty reads of the record, which does not
  -- fit in pg_net's five-second default. The route is maxDuration = 300 and
  -- finishes either way; this stops an error being logged every morning.
  if position('timeout_milliseconds' in v_command) = 0 then
    if v_command !~ '\)\s*;?\s*$' then
      raise exception 'The digest command does not end in a function call, so the timeout cannot be appended.'
        using hint = 'Add zion-reports by hand with cron.schedule.';
    end if;
    v_command := regexp_replace(v_command, '\)\s*;?\s*$', ', timeout_milliseconds := 240000);');
  end if;

  select jobid into v_job from cron.job where jobname = 'zion-reports';
  if v_job is null then
    perform cron.schedule('zion-reports', '50 12 * * *', v_command);
    raise notice 'zion-reports scheduled daily at 12:50 UTC';
  else
    perform cron.alter_job(v_job, schedule := '50 12 * * *', command := v_command, active := true);
    raise notice 'zion-reports was already scheduled; schedule and command set';
  end if;
end $$;
