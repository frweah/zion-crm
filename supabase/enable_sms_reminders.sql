-- Zion Vocational Rehab CRM — turn on the day-before appointment reminders
--
-- Companion to enable_email_digest.sql and enable_outlook_sync.sql, scheduled
-- the same way: pg_cron posts to the app, because sending needs the app's
-- GoHighLevel credentials and the database has none.
--
-- Timing. 23:00 UTC is 5pm in Utah during daylight saving and 4pm otherwise —
-- inside the 8am-to-9pm window the database enforces either way, and late
-- enough in the day that somebody who cannot make tomorrow can still ring the
-- office about it.
--
-- Before running, replace both placeholders:
--   YOUR-APP-URL       e.g. https://zion-crm-red.vercel.app
--   YOUR-CRON-SECRET   the CRON_SECRET from .env.local, which must also be set
--                      in Vercel's environment variables
--
-- The route sends nothing on its own authority: the database decides who may
-- be texted at all, and sms_due_reminders decides who is due. A run that finds
-- nobody consenting sends nothing and reports so, which is the correct
-- behaviour on the day this is turned on.

create extension if not exists pg_net;

do $$
begin
  perform cron.unschedule('zion-sms-reminders');
exception when others then
  null;
end $$;

select cron.schedule(
  'zion-sms-reminders',
  '0 23 * * *',
  $cron$
    select net.http_post(
      url     := 'YOUR-APP-URL/api/cron/sms',
      headers := jsonb_build_object(
                   'Authorization', 'Bearer YOUR-CRON-SECRET',
                   'Content-Type', 'application/json'
                 ),
      body    := '{}'::jsonb,
      timeout_milliseconds := 240000
    );
  $cron$
);

-- What the last run did, and what it could not do:
--   select status, (response).status_code, (response).body
--     from net._http_response order by created desc limit 5;
--
-- Who is due tomorrow, before it runs:
--   select client_name, local_day, local_time, kind from public.sms_due_reminders;
--
-- Who could be texted at all:
--   select count(*) filter (where can_text) as consenting,
--          count(*) as clients
--     from public.client_sms_consent;
