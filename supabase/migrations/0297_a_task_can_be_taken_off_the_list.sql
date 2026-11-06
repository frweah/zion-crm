-- A task can be taken off the list (owner, 5 Nov 2026)
--
-- Today carries two actions on every task now: mark it complete, or take it
-- off. Complete is what Done has always meant. Taking one off is new, and it
-- is not the same thing: a task somebody finished and a task that should
-- never have been raised are two different facts, and recording both as Done
-- loses the second one - along with who decided it and why.
--
-- ── a third status rather than a flag ────────────────────────
--
-- Every list in this system asks for `status = 'Open'`: nineteen functions,
-- five views and ten screens, and not one of them asks for "not Done". So a
-- third status drops out of all of them the moment it exists, and a
-- `removed_at` column beside the status would have left every one of those
-- lists showing removed tasks until somebody remembered to add a clause.
-- Checked rather than assumed - no function, view or screen says "<> 'Done'".
--
-- The stamps are written by a trigger and not by the screen, because "who
-- removed it" is the whole point of recording it and a value the browser
-- sends is a value the browser can choose. They survive an undo: status says
-- whether it is off the list now, and removed_by says who took it off last,
-- which is the question anybody would be asking.
--
-- A checklist step goes with its parent. The steps are tasks with a
-- parent_id, Today lists tasks without asking about parents, and a removed
-- parent with three open steps still on Today would be the fault this is
-- meant to fix wearing a different hat.

alter table public.tasks drop constraint if exists tasks_status_check;
alter table public.tasks add constraint tasks_status_check
  check (status = any (array['Open', 'Done', 'Removed']));

alter table public.tasks add column if not exists removed_at timestamptz;
alter table public.tasks add column if not exists removed_by uuid references public.staff(id);
alter table public.tasks add column if not exists removed_reason text;

comment on column public.tasks.removed_by is
  'Who took this task off the list (0297). Written by a trigger, never by a screen. Kept after an undo: the status says whether it is off the list now, this says who took it off last.';

-- One-directional on purpose: a task that is Removed has to say who and when,
-- and a task that is not may still carry the record of a removal undone.
alter table public.tasks drop constraint if exists tasks_removal_is_recorded;
alter table public.tasks add constraint tasks_removal_is_recorded
  check (status <> 'Removed' or (removed_at is not null and removed_by is not null));

create or replace function public.task_removal_stamp()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if new.status = 'Removed' and coalesce(old.status, '') <> 'Removed' then
    new.removed_at := now();
    new.removed_by := public.current_staff_id();
    -- A task is off the list or finished, not both.
    new.done_at := null;
  end if;
  return new;
end;
$$;

drop trigger if exists tasks_removal_stamp on public.tasks;
create trigger tasks_removal_stamp
  before update of status on public.tasks
  for each row execute function public.task_removal_stamp();

/**
 * And the steps go with it.
 *
 * After the row rather than before, because the parent has to be removed for
 * this to be true - and recursion is not a worry: a step has no steps of its
 * own, so the second pass changes nothing and stops.
 */
create or replace function public.task_removal_takes_its_steps()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if new.status = 'Removed' and coalesce(old.status, '') <> 'Removed' then
    update public.tasks
       set status = 'Removed',
           removed_at = new.removed_at,
           removed_by = new.removed_by,
           removed_reason = coalesce(new.removed_reason, 'Its task was taken off the list')
     where parent_id = new.id and status = 'Open';
  end if;
  return null;
end;
$$;

drop trigger if exists tasks_removal_takes_its_steps on public.tasks;
create trigger tasks_removal_takes_its_steps
  after update of status on public.tasks
  for each row execute function public.task_removal_takes_its_steps();

-- Neither is callable from a browser: they are triggers, and nothing else
-- should be asking for them.
revoke execute on function public.task_removal_stamp() from anon, authenticated;
revoke execute on function public.task_removal_takes_its_steps() from anon, authenticated;
