-- Zion Vocational Rehab CRM — the intake runs every quarter hour
--
-- "Poll the mailbox on the existing Outlook sync cadence; if that is daily,
-- add a 15-minute job for service@ only." (Intake Automation Brief.) It is
-- daily - zion-outlook-sync runs at 12:50 - so this is the 15-minute job, and
-- it reads service@ and nothing else.
--
-- Fifteen minutes rather than daily because of what the referral starts: an
-- intake call due the next business day is no use if the referral is not seen
-- until the following lunchtime. The authorization matters less urgently but
-- arrives the same way.
--
-- The secret is not written here. The command is copied from a job that
-- already carries it (zion-messages-digest, also every fifteen minutes) with
-- only the path changed - so the shared secret stays out of the repository and
-- there is one place it lives. If that job is ever removed this raises rather
-- than quietly scheduling a call that would be refused.

do $$
declare
  v_command text;
begin
  select replace(command, '/api/cron/messages-digest', '/api/cron/intake')
    into v_command
    from cron.job
   where jobname = 'zion-messages-digest';

  if v_command is null then
    raise exception 'zion-messages-digest is not scheduled, so there is no command to copy the secret from.'
      using hint = 'Schedule the intake by hand, with the same headers as the other cron jobs.';
  end if;
  if position('/api/cron/intake' in v_command) = 0 then
    raise exception 'The job copied from does not call the path this expected; nothing was scheduled.';
  end if;

  perform cron.unschedule('zion-intake')
    where exists (select 1 from cron.job where jobname = 'zion-intake');

  perform cron.schedule('zion-intake', '*/15 * * * *', v_command);

  -- ── scheduled, and off ─────────────────────────────────────
  -- Created inactive, and that is not caution for its own sake. The first run
  -- reads the forty most recent messages in service@ and, by Rule 4, replies
  -- to every utah.gov one carrying a PDF - including the ones Margaret already
  -- dealt with by hand before any of this existed. The brief asks for that
  -- reply on mail as it arrives; it does not ask for a morning of thank-yous
  -- for a backlog, and a sent email cannot be taken back.
  --
  -- So the owner turns it on when the inbox is where they want it:
  --
  --   select cron.alter_job((select jobid from cron.job where jobname = 'zion-intake'),
  --                          active := true);
  --
  -- Everything else is live: a document dropped on Billing, or sent by the
  -- agent, is filed by the same rules already.
  -- Through alter_job, because cron.job itself is not ours to update.
  perform cron.alter_job(
    (select jobid from cron.job where jobname = 'zion-intake'), active := false);
  raise notice 'the intake is scheduled every fifteen minutes, and left inactive until the owner turns it on';
end $$;
