-- Zion Vocational Rehab CRM — the mailboxes are still being watched (0241)
--
-- Microsoft's change notifications are what make a client's mail arrive in a
-- minute instead of fifteen, and a delegated subscription to them expires
-- inside about seventy hours whatever happens. Nothing renews them but the
-- fifteen-minute sweep, so if the sweep stops, every mailbox goes quiet about
-- three days later and nothing says so (owner, 24 Oct 2026).
--
-- **Read-only, and about the practice's live rows rather than a fixture.**
-- That is unusual here and it is the point: there is no arrangement of test
-- data that can tell you whether the real subscriptions are being renewed.
-- What is asserted is the thing an outage actually looks like.
--
-- The threshold is a day, and the sweep renews at two days
-- (app/api/cron/sync/route.ts). A healthy subscription therefore never sits
-- inside a day of expiry - it is renewed with a day of room to spare - so
-- being inside one means renewal has been failing for a full day, which is
-- ninety-six missed sweeps. That gap between "when it renews" and "when this
-- complains" is deliberate: a check that fires during normal operation is a
-- check people learn to ignore.
--
-- It says nothing when no mailbox is connected. A practice that has not set
-- Outlook up yet is not a practice with a broken subscription.

do $$
declare
  v_watched  integer;
  v_dying    text;
  v_errored  text;
  v_stale    text;
  failures   text[] := '{}';
begin
  select count(*) into v_watched from public.microsoft_subscriptions;
  if v_watched = 0 then
    raise notice '--  no mailbox is subscribed, so there is nothing to watch over';
    raise notice '--- MAIL SUBSCRIPTIONS VERIFIED ---';
    return;
  end if;

  -- ── inside a day, which the sweep should never allow ──────
  select string_agg(
           format('%s (expires %s, last renewed %s)',
                  s.name,
                  to_char(m.expires_at, 'FMMon FMDD HH24:MI'),
                  coalesce(to_char(m.renewed_at, 'FMMon FMDD HH24:MI'), 'never')),
           ', ' order by m.expires_at)
    into v_dying
    from public.microsoft_subscriptions m
    join public.staff s on s.id = m.staff_id
   where m.expires_at is null
      or m.expires_at < now() + interval '24 hours';

  if v_dying is not null then
    failures := failures || format(
      'FAILED: a subscription is inside a day of expiry and has not been renewed: %s. '
      'The fifteen-minute sweep renews at two days out, so this means it has not run for a day '
      '- check cron.job "zion-outlook-sync" and /api/cron/sync.', v_dying)::text;
  else
    raise notice 'ok  every subscription has more than a day left, so renewal is keeping up';
  end if;

  -- ── and none of them is carrying a complaint ──────────────
  select string_agg(format('%s: %s', s.name, left(m.last_error, 80)), '; ' order by s.name)
    into v_errored
    from public.microsoft_subscriptions m
    join public.staff s on s.id = m.staff_id
   where coalesce(m.last_error, '') <> '';

  if v_errored is not null then
    failures := failures || format('FAILED: a subscription recorded an error: %s', v_errored)::text;
  else
    raise notice 'ok  and none of them is carrying an error';
  end if;

  -- ── the sweep itself has been round recently ──────────────
  --
  -- Asked of the sweep rather than only of its results: a subscription
  -- renewed yesterday looks healthy for another two days, so the expiry
  -- alone would not notice a scheduler that stopped this morning.
  select string_agg(format('%s (%s)', s.name,
                           coalesce(to_char(m.last_run_at, 'FMMon FMDD HH24:MI'), 'never')),
                    ', ' order by s.name)
    into v_stale
    from public.microsoft_sync_state m
    join public.staff s on s.id = m.staff_id
    join public.microsoft_connections c on c.staff_id = m.staff_id
   where m.last_run_at is null or m.last_run_at < now() - interval '2 hours';

  if v_stale is not null then
    failures := failures || format(
      'FAILED: a connected mailbox has not been swept for two hours: %s. '
      'The sweep is scheduled every fifteen minutes.', v_stale)::text;
  else
    raise notice 'ok  and every connected mailbox was swept within the last two hours';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- MAIL SUBSCRIPTIONS VERIFIED ---';
end $$;
