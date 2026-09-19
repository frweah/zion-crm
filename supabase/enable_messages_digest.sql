-- Zion Vocational Rehab CRM — turn on the unread-message email (Messaging brief, foundation)
--
-- Run once, after the foundation is deployed (the route has to exist first).
-- It copies the nightly digest's call - the same app address and cron secret
-- - onto /api/cron/messages-digest, every fifteen minutes. Nobody is emailed
-- who has not asked for it on the Messages screen.

do $$
declare
  v_command text;
begin
  select command into v_command from cron.job where jobname = 'zion-nightly-digest';
  if v_command is null then
    raise exception 'The nightly digest is not scheduled, so there is no address and secret to copy. Run enable_email_digest.sql first.';
  end if;
  begin
    perform cron.unschedule('zion-messages-digest');
  exception when others then
    null;
  end;
  perform cron.schedule('zion-messages-digest', '*/15 * * * *', replace(v_command, '/api/cron/notify', '/api/cron/messages-digest'));
end $$;
