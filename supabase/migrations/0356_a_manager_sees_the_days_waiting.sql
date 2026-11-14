-- Zion Vocational Rehab CRM — a manager sees the days waiting
--
-- The owner's rule: a day with no summary is flagged "on their My day and
-- their manager's". The first half worked the moment `work_days` existed.
-- The second half could not work at all, and the reason is worth writing
-- down.
--
-- `work_sessions_read` is **Admin, or the person whose hours they are**. A
-- manager who is not an Admin - Margaret, who has one person reporting to her
-- - cannot read her own people's sessions, so `work_days` answers her with
-- nothing and the flag she was promised is an empty table. The team roll-up
-- made it worse by reading `staff_days`: a day nobody accounted for has no
-- End of day row at all, so the days that need her attention were the exact
-- days that could not appear on her screen.
--
-- ── what this does and does not open ─────────────────────────
--
-- Not the table. Widening `work_sessions_read` to managers would hand them
-- every session, every correction and every description their people have
-- ever logged, to answer a question about which days are missing an account.
--
-- A function instead, returning **the days and nothing else**: whose, which
-- day, how many segments, what it came to. Which is already what the
-- twelve-hour notice tells a manager in a sentence, so it decides nothing
-- new about what a manager may know - it just makes it answerable.
--
-- Admin gets everybody's, because Admin already can.

begin;

create or replace function public.days_to_account_for()
returns table (
  staff_id uuid,
  staff_name text,
  day date,
  segments bigint,
  worked_hours numeric)
language sql
stable
security definer
set search_path to 'public'
as $$
  /*
   * The days the caller is owed an account of.
   *
   * Their own always. Their people's when somebody reports to them. Everyone's
   * for Admin. Nothing when nobody is signed in, which is the honest answer to
   * a question about "your people" asked by nobody.
   */
  select d.staff_id, d.staff_name, d.day, d.segments, d.worked_hours
    from public.work_days d
   where d.needs_an_account
     and public.current_staff_id() is not null
     and (
       d.staff_id = public.current_staff_id()
       or public.current_staff_role() = 'Admin'
       or exists (
         select 1 from public.staff s
          where s.id = d.staff_id
            and s.manager_id = public.current_staff_id()
            and s.active
       )
     )
   order by d.day desc, d.staff_name;
$$;

revoke all on function public.days_to_account_for() from public, anon, authenticated;
grant execute on function public.days_to_account_for() to authenticated;

commit;
