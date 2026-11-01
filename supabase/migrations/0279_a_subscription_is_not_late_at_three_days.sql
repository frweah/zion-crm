-- A subscription is not late at three days
--
-- 0278 called a Graph subscription "expiring" when it had less than three days
-- left, reasoning that the renewer runs every quarter hour and three days is
-- three hundred chances to renew.
--
-- That reasoning was wrong, and the first dry run of the Monday email said so:
-- all four subscriptions were reported as about to lapse, and the subject line
-- was about them.
--
-- **Microsoft's maximum lifetime for a mail subscription is 70 hours.** A
-- subscription renewed one minute ago has 70 hours left, which is less than
-- three days - so the threshold sat above the longest life a healthy
-- subscription can have, and would have raised the same alarm every Monday for
-- ever. Measured on 1 November 2026: four subscriptions, lifetime 70.0 hours
-- each, all renewed that morning, 55 hours left apiece, nothing wrong with any
-- of them.
--
-- Six hours instead. The renewer runs every fifteen minutes, so a subscription
-- with six hours left has had twenty-four passes at it and not been renewed:
-- that is stuck rather than ordinary, and six hours is still most of a working
-- day's warning before anything actually lapses.
--
-- The lesson is the one about defaults being the dull case, in a different
-- guise: a threshold has to be chosen against what the thing being measured
-- normally does, and I chose this one against how often the renewer runs.

create or replace function public.practice_health_summary()
returns table (
  verify_at          timestamptz,
  verify_ok          boolean,
  verify_detail      text,
  backup_at          timestamptz,
  backup_ok          boolean,
  backup_detail      text,
  graph_total        integer,
  graph_expiring     integer,
  graph_soonest      timestamptz,
  graph_failing      integer,
  stale_count        integer,
  billing_over_90    integer,
  billing_over_90_amount numeric,
  billing_oldest     date,
  reports_due        integer,
  reports_sent       integer,
  reports_overdue    integer,
  reports_oldest_unsent date
)
language sql stable security definer set search_path = public as $$
  select
    (select h.at from public.practice_health h where h.kind = 'verify'),
    (select h.ok from public.practice_health h where h.kind = 'verify'),
    (select coalesce(h.detail, '') from public.practice_health h where h.kind = 'verify'),
    (select h.at from public.practice_health h where h.kind = 'backup'),
    (select h.ok from public.practice_health h where h.kind = 'backup'),
    (select coalesce(h.detail, '') from public.practice_health h where h.kind = 'backup'),

    -- Graph: how many subscriptions, how many are stuck, the soonest to go,
    -- and how many last reported an error.
    --
    -- Six hours, not three days: the maximum lifetime Microsoft gives a mail
    -- subscription is 70 hours, so a three-day threshold is above the longest
    -- a healthy one can live and flags all of them, always. The renewer runs
    -- every quarter hour, so six hours left means twenty-four passes have gone
    -- by without it being renewed.
    (select count(*)::integer from public.microsoft_subscriptions),
    (select count(*)::integer from public.microsoft_subscriptions
      where expires_at < now() + interval '6 hours'),
    (select min(expires_at) from public.microsoft_subscriptions),
    (select count(*)::integer from public.microsoft_subscriptions
      where coalesce(last_error, '') <> ''),

    -- The Stale view's own count, from the same function the screen reads, so
    -- the email and the screen cannot disagree.
    (select count(*)::integer from public.billing_worklist() w where w.blocked),

    -- Submitted and not paid for more than ninety days: money the practice
    -- thinks it is owed and has heard nothing about.
    (select count(*)::integer from public.authorization_record a
      where a.submitted_on is not null and a.paid_on is null
        and a.submitted_on < public.practice_today() - 90),
    (select coalesce(sum(a.amount), 0) from public.authorization_record a
      where a.submitted_on is not null and a.paid_on is null
        and a.submitted_on < public.practice_today() - 90),
    (select min(a.submitted_on) from public.authorization_record a
      where a.submitted_on is not null and a.paid_on is null),

    -- Reports: waiting to go, gone, past their due date and not gone, and the
    -- period of the oldest that has not gone.
    (select count(*)::integer from public.client_reports r
      where r.status in ('Draft', 'Reviewed', 'Signed')),
    (select count(*)::integer from public.client_reports r where r.status = 'Sent'),
    (select count(*)::integer from public.client_reports r
      where r.status <> 'Sent' and r.due_on < public.practice_today()),
    (select min(r.period) from public.client_reports r where r.status <> 'Sent');
$$;

revoke all on function public.practice_health_summary() from anon, authenticated;

do $$
declare r record; v_life numeric;
begin
  select * into r from public.practice_health_summary();

  -- The longest a subscription on file was given, so this file's reasoning can
  -- be checked against the thing it is about rather than taken on trust.
  select max(extract(epoch from (expires_at - coalesce(renewed_at, created_at))) / 3600)
    into v_life from public.microsoft_subscriptions;

  if v_life is not null and v_life >= 72 then
    raise exception
      'a subscription was given % hours, which is more than the three days this file says is impossible',
      round(v_life, 1);
  end if;

  raise notice 'ok  % subscriptions, longest life % hours, % now counted as stuck',
    r.graph_total, coalesce(round(v_life, 1)::text, 'n/a'), r.graph_expiring;
end $$;
