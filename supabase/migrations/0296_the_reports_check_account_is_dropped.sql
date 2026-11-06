-- The Reports check account is dropped (owner, 5 Nov 2026)
--
-- It bought nothing. Intake & Reports reaches twenty screens and Job Search
-- reaches all twenty, so the third account walked the same ground a second
-- time as a different role; the twelve HR and Admin screens nothing times
-- were out of its reach either way. The owner read that and dropped it. The
-- timing walk keeps the two accounts that do add screens - Job Search and
-- Billing (0129) - and keeps naming the twelve.
--
-- ── the row cannot be deleted, and that is on purpose ────────
--
-- `delete from staff` is refused, and the sentence it is refused with is the
-- point: "The staff change log is a record; it is added to, never changed or
-- removed."
--
-- Three guards, each doing its job. staff_record_changes.staff_id is
-- `on delete set null`, so deleting a colleague makes Postgres *update* the
-- change log - and staff_record_changes_append_only refuses every update to
-- it, whoever is asking. On top of that, the log's own trigger writes a
-- "Removed" row for the delete, naming a staff id that no longer exists.
--
-- So this practice deactivates people; it does not erase them. That is why
-- both other check accounts (0120, 0129) have only ever been switched off and
-- on. Deleting this one would mean opening a hole in the append-only guard
-- and teaching the log to write a null id - a new power over the staff record
-- for every row in the table, bought to tidy away one robot that never signed
-- in. Not worth it, and not asked for.
--
-- What it does instead is take the account out of service: the sign-in is
-- deleted, so the credential issued for it at 02:02 this morning no longer
-- exists, and the row is left switched off. What survives is four rows of
-- change log saying an account was added, renamed, given a sign-in, and
-- switched off again - which is the record working, not the record failing.
--
-- Switched off is enough, as it turns out. `link_staff_account` on
-- auth.users refuses a sign-in for a staff row that is closed - "The staff
-- account for … is closed" - which was found by trying to put the fault back
-- and being refused. So the address cannot be given a password again while
-- the row stays off, by this script or by anything else.
--
-- The constraint stays as 0295 left it, at the owner's instruction: a system
-- account may be Job Search, Billing or Intake & Reports, and never Admin.
-- Reports stays permitted and is now unused, which costs nothing - a rule
-- about what a check account may be is not a list of the ones that exist.

-- The change log reads this, so the rows it writes below say why.
select set_config('zion.staff_change_note', 'Dropped at the owner instruction: Intake & Reports timed no screen that Job Search did not.', false);

do $$
declare
  v_id   uuid;
  v_user uuid;
begin
  select id, user_id into v_id, v_user
    from public.staff
   where email = 'automated-check-reports@zionvocrehab.com' and is_system;

  if v_id is null then
    raise notice 'no Reports check account on file, so there is nothing to drop';
    return;
  end if;

  -- The sign-in first. staff.user_id is `on delete set null`, so this takes
  -- the account's link to it away in the same breath - and a password issued
  -- for an account that is out of service is the half of this worth being
  -- sure of.
  if v_user is not null then
    delete from auth.users where id = v_user;
    raise notice 'the sign-in is deleted';
  else
    raise notice 'it had no sign-in';
  end if;

  -- And switched off. invited_at and accepted_at go with the sign-in: an
  -- account recorded as invited and accepted with nothing to sign in to is a
  -- state no screen should have to make sense of.
  update public.staff
     set active = false,
         invited_at = null,
         accepted_at = null
   where id = v_id;

  raise notice 'the Reports check account is out of service';
end $$;

select set_config('zion.staff_change_note', '', false);

comment on column public.staff.is_system is
  'An account that is not a person (0120, 0129): a deploy check. Read-only against every table, and Job Search, Billing or Intake & Reports - never Admin, which is the role whose writes go through functions rather than tables. Reports is permitted and unused: the one that held it (0295) was dropped in 0296 because it timed no screen Job Search did not.';
