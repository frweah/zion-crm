-- Zion Vocational Rehab CRM — turn on the nightly email digest
--
-- RUN THIS ONCE THE APP IS DEPLOYED AND HAS A URL. Not before: the database
-- cannot post to a laptop.
--
-- The rules themselves already run nightly without this — migration 0010
-- schedules generate_notifications() under pg_cron, so alerts appear on the
-- dashboard whether or not anyone is logged in. This adds the second half:
-- posting to /api/cron/notify so the day's items are also emailed.
--
-- Before running, replace both placeholders:
--   YOUR-APP-URL   e.g. https://crm.zionrehabcenter.com
--   YOUR-CRON-SECRET   the CRON_SECRET from .env.local, which must also be set
--                      in Vercel's environment variables

create extension if not exists pg_net;

do $$
begin
  perform cron.unschedule('zion-nightly-digest');
exception when others then
  null;
end $$;

-- Five minutes after the alert run, so the digest reflects it.
select cron.schedule(
  'zion-nightly-digest',
  '5 13 * * *',
  $cron$
    select net.http_post(
      url     := 'YOUR-APP-URL/api/cron/notify',
      headers := jsonb_build_object(
                   'Authorization', 'Bearer YOUR-CRON-SECRET',
                   'Content-Type', 'application/json'
                 ),
      body    := '{}'::jsonb
    );
  $cron$
);

-- Check both jobs are scheduled:
--   select jobname, schedule, active from cron.job order by jobname;
--
-- And what the digest did on its last run:
--   select status, (response).status_code, (response).body
--     from net._http_response order by created desc limit 5;
--
-- The secret sits in the job definition, which only the postgres role can
-- read. Rotate it in both places — Vercel and here — if it is ever exposed.
