-- Zion Vocational Rehab CRM — turn on the Monday health run
--
-- RUN THIS ONCE THE APP IS DEPLOYED. Before running, replace both
-- placeholders:
--   YOUR-APP-URL        e.g. https://crm.zionvocrehab.com
--   YOUR-CRON-SECRET    the CRON_SECRET from .env.local, which must also be
--                       set in Vercel's environment variables
--
-- One email, Monday morning, from service@ to every active Admin, with the
-- seven things the owner asked for (0278).
--
-- **Two firings, one email, and 07:00 Mountain all year.** pg_cron thinks in
-- UTC. Utah is UTC-6 from March to November and UTC-7 the rest of the year, so
-- a job fixed at one UTC hour is 07:00 Mountain for half the year and 06:00
-- for the other half. The job fires at 13:00 and 14:00 UTC on a Monday and the
-- route sends only when the hour in Utah is 7 - which is exactly one of the
-- two, whichever half of the year it is.
--
-- The alternative was one firing and an hour of drift twice a year. Two http
-- calls a week is cheaper than a quarterly conversation about why the email
-- arrived at six.

create extension if not exists pg_net;

do $$
begin
  perform cron.unschedule('zion-monday-health');
exception when others then
  null;
end $$;

select cron.schedule(
  'zion-monday-health',
  '0 13,14 * * 1',
  $cron$
    select net.http_post(
      url     := 'YOUR-APP-URL/api/cron/health',
      headers := jsonb_build_object(
                   'Authorization', 'Bearer YOUR-CRON-SECRET',
                   'Content-Type', 'application/json'
                 ),
      body    := '{}'::jsonb
    );
  $cron$
);

-- Check it is scheduled:
--   select jobname, schedule, active from cron.job order by jobname;
--
-- And what it would say today, without sending anything:
--   curl -H "Authorization: Bearer $CRON_SECRET" 'https://APP/api/cron/health?dry=1'
--
-- The two things the email reports that nothing else can work out are written
-- from a laptop:
--   node --env-file=.env.local scripts/verify-all.mjs
--   node --env-file=.env.local scripts/backup-fingerprint.mjs > before.json
--
-- The secret sits in the job definition, which only the postgres role can
-- read. Rotate it in both places — Vercel and here — if it is ever exposed.
