-- ─────────────────────────────────────────────────────────────
-- 13.5 — somebody leaving
--
-- Half of this already existed and the half that existed was the easy half:
-- deactivating an account removes access the same moment, and there is an
-- offboarding checklist. What was missing is everything that has to happen
-- around it, and the fact that it all has to happen together.
--
-- Deactivating first and reassigning afterwards leaves a caseload belonging
-- to somebody who cannot be reached. Reassigning first and forgetting to
-- deactivate leaves an account open. Doing them in two clicks means the
-- second one gets done on a different day, or not at all — the current guard
-- refuses to deactivate anybody with active clients, which is correct and
-- also the reason it gets postponed.
--
-- So: one function, one transaction, and a record of what was done with what.
-- ─────────────────────────────────────────────────────────────

create table if not exists public.staff_offboarding (
  staff_id       uuid primary key references public.staff(id) on delete cascade,
  last_day       date not null,
  reason         text not null default '',
  -- Who picked up the caseload. Null is allowed: somebody may leave with
  -- nobody assigned to them, and pretending otherwise would mean inventing a
  -- successor to satisfy a column.
  successor_id   uuid references public.staff(id) on delete set null,
  clients_moved  integer not null default 0,
  tasks_moved    integer not null default 0,
  note           text not null default '',
  offboarded_by  uuid references public.staff(id) on delete set null,
  offboarded_at  timestamptz not null default now()
);

alter table public.staff_offboarding enable row level security;

drop policy if exists staff_offboarding_read on public.staff_offboarding;
drop policy if exists staff_offboarding_write on public.staff_offboarding;

-- Admin, or the person themselves — somebody should be able to see the date
-- recorded as their last day.
create policy staff_offboarding_read on public.staff_offboarding
  for select to authenticated
  using (public.is_admin() or staff_id = public.current_staff_id());

create policy staff_offboarding_write on public.staff_offboarding
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- ─────────────────────────────────────────────────────────────
-- What is still attached to somebody
--
-- Read before offboarding, so the conversation happens before the account is
-- closed rather than after. Nothing here blocks: an unsubmitted week of hours
-- is a thing to settle, not a reason to leave somebody's access open while it
-- is settled.
-- ─────────────────────────────────────────────────────────────
create or replace view public.offboarding_readiness as
select s.id                                                          as staff_id,
       s.name,
       s.role,
       s.active,

       (select count(*) from public.clients c
         where c.assigned_staff_id = s.id and c.status = 'Active')    as active_clients,

       (select count(*) from public.tasks t
         where t.assigned_staff_id = s.id and t.status = 'Open')      as open_tasks,

       -- Hours worked and not yet on a statement: the money they are owed.
       (select coalesce(sum(w.hours), 0) from public.work_sessions w
         where w.staff_id = s.id and not w.voided and w.statement_id is null)
                                                                     as unsubmitted_hours,

       (select count(*) from public.contractor_statements st
         where st.staff_id = s.id and st.status in ('Submitted', 'Returned'))
                                                                     as open_statements,

       (select count(*) from public.work_session_timers tm
         where tm.staff_id = s.id)                                   as running_timers,

       (select count(*) from public.staff_files f where f.staff_id = s.id)
                                                                     as documents_held,

       (select count(*) from public.microsoft_connections m where m.staff_id = s.id)
                                                                     as mailbox_connected

  from public.staff s;

alter view public.offboarding_readiness set (security_invoker = true);
grant select on public.offboarding_readiness to authenticated;

comment on view public.offboarding_readiness is
  'What is still attached to a member of staff: caseload, open tasks, unsubmitted hours, open statements, a running timer, documents held, a connected mailbox.';

