-- ─────────────────────────────────────────────────────────────
-- 0037 — a stopwatch, not a shift clock.
--
-- Rei and Margaret are contractors. Nothing here starts on login, nothing
-- knows about schedules or breaks, and nothing stops anybody logging hours by
-- hand. It exists because typing "how long was I on that?" at the end of the
-- afternoon is guesswork, and a running clock is not.
--
-- The timer never becomes a work session by itself. It offers an elapsed
-- figure, the person changes it if it is wrong, writes what they did, and
-- saves — at which point the ordinary append-only work_sessions row is
-- written, the same one the manual form writes. A timer that logged its own
-- time would be a clock somebody has to remember to stop.
-- ─────────────────────────────────────────────────────────────

create table if not exists public.work_session_timers (
  -- One at a time. Two running timers is a question about which is real, and
  -- the primary key means it can never be asked.
  staff_id   uuid primary key references public.staff(id) on delete cascade,
  started_at timestamptz not null default now(),
  note       text not null default '',
  client_id  uuid references public.clients(id) on delete set null,
  created_at timestamptz not null default now()
);

alter table public.work_session_timers enable row level security;

-- Yours alone, in both directions. A running timer is not information anybody
-- else needs, including Admin: it says where somebody is in their afternoon.
drop policy if exists work_session_timers_own on public.work_session_timers;
create policy work_session_timers_own on public.work_session_timers
  for all to authenticated
  using (staff_id = public.current_staff_id())
  with check (staff_id = public.current_staff_id());

/**
 * What the timer has run for, in hours, to the nearest hundredth.
 *
 * Capped at 24 because work_sessions refuses more, and a timer showing 31.4
 * hours is a timer somebody forgot on Friday rather than a day's work. The
 * screen says so instead of quietly writing 24.
 */
create or replace function public.timer_elapsed_hours(p_started timestamptz)
returns numeric language sql stable as $$
  select least(round(extract(epoch from (now() - p_started)) / 3600.0, 2), 24.00);
$$;

grant execute on function public.timer_elapsed_hours(timestamptz) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- Today, and this period
-- ─────────────────────────────────────────────────────────────
create or replace view public.my_hours_summary as
select w.staff_id,
       coalesce(sum(w.hours) filter (where w.worked_on = public.practice_today()), 0) as today_hours,
       coalesce(sum(w.hours) filter (
         where w.worked_on between public.period_start(public.practice_today())
                               and public.period_end(public.practice_today())), 0)   as period_hours,
       public.period_start(public.practice_today()) as period_start,
       public.period_end(public.practice_today())   as period_end
  from public.work_sessions w
 where not w.voided
 group by w.staff_id;

alter view public.my_hours_summary set (security_invoker = true);
grant select on public.my_hours_summary to authenticated;

comment on view public.my_hours_summary is
  'Today and this period, for whoever is asking. security_invoker, so it is their own hours.';
