-- Zion Vocational Rehab CRM — the chase runs daily
--
-- Rules 6 and 7 are about days passing, so once a day is right: a referral
-- reaches its seventh day at midnight and the nudge goes out that morning.
-- Early, before the working day, so what it raises is already on Margaret's
-- My day when she opens it.
--
-- The command is copied from a job that already carries the shared secret, so
-- the secret stays out of the repository - the same way 0183 schedules the
-- intake.
--
-- Left active, unlike the intake poll. The difference is what the first run
-- would do: the intake poll would have replied to a mailbox full of mail
-- already handled by hand, while this one sends on the seventh and fourteenth
-- day only - and every client at Referral today is well past both, so it sends
-- nothing. Checked rather than assumed: 22 clients are waiting and 0 of them
-- would be emailed. From tomorrow it chases new referrals as they age, which
-- is what Rule 6 asks for.

do $$
declare
  v_command text;
  v_waiting bigint;
  v_sending bigint;
begin
  select replace(command, '/api/cron/messages-digest', '/api/cron/chase')
    into v_command
    from cron.job
   where jobname = 'zion-messages-digest';

  if v_command is null then
    raise exception 'zion-messages-digest is not scheduled, so there is no command to copy the secret from.'
      using hint = 'Schedule the chase by hand, with the same headers as the other cron jobs.';
  end if;
  if position('/api/cron/chase' in v_command) = 0 then
    raise exception 'The job copied from does not call the path this expected; nothing was scheduled.';
  end if;

  -- What it would send today, said out loud at the moment it is turned on.
  select count(*), count(*) filter (where send)
    into v_waiting, v_sending
    from public.referrals_without_authorization();
  raise notice 'today: % client(s) waiting on an authorization, % would be emailed', v_waiting, v_sending;

  perform cron.unschedule('zion-chase')
    where exists (select 1 from cron.job where jobname = 'zion-chase');

  perform cron.schedule('zion-chase', '20 13 * * *', v_command);
  raise notice 'the chase runs daily';
end $$;
