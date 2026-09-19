-- Zion Vocational Rehab CRM — send the texts written for the next window
--
-- Run once, after part A is deployed. Copies the nightly digest's address and
-- cron secret onto /api/cron/scheduled-texts, every fifteen minutes, so a
-- message written at night goes out soon after 8am rather than that evening.

do $$
declare
  v_command text;
begin
  select command into v_command from cron.job where jobname = 'zion-nightly-digest';
  if v_command is null then
    raise exception 'The nightly digest is not scheduled, so there is no address and secret to copy.';
  end if;
  begin
    perform cron.unschedule('zion-scheduled-texts');
  exception when others then
    null;
  end;
  perform cron.schedule('zion-scheduled-texts', '*/15 * * * *', replace(v_command, '/api/cron/notify', '/api/cron/scheduled-texts'));
end $$;
