-- Zion Vocational Rehab CRM — tasks as checklists: steps, comments, and the
-- ones that come round again (Design language, §2, §3)
--
-- Three things a task could not do, each of which was being done somewhere
-- else and worse:
--
--   Steps. "Send the quarterly report" is six things, and they were either
--   six tasks with no relation to each other or one task somebody kept in
--   their head. A task can have steps now, which are tasks themselves - same
--   rules, same inline editing, same history - hanging off a parent.
--
--   A word about it. Why something slipped, what the counselor said, what to
--   try next: that went in the title, which is why some titles are two
--   sentences long.
--
--   Coming round again. The monthly report and the 90-day check were
--   remembered, or they were not. A task can repeat: finishing one opens the
--   next, dated from the one just finished, so a fortnight late does not make
--   every future one a fortnight late.
--
-- Repeating happens in the database rather than in a nightly job, because a
-- task is finished from four different screens and all four should behave the
-- same way.

alter table public.tasks
  add column if not exists parent_id uuid references public.tasks(id) on delete cascade,
  add column if not exists repeat_every text,
  add column if not exists repeat_until date;

comment on column public.tasks.parent_id is
  'The task this is a step of (0138). A step is a task: same rules, same editing, same history.';
comment on column public.tasks.repeat_every is
  'How often this comes round: week, month, quarter, 90 days (0138). Null is a task that happens once.';

alter table public.tasks drop constraint if exists tasks_repeat_known;
alter table public.tasks add constraint tasks_repeat_known
  check (repeat_every is null or repeat_every in ('week', 'month', 'quarter', '90 days', 'year'));

-- A step of a step is a nesting nobody asked for and a tree nobody can read.
create or replace function public.tasks_one_level_of_steps()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.parent_id is not null and exists (
    select 1 from public.tasks t where t.id = new.parent_id and t.parent_id is not null
  ) then
    raise exception 'A step cannot have steps of its own.' using errcode = 'check_violation';
  end if;
  if new.parent_id is not null and new.repeat_every is not null then
    raise exception 'A step does not repeat; the task it belongs to does.' using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
revoke execute on function public.tasks_one_level_of_steps() from public, anon, authenticated;

drop trigger if exists tasks_one_level on public.tasks;
create trigger tasks_one_level before insert or update on public.tasks
  for each row execute function public.tasks_one_level_of_steps();

create index if not exists tasks_parent_idx on public.tasks (parent_id) where parent_id is not null;

-- ── a task that comes round again ──────────────────────────
/**
 * Finishing a repeating task opens the next one.
 *
 * Dated from the one just finished rather than from today, so a report sent
 * a fortnight late does not push every future month a fortnight late. The new
 * one carries the steps as steps, unfinished, because a checklist that only
 * works the first time is a checklist nobody trusts.
 */
create or replace function public.tasks_open_the_next_one()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_next date;
  v_new uuid;
  r record;
begin
  if new.repeat_every is null or new.status = 'Open' or old.status <> 'Open' then
    return new;
  end if;

  v_next := case new.repeat_every
    when 'week' then coalesce(new.due, public.practice_today()) + 7
    when 'month' then (coalesce(new.due, public.practice_today()) + interval '1 month')::date
    when 'quarter' then (coalesce(new.due, public.practice_today()) + interval '3 months')::date
    when '90 days' then coalesce(new.due, public.practice_today()) + 90
    when 'year' then (coalesce(new.due, public.practice_today()) + interval '1 year')::date
  end;

  if new.repeat_until is not null and v_next > new.repeat_until then
    return new;
  end if;

  insert into public.tasks (client_id, assigned_staff_id, title, due, status, system_generated,
                            repeat_every, repeat_until, created_by)
  values (new.client_id, new.assigned_staff_id, new.title, v_next, 'Open', new.system_generated,
          new.repeat_every, new.repeat_until, new.created_by)
  returning id into v_new;

  for r in select title, assigned_staff_id from public.tasks where parent_id = new.id order by created_at loop
    insert into public.tasks (client_id, assigned_staff_id, title, due, status, parent_id, created_by)
    values (new.client_id, r.assigned_staff_id, r.title, v_next, 'Open', v_new, new.created_by);
  end loop;

  return new;
end;
$$;
revoke execute on function public.tasks_open_the_next_one() from public, anon, authenticated;

drop trigger if exists tasks_repeat on public.tasks;
create trigger tasks_repeat after update on public.tasks
  for each row execute function public.tasks_open_the_next_one();

-- ── a word about it ────────────────────────────────────────
create table if not exists public.task_comments (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null references public.tasks(id) on delete cascade,
  staff_id uuid references public.staff(id) on delete set null,
  staff_name text,
  said text not null,
  at timestamptz not null default now(),

  constraint task_comments_said check (btrim(said) <> '')
);

comment on table public.task_comments is
  'Why something slipped, what the counselor said, what to try next (0138). It was going in the title.';

create index if not exists task_comments_task_idx on public.task_comments (task_id, at);

alter table public.task_comments enable row level security;

-- Whoever can see the task can see what was said about it, and anybody who
-- can see it can add a word. A comment is not editable: a note somebody can
-- rewrite later is not a record of what was said.
drop policy if exists task_comments_select on public.task_comments;
create policy task_comments_select on public.task_comments for select to authenticated
  using (exists (select 1 from public.tasks t where t.id = task_id));

drop policy if exists task_comments_insert on public.task_comments;
create policy task_comments_insert on public.task_comments for insert to authenticated
  with check (
    staff_id = (select public.current_staff_id())
    and exists (select 1 from public.tasks t where t.id = task_id)
  );

select public.apply_system_read_only('public.task_comments'::regclass);

grant select, insert on public.task_comments to authenticated;
