-- Zion Vocational Rehab CRM — turn on the nightly Outlook sweep
--
-- Companion to enable_email_digest.sql, and scheduled the same way: pg_cron
-- posts to the app, because the sweep needs the app's Microsoft credentials
-- and the database has none.
--
-- Timing. The alerts run at 13:00 UTC and the digest at 13:05. This goes at
-- 12:50, ten minutes ahead of both, so anything it brings in — an appointment
-- tagged to a client, a counselor's reply — is already there when the day's
-- alerts are computed and the digest is written. Running it after would mean
-- the digest described yesterday.
--
-- Before running, replace both placeholders:
--   YOUR-APP-URL       e.g. https://zion-crm-red.vercel.app
--   YOUR-CRON-SECRET   the CRON_SECRET from .env.local, which must also be set
--                      in Vercel's environment variables
--
-- The sweep runs for every active staff member who has connected a mailbox.
-- One person's expired token is recorded against that person and does not stop
-- the others: somebody on leave should not mean nobody's mail is logged.

create extension if not exists pg_net;

do $$
begin
  perform cron.unschedule('zion-outlook-sync');
exception when others then
  null;
end $$;

select cron.schedule(
  'zion-outlook-sync',
  '50 12 * * *',
  $cron$
    select net.http_post(
      url     := 'YOUR-APP-URL/api/cron/sync',
      headers := jsonb_build_object(
                   'Authorization', 'Bearer YOUR-CRON-SECRET',
                   'Content-Type', 'application/json'
                 ),
      body    := '{}'::jsonb,
      timeout_milliseconds := 240000
    );
  $cron$
);

-- Check all three jobs are scheduled:
--   select jobname, schedule, active from cron.job order by schedule;
--
-- And what the sweep did on its last run — it reports per person, so a
-- connection that has quietly stopped working shows up here as well as on that
-- person's own dashboard:
--   select status, (response).status_code, (response).body
--     from net._http_response order by created desc limit 5;
--
-- The secret sits in the job definition, which only the postgres role can
-- read. Rotate it in both places — Vercel and here — if it is ever exposed.
