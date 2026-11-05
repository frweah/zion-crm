-- A system account is not a colleague (owner, 5 Nov 2026)
--
-- The deploy checks sign in as accounts that are not people: "Automated
-- check" opens what Job Search reaches, "Automated check (billing)" opens
-- Billing's screens, and this adds a third for Admin's, so the timing walk
-- covers the screens the first two cannot see.
--
-- `is_system` already keeps them out of everything that is about people. They
-- are left off the roster in Admin -> People, off the Directory, and out of
-- `staff_credential_status`, which is what 0288 was for: a robot has no I-9.
--
-- One place had been missed. `everyone_group_follows_the_staff` adds every
-- active staff row to the Everyone conversation and asks nothing about
-- `is_system`, so both existing check accounts have been sitting in the staff
-- group since 0272 - every message anybody sent a colleague was delivered to
-- two accounts that cannot read. Nothing broke, which is why it lasted: a
-- participant who never opens anything looks exactly like one who is quiet.
--
-- So: the group follows the *people* on the staff, the two that are already in
-- it are marked as having left, and the third account is made correctly by
-- construction rather than by somebody remembering.
--
-- The name is not "ZZ Smoke Admin", which is what was asked for, and the
-- reason is worth a sentence: ZZ and ZQ mean fixture data that has no business
-- in production, and verify_zz_no_fixtures permits exactly one such name and
-- fails on any other. A permanent system account is not fixture data, and
-- excepting a second name would turn "a list of one is still a rule" into a
-- list. It is named after the two it joins instead.

-- ── the group follows the people ─────────────────────────────
create or replace function public.everyone_group_follows_the_staff()
returns trigger
language plpgsql security definer set search_path = public as $$
declare v_conv uuid;
begin
  select id into v_conv from public.conversations where system_key = 'everyone';
  if v_conv is null then
    return new;
  end if;

  -- A system account is not a colleague. Marked as having left rather than
  -- skipped, because a row that becomes `is_system` after it was added has to
  -- come out of the group and not merely stop being added to it.
  if new.is_system then
    update public.conversation_participants
       set left_at = coalesce(left_at, now())
     where conversation_id = v_conv and staff_id = new.id;
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

-- The trigger fired on insert and on `active` changing, which was the whole
-- of what could move somebody in or out. `is_system` can now too, so it has
-- to be one of the columns watched - otherwise a row that becomes a system
-- account keeps its seat, which is precisely how the two check accounts kept
-- theirs.
drop trigger if exists staff_join_everyone on public.staff;
create trigger staff_join_everyone
  after insert or update of active, is_system on public.staff
  for each row execute function public.everyone_group_follows_the_staff();

-- ── and the guard says colleague, which is what it meant ─────
--
-- `the_kept_group_keeps_its_people` refuses an active member leaving the
-- Everyone group, which is right and is why the two check accounts could not
-- simply be taken out: "everybody on the staff is in the Everyone group" was
-- written when everybody on the staff was a person. It asks the same question
-- the group trigger now asks.
create or replace function public.the_kept_group_keeps_its_people()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  -- Only a colleague leaving of their own accord is refused. The staff
  -- trigger sets left_at when somebody is deactivated, and when an account is
  -- a system one, and those are the two ways out of this group.
  if new.left_at is not null and old.left_at is null
     and exists (select 1 from public.conversations c
                  where c.id = new.conversation_id and c.system_key = 'everyone')
     and exists (select 1 from public.staff s
                  where s.id = new.staff_id and s.active and not s.is_system) then
    raise exception 'Everybody on the staff is in the Everyone group. Turn off the pop-up for it instead.'
      using errcode = 'check_violation';
  end if;
  return new;
end $$;

-- ── and the two that are already in it come out ──────────────
update public.conversation_participants p
   set left_at = coalesce(p.left_at, now())
 where p.conversation_id = (select id from public.conversations where system_key = 'everyone')
   and exists (select 1 from public.staff s where s.id = p.staff_id and s.is_system);

-- ── a system account may be Admin, and what that costs ──────
--
-- 0120 said a system account "is Job Search, the least a signed-in account
-- can be, and it can be nothing else: not Admin", and the constraint has said
-- so since. 0129 widened it to Billing for the same reason this widens it to
-- Admin: a role sees its own screens and nothing else, so the screens Admin
-- reaches were being timed and opened by nobody.
--
-- What that costs, stated rather than discovered later. 0120's promise was
-- that "if its password ever leaked, what leaked is the ability to look, not
-- to change anything", and that promise rests on 310 restrictive policies
-- refusing an insert, update or delete made as a system account. Those cover
-- writes to a table. They do not cover a security definer function, which
-- writes as its owner - and 56 functions are gated on `is_admin()`, so an
-- Admin system account can call them.
--
-- There is no version of this that both reads as Admin and cannot act as
-- Admin without a guard in each of those functions: making `is_admin()`
-- refuse a system account would close the writes and the reads together, and
-- the reads are the whole point.
--
-- What makes it tolerable is where the secret lives. It is a GitHub Actions
-- secret, and anybody who can read it can already push to the repository that
-- deploys this app - which is strictly more than Admin. The account is
-- outside no rule it was outside before: its reads are logged like anybody's,
-- it is off every list of colleagues, and nothing exempts it.
--
-- What is still true is asserted rather than assumed:
-- verify_a_system_account_is_not_a_colleague puts an Admin system account in
-- front of a table and watches the write refused.
alter table public.staff drop constraint if exists staff_system_is_job_search;
alter table public.staff add constraint staff_system_is_job_search
  check (not is_system or role = any (array['Job Search', 'Billing', 'Admin']));

comment on column public.staff.is_system is
  'An account that is not a person (0120, 0129, 0294): a deploy check. Read-only against every table, Job Search, Billing or Admin so that each role''s own screens can be opened, and never given an area beyond its role.';

-- ── the third check account ──────────────────────────────────
--
-- The staff row only. The sign-in and its password are the owner's to issue:
-- scripts/create-check-account.mjs --admin makes the login and prints the
-- password once, and nothing here or anywhere else keeps it.
insert into public.staff (name, email, role, active, is_system)
values ('Automated check (admin)', 'automated-check-admin@zionvocrehab.com', 'Admin', true, true)
on conflict (email) do update
   set name = excluded.name,
       role = excluded.role,
       active = excluded.active,
       is_system = excluded.is_system;
