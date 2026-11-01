-- The practice says how it is
--
-- The owner asked for one email on a Monday morning with seven things in it:
-- the verify suite's result, the last backup fingerprint and its age, the
-- Graph subscriptions and when they expire, the stale filter's count, billing
-- older than ninety days, and the reports due, sent, overdue and oldest
-- unsent.
--
-- Five of the seven can be answered from the record at the moment the email
-- is written. **Two cannot**, and that is the whole reason this table exists:
--
--   The verification suite needs database credentials and so is run by hand
--   from a laptop, which CLAUDE.md says and which is right - it cannot run on
--   Vercel. Nothing recorded that it had been run. An email that said nothing
--   about it would have been an email with the most important line missing,
--   and one that said "passing" without knowing would be worse.
--
--   The backup fingerprint is the same: `scripts/backup-fingerprint.mjs` has
--   existed since the restore drill and nothing has ever recorded that it ran.
--
-- So the two things a person does by hand now leave a mark, and the Monday
-- email reports the mark and its age rather than the thing. "The suite passed
-- on Thursday" and "the suite passes" are different claims and only the first
-- is one this system can make.

create table if not exists public.practice_health (
  -- One row per thing, replaced each time it is done: this is the latest
  -- state, not a log. The history of a verify run is the terminal it ran in.
  kind        text primary key check (kind in ('verify', 'backup')),
  at          timestamptz not null default now(),
  ok          boolean not null,
  detail      text not null default '',
  recorded_by text not null default ''
);

comment on table public.practice_health is
  'The last time somebody ran the verification suite or the backup fingerprint, and what happened. Written from a laptop, read by the Monday email (0278).';

alter table public.practice_health enable row level security;

-- Admin reads it. It is about the practice rather than about a client, and
-- the people who act on a failing verify run are the people who can see the
-- whole of it anyway.
drop policy if exists practice_health_read on public.practice_health;
create policy practice_health_read on public.practice_health
  for select using ((select public.is_admin()));

-- Written by the scripts, which connect as postgres from a laptop, and by
-- nothing in the browser. No insert or update policy at all, and the grants
-- say the same thing twice on purpose.
revoke all on public.practice_health from authenticated;
revoke all on public.practice_health from anon;
grant select on public.practice_health to authenticated;

select public.apply_system_read_only('practice_health');

-- ─────────────────────────────────────────────────────────────
-- How it is, in one answer
--
-- One call rather than seven, because the route that writes the email should
-- not be the place the seven questions are phrased: a figure in an email and
-- the same figure on a screen have to agree, and they only agree if there is
-- one of each question.
--
-- Nothing here is client data. Counts, dates and a fingerprint - the email can
-- be read on a phone on a Monday morning without disclosing anybody.
-- ─────────────────────────────────────────────────────────────
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

    -- Graph: how many subscriptions, how many expire inside three days, the
    -- soonest, and how many last reported an error. Three days because the
    -- renewer runs every quarter hour and a subscription with three days left
    -- has had three hundred chances to renew: one that has not is stuck.
    (select count(*)::integer from public.microsoft_subscriptions),
    (select count(*)::integer from public.microsoft_subscriptions
      where expires_at < now() + interval '3 days'),
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

comment on function public.practice_health_summary is
  'The seven things the Monday email reports, in one answer so a figure in the email and the same figure on a screen cannot disagree (0278).';

-- Read by the Monday route with the service key, and by nobody signed in: it
-- aggregates billing across every office, which no role on a screen gets in
-- one number.
revoke all on function public.practice_health_summary() from anon, authenticated;

do $$
declare r record;
begin
  select * into r from public.practice_health_summary();
  raise notice 'ok  health summary answers: % subscriptions, % stale, % billing over 90 days, % reports waiting',
    r.graph_total, r.stale_count, r.billing_over_90, r.reports_due;
  if r.verify_at is null then
    raise notice 'ok  and says nothing has recorded a verify run yet, which is true';
  end if;
end $$;