-- ─────────────────────────────────────────────────────────────
-- Offboarding, as one act
--
-- Reassign, close the loose ends, record it, deactivate — in that order and
-- in one transaction, so there is no state where the caseload has moved and
-- the account is still open, or the reverse.
--
-- What it does not do is ban the auth user: that lives outside the database,
-- and the caller does it immediately afterwards. The deactivation here is
-- what row-level security reads, so access is gone the moment this commits
-- whether or not the ban lands.
-- ─────────────────────────────────────────────────────────────
create or replace function public.offboard_staff(
  p_staff_id  uuid,
  p_last_day  date,
  p_reason    text default '',
  p_successor uuid default null,
  p_note      text default ''
)
returns table (clients_moved integer, tasks_moved integer, timer_discarded boolean)
language plpgsql security definer set search_path = public as $$
declare
  v_me       uuid := public.current_staff_id();
  v_clients  integer := 0;
  v_tasks    integer := 0;
  v_timer    boolean := false;
begin
  if not public.is_admin() then
    raise exception 'Only the administrator offboards somebody.'
      using errcode = 'insufficient_privilege';
  end if;
  if p_staff_id = v_me then
    raise exception 'You cannot offboard yourself. Somebody else has to do it.'
      using errcode = 'check_violation';
  end if;
  if p_last_day is null then
    raise exception 'When was their last day?' using errcode = 'check_violation';
  end if;

  if p_successor is not null then
    if p_successor = p_staff_id then
      raise exception 'Somebody cannot take over from themselves.'
        using errcode = 'check_violation';
    end if;
    if not exists (select 1 from public.staff where id = p_successor and active) then
      raise exception 'The person taking over has to be an active member of staff.'
        using errcode = 'check_violation';
    end if;
  end if;

  -- ── the caseload ────────────────────────────────────────────
  -- Only active clients move. A closed client stays where they were, because
  -- the record of who worked with them is part of the record.
  if p_successor is not null then
    update public.clients
       set assigned_staff_id = p_successor
     where assigned_staff_id = p_staff_id and status = 'Active';
    get diagnostics v_clients = row_count;

    update public.tasks
       set assigned_staff_id = p_successor
     where assigned_staff_id = p_staff_id and status = 'Open';
    get diagnostics v_tasks = row_count;
  else
    -- Nobody named: the clients are unassigned rather than left pointing at
    -- somebody who has gone. The capacity screen counts unassigned clients,
    -- so they surface rather than disappearing.
    update public.clients
       set assigned_staff_id = null
     where assigned_staff_id = p_staff_id and status = 'Active';
    get diagnostics v_clients = row_count;
  end if;

  -- ── a timer left running ────────────────────────────────────
  -- Discarded, not saved. A timer somebody forgot to stop measures the time
  -- since they forgot, and turning that into hours on their final statement
  -- would be inventing work.
  delete from public.work_session_timers where staff_id = p_staff_id;
  get diagnostics v_timer = row_count;

  -- ── the record ──────────────────────────────────────────────
  insert into public.staff_offboarding
    (staff_id, last_day, reason, successor_id, clients_moved, tasks_moved, note, offboarded_by)
  values (p_staff_id, p_last_day, coalesce(p_reason, ''), p_successor,
          v_clients, v_tasks, coalesce(p_note, ''), v_me)
  on conflict (staff_id) do update set
    last_day = excluded.last_day,
    reason = excluded.reason,
    successor_id = excluded.successor_id,
    clients_moved = public.staff_offboarding.clients_moved + excluded.clients_moved,
    tasks_moved = public.staff_offboarding.tasks_moved + excluded.tasks_moved,
    note = excluded.note,
    offboarded_by = excluded.offboarded_by,
    offboarded_at = now();

  -- ── the account ─────────────────────────────────────────────
  update public.staff
     set active = false, deactivated_at = now()
   where id = p_staff_id;

  return query select v_clients, v_tasks, v_timer;
end;
$$;

revoke execute on function public.offboard_staff(uuid, date, text, uuid, text) from public;
grant execute on function public.offboard_staff(uuid, date, text, uuid, text) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- The checklist needed nothing
--
-- 'clients_reassigned', 'tasks_reassigned' and 'statements_settled' were
-- going to be added here as items that answer for themselves. They already
-- do — the offboarding checklist has computed all three since 0024, and
-- rewriting the view to add them would have dropped columns it has grown
-- since. Left alone on purpose, and said here so the next person does not
-- go looking for the same gap.
-- ─────────────────────────────────────────────────────────────
