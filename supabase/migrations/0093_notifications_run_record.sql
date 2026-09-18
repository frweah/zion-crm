-- Zion Vocational Rehab CRM — when the alerts were last worked out
--
-- The dashboard recalculated every alert for everybody before it drew a
-- thing, on every visit - 30 to 190 ms of work plus a round trip, in front of
-- the page, to protect against alerts being up to a day old. The owner's rule
-- instead (18 Sept 2026): read the alerts as they are; if they were worked out
-- more than an hour ago, work them out again in the background, never on the
-- way to the page.
--
-- That needs the one fact nothing recorded: when they were last worked out.
-- generate_notifications() is the single way in - the nightly job and the
-- dashboard both call it - so it writes the time down.

create table if not exists public.job_runs (
  job          text primary key,
  last_run_at  timestamptz not null,
  last_ms      integer not null default 0
);

comment on table public.job_runs is
  'When each recurring job last ran, and how long it took. Written by the jobs themselves; read by the screens that decide whether to run one again.';

alter table public.job_runs enable row level security;

drop policy if exists job_runs_read on public.job_runs;
create policy job_runs_read on public.job_runs for select to authenticated
  using (public.is_active_staff());

revoke all on public.job_runs from anon;
revoke insert, update, delete, truncate on public.job_runs from authenticated;
grant select on public.job_runs to authenticated;
grant all on public.job_runs to service_role;

-- The same function as 0086 - staff and the nightly job only - that also
-- records the run.
create or replace function public.generate_notifications()
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_started timestamptz := clock_timestamp();
  v_open    integer;
begin
  if auth.uid() is not null
     and coalesce(auth.role(), '') <> 'service_role'
     and not public.is_active_staff() then
    raise exception 'Only staff recalculate alerts.' using errcode = 'insufficient_privilege';
  end if;

  v_open := public.generate_notifications_on(public.practice_today());

  insert into public.job_runs (job, last_run_at, last_ms)
  values ('notifications', now(), round(extract(epoch from clock_timestamp() - v_started) * 1000))
  on conflict (job) do update set last_run_at = excluded.last_run_at, last_ms = excluded.last_ms;

  return v_open;
end;
$function$;

revoke execute on function public.generate_notifications() from public, anon;
grant execute on function public.generate_notifications() to authenticated, service_role;

-- Start the record now, so the first dashboard after this knows how old the
-- alerts are.
select public.generate_notifications();
