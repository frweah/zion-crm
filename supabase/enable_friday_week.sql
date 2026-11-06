-- Zion Vocational Rehab CRM — turn on the Friday week email (item G)
--
-- Run once, after the route is deployed. It copies the nightly digest's call
-- — the same app address and the same cron secret — onto /api/cron/week, so
-- the secret is never typed anywhere and never ends up in a file. The
-- messages digest is turned on the same way, and for the same reason.
--
-- **Two firings, one email, and 15:00 Mountain all year.** pg_cron thinks in
-- UTC. Utah is UTC-6 from March to November and UTC-7 the rest of the year, so
-- a job fixed at one UTC hour is three in the afternoon for half the year and
-- two for the other half. The job fires at 21:00 and 22:00 UTC on a Friday and
-- the route sends only when the hour in Utah is 15 — which is exactly one of
-- the two, whichever half of the year it is. Two http calls a week is cheaper
-- than a twice-yearly conversation about why the email arrived at two.

do $$
declare
  v_command text;
begin
  select command into v_command from cron.job where jobname = 'zion-nightly-digest';
  if v_command is null then
    raise exception 'The nightly digest is not scheduled, so there is no address and secret to copy. Run enable_email_digest.sql first.';
  end if;
  begin
    perform cron.unschedule('zion-friday-week');
  exception when others then
    null;
  end;
  perform cron.schedule('zion-friday-week', '0 21,22 * * 5',
    replace(v_command, '/api/cron/notify', '/api/cron/week'));
end $$;

-- Check it is scheduled:
--   select jobname, schedule, active from cron.job order by jobname;
--
-- And what it would say today, without sending anything:
--   curl -H "Authorization: Bearer $CRON_SECRET" 'https://APP/api/cron/week?dry=1'
