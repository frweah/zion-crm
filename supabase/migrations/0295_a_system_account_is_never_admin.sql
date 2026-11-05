-- A system account is never Admin (owner, 5 Nov 2026)
--
-- 0294 let one be, so the timing walk could open the twelve screens only Admin
-- reaches, and recorded what that cost: the read-only promise is 310
-- restrictive policies over tables, and 56 functions gated on `is_admin()`
-- are not tables. The owner has read the cost and declined it. 0120's rule
-- stands.
--
-- Reports instead, and the honest note about what that buys: nothing, in
-- screens. Intake & Reports reaches twenty screens and every one of them is
-- already reached by Job Search, which the first check account is - so the
-- walk times the same twenty a second time, by a different role. That is not
-- worthless, because a screen can render for one role and break for another
-- and that is why smoke.mjs exists, but it is not coverage. The twelve HR and
-- Admin screens are timed by nobody, and the deploy says so by name on every
-- run rather than leaving it to be rediscovered.
--
-- Off, then the row, then on. Neither order works on its own: the constraint
-- as 0294 left it does not allow Reports, so the row cannot change while it is
-- there - and the constraint this adds does not allow Admin, so it cannot be
-- added while the row still is one.

alter table public.staff drop constraint if exists staff_system_is_job_search;

update public.staff
   set name = 'Automated check (reports)',
       email = 'automated-check-reports@zionvocrehab.com',
       role = 'Reports'
 where email = 'automated-check-admin@zionvocrehab.com'
   and is_system;

-- ── and never Admin again ────────────────────────────────────
--
-- Job Search (0120), Billing (0129), Intake & Reports (0295). Each is a role
-- that sees its own screens; none of them is the role that can change who
-- sees what.
--
-- Added last, which also makes it the assertion: if any system account still
-- held Admin, this would refuse to be created and the migration would fail
-- rather than leaving the rule written down and not in force.
alter table public.staff add constraint staff_system_is_job_search
  check (not is_system or role = any (array['Job Search', 'Billing', 'Reports']));

comment on column public.staff.is_system is
  'An account that is not a person (0120, 0129, 0295): a deploy check. Read-only against every table, and Job Search, Billing or Intake & Reports - never Admin, which is the role whose writes go through functions rather than tables.';
