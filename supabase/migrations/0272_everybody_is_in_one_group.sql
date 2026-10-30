-- Everybody is in one group
--
-- Staff chat has worked since 0104 and 0106, and on 30 October it had eight
-- messages in it across four direct conversations. Nobody had started a group,
-- which is a fair description of what happens when starting one is a decision
-- somebody has to make before they can say anything to the practice.
--
-- So one group exists without anybody starting it, holds every active member
-- of staff, and is not left or archived. The owner's rule (30 Oct 2026):
-- membership follows being on the staff - added on hire, removed on
-- offboarding, "the same minute as everything else".
--
-- `conversations.system_key` is how it is found again. A title would not do:
-- titles are typed by people and this one has to be the same row tomorrow,
-- after somebody has renamed it or started a group of their own called
-- Everyone.
--
-- Membership is maintained by a trigger on `staff` rather than by the screen
-- that hires somebody, for the reason the note trigger on lead_matches gives:
-- it then holds for the screen, for an import, and for a correction run months
-- from now.

alter table public.conversations
  add column if not exists system_key text;

comment on column public.conversations.system_key is
  'Names a conversation the practice keeps rather than one somebody started: "everyone" is the group every active staff member is in (0272). Null for every conversation a person starts.';

-- One row per key, and only where there is a key at all.
create unique index if not exists conversations_system_key_idx
  on public.conversations (system_key) where system_key is not null;

-- ─────────────────────────────────────────────────────────────
-- The group itself
--
-- `create if not absent` rather than `insert ... on conflict`, because the
-- unique index above is partial and a conflict target has to match it.
-- ─────────────────────────────────────────────────────────────
do $$
declare v_conv uuid;
begin
  select id into v_conv from public.conversations where system_key = 'everyone';
  if v_conv is null then
    insert into public.conversations (kind, title, system_key, created_by)
    values ('internal', 'Everyone', 'everyone', null)
    returning id into v_conv;
    raise notice 'ok  the Everyone group was made';
  else
    raise notice 'ok  the Everyone group was already there';
  end if;
end $$;

-- ─────────────────────────────────────────────────────────────
-- Who is in it
--
-- Exactly the people `is_active_staff` answers yes about, which is the
-- assertion the owner asked for and is why the question is asked of the staff
-- table rather than of a list kept alongside it.
--
-- A member who is deactivated has `left_at` set rather than their row deleted:
-- what they said stays where they said it, which is 0106's rule for leaving a
-- group and is the only version of this that leaves a readable conversation
-- behind. Coming back clears it, because somebody rehired is in the group
-- again and not in it twice.
-- ─────────────────────────────────────────────────────────────
create or replace function public.everyone_group_follows_the_staff()
returns trigger
language plpgsql security definer set search_path = public as $$
declare v_conv uuid;
begin
  select id into v_conv from public.conversations where system_key = 'everyone';
  if v_conv is null then
    return new;
  end if;

  if new.active then
    insert into public.conversation_participants (conversation_id, staff_id)
    values (v_conv, new.id)
    on conflict (conversation_id, staff_id) do update set left_at = null;
  else
    update public.conversation_participants
       set left_at = coalesce(left_at, now())
     where conversation_id = v_conv and staff_id = new.id;
  end if;

  return new;
end $$;

drop trigger if exists staff_join_everyone on public.staff;
create trigger staff_join_everyone
  after insert or update of active on public.staff
  for each row execute function public.everyone_group_follows_the_staff();

-- The people already on the staff when this ran. The trigger covers everybody
-- hired after it and nobody hired before it.
insert into public.conversation_participants (conversation_id, staff_id)
select c.id, s.id
  from public.conversations c
 cross join public.staff s
 where c.system_key = 'everyone' and s.active
on conflict (conversation_id, staff_id) do update set left_at = null;

update public.conversation_participants p
   set left_at = coalesce(p.left_at, now())
  from public.conversations c, public.staff s
 where c.system_key = 'everyone' and p.conversation_id = c.id
   and s.id = p.staff_id and not s.active;

-- ─────────────────────────────────────────────────────────────
-- It is not left, and it is not archived
--
-- Both are offered on every other conversation. Leaving the group everybody is
-- in is a thing somebody would do once and then not be told anything by the
-- practice again, and archiving it would do that to all of them at once.
-- ─────────────────────────────────────────────────────────────
create or replace function public.the_kept_group_stays()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.system_key is not null and new.archived_at is not null and old.archived_at is null then
    raise exception 'The Everyone group is not archived - it is where the practice talks to itself.'
      using errcode = 'check_violation';
  end if;
  return new;
end $$;

drop trigger if exists conversations_kept_group on public.conversations;
create trigger conversations_kept_group
  before update of archived_at on public.conversations
  for each row execute function public.the_kept_group_stays();

create or replace function public.the_kept_group_keeps_its_people()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  -- Only a person leaving of their own accord is refused. The staff trigger
  -- above sets left_at when somebody is deactivated, and that is the one way
  -- out of this group.
  if new.left_at is not null and old.left_at is null
     and exists (select 1 from public.conversations c
                  where c.id = new.conversation_id and c.system_key = 'everyone')
     and (select active from public.staff where id = new.staff_id) then
    raise exception 'Everybody on the staff is in the Everyone group. Turn off the pop-up for it instead.'
      using errcode = 'check_violation';
  end if;
  return new;
end $$;

drop trigger if exists participants_kept_group on public.conversation_participants;
create trigger participants_kept_group
  before update of left_at on public.conversation_participants
  for each row execute function public.the_kept_group_keeps_its_people();

-- ─────────────────────────────────────────────────────────────
-- And the membership is the staff list
-- ─────────────────────────────────────────────────────────────
do $$
declare v_in integer; v_active integer; v_wrong integer;
begin
  select count(*) into v_active from public.staff where active;
  select count(*) into v_in
    from public.conversation_participants p
    join public.conversations c on c.id = p.conversation_id
   where c.system_key = 'everyone' and p.left_at is null;
  select count(*) into v_wrong
    from public.conversation_participants p
    join public.conversations c on c.id = p.conversation_id
    join public.staff s on s.id = p.staff_id
   where c.system_key = 'everyone' and (p.left_at is null) <> s.active;

  if v_wrong > 0 or v_in <> v_active then
    raise exception
      'the Everyone group has % members and there are % active staff (% disagree)',
      v_in, v_active, v_wrong;
  end if;
  raise notice 'ok  the Everyone group holds all % active staff and nobody else', v_in;
end $$;
