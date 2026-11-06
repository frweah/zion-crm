-- Zion Vocational Rehab CRM — turn on the "To file" sweeps (item E)
--
-- Run once, after the route is deployed. It copies the nightly digest's call
-- — the same app address and the same cron secret — onto /api/cron/to-file,
-- so the secret is never typed anywhere and never lands in a file.
--
-- Nightly, at 06:20 UTC, which is just before midnight in Utah and after the
-- day's mail sync has run. Nothing about the hour is load-bearing: the sweep
-- only offers, and an offer that arrives an hour later is an offer that
-- arrives an hour later.
--
-- **The first sweep is a decision, not a schedule.** The calendar half looks
-- back sixty days the first time it sees a person and two days afterwards,
-- which the route works out for itself. The mail half looks back two days,
-- because the practice has months of unfiled mail that names a client and
-- putting ninety-five suggestions into somebody's inbox on a Tuesday night is
-- not a thing to do without being asked. To offer that backlog deliberately:
--
--   curl -H "Authorization: Bearer $CRON_SECRET" 'https://APP/api/cron/to-file?since=90'
--
-- and to see what it would offer without offering anything, add dry=1.

do $$
declare
  v_command text;
begin
  select command into v_command from cron.job where jobname = 'zion-nightly-digest';
  if v_command is null then
    raise exception 'The nightly digest is not scheduled, so there is no address and secret to copy. Run enable_email_digest.sql first.';
  end if;
  begin
    perform cron.unschedule('zion-to-file');
  exception when others then
    null;
  end;
  perform cron.schedule('zion-to-file', '20 6 * * *',
    replace(v_command, '/api/cron/notify', '/api/cron/to-file'));
end $$;

-- Check it is scheduled:
--   select jobname, schedule, active from cron.job order by jobname;
