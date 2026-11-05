-- Zion Vocational Rehab CRM — turn on the clock's two automatic rules
--
-- RUN THIS ONCE THE APP IS DEPLOYED. Before running, replace both
-- placeholders:
--   YOUR-APP-URL        e.g. https://crm.zionvocrehab.com
--   YOUR-CRON-SECRET    the CRON_SECRET from .env.local, which must also be
--                       set in Vercel's environment variables
--
-- Quarter-hourly, and the hour does not matter, which is why this one needs no
-- daylight-saving dance: both rules are about minutes.
--
--   A session nobody closed is told about at ten hours, to the person and to
--   whoever they answer to, and closed at fourteen - at the last thing the
--   practice saw that person do, flagged, and left for them to confirm or
--   correct.
--
--   Somebody expected at nine who has not clocked in by a quarter past is
--   reminded. Them only, and never by text (0293).
--
-- Both rules are in the database. The route carries nothing but the request,
-- so running this twice in a minute does no harm: a notification is said once
-- by its dedupe key and a closed session is no longer open to close.

-- zion- prefixed, like every other job. verify_scheduler fails any zion-% job
-- that appears in no enable script, and a job called plain "clock-sweep"
-- would have sat outside that rule - which is the one hole the rule exists to
-- close, so a name that dodges it is worse than no name at all.
select cron.schedule(
  'zion-clock-sweep',
  '*/15 * * * *',
  $$
    select net.http_post(
      url     := 'YOUR-APP-URL/api/cron/clock',
      headers := jsonb_build_object(
                   'Content-Type',  'application/json',
                   'Authorization', 'Bearer YOUR-CRON-SECRET'),
      body    := '{}'::jsonb
    );
  $$
);

-- To see it, and to take it off again:
--
--   select jobid, jobname, schedule, active from cron.job where jobname = 'zion-clock-sweep';
--   select cron.unschedule('zion-clock-sweep');
