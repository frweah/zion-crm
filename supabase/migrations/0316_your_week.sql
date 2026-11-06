-- Zion Vocational Rehab CRM — your week
--
-- Item G of the owner's list: a Friday email to each member of staff about
-- their own week, at three in the afternoon Mountain time, from service@.
--
-- The numbers are here and the words are in lib/week-report.ts, which is the
-- shape the Monday health run settled (0278): a figure that is counted in SQL
-- can be checked in a transaction that is rolled back, and a sentence that is
-- built in TypeScript can be run over made-up figures before every build.
-- Neither half can be checked where the other one lives.
--
-- ── what a week is ───────────────────────────────────────────
--
-- Monday to the day it is sent, rather than the last seven days. "Your week"
-- on a Friday afternoon means this week, and a rolling window would count
-- last Saturday's hours in a Friday email about this one.
--
-- ── and whose ───────────────────────────────────────────────
--
-- Every active member of staff who is a person. A check account is not sent
-- one, which is the rule 0120 set and the one the Monday run learnt the hard
-- way when an automated Admin turned up in the owner's To line.
--
-- Nothing here is a client's name. Counts, hours and dates only, so the email
-- can be read on a phone on the bus without disclosing anybody - the same
-- rule the Monday email follows and for the same reason.

begin;

create or replace function public.staff_week(p_today date default null)
returns table(
  staff_id         uuid,
  staff_name       text,
  email            text,
  role             text,
  week_start       date,
  week_end         date,
  billable_hours   numeric,
  clocked_hours    numeric,
  notes_written    integer,
  contacts_logged  integer,
  tasks_done       integer,
  tasks_open       integer,
  tasks_overdue    integer,
  clients_carried  integer,
  appointments     integer
)
language sql
stable
security definer
set search_path to 'public'
as $$
  with me as (
    select coalesce(p_today, public.practice_today()) as today
  ),
  span as (
    select date_trunc('week', (select today from me))::date as week_start,
           (select today from me) as week_end
  )
  select s.id,
         s.name,
         s.email,
         s.role,
         (select week_start from span),
         (select week_end from span),
         -- Billable hours they logged against an authorization.
         coalesce((select sum(e.hours) from public.service_entries e
                    where e.staff_id = s.id and not e.non_billable
                      and e.date between (select week_start from span) and (select week_end from span)), 0),
         -- And hours on the clock, which is a different question: what they
         -- did with the day, rather than what the practice bills for.
         coalesce((select sum(w.hours) from public.work_sessions w
                    where w.staff_id = s.id and not w.voided
                      and w.worked_on between (select week_start from span) and (select week_end from span)), 0),
         (select count(*) from public.notes n
           where n.staff_id = s.id
             and n.at between (select week_start from span) and (select week_end from span))::integer,
         (select count(*) from public.contact_log c
           where c.staff_id = s.id
             and c.date between (select week_start from span) and (select week_end from span))::integer,
         (select count(*) from public.tasks t
           where t.assigned_staff_id = s.id and t.status = 'Done'
             and t.done_at between (select week_start from span) and (select week_end from span))::integer,
         -- Open now, rather than open at some point this week: what is
         -- waiting is a fact about Monday morning.
         (select count(*) from public.tasks t
           where t.assigned_staff_id = s.id and t.status = 'Open' and t.removed_at is null)::integer,
         (select count(*) from public.tasks t
           where t.assigned_staff_id = s.id and t.status = 'Open' and t.removed_at is null
             and t.due is not null and t.due < (select today from me))::integer,
         (select count(*) from public.clients c
           where c.assigned_staff_id = s.id and c.status = 'Active' and c.merged_into is null)::integer,
         -- The week ahead, which is the other thing somebody wants on a
         -- Friday: what is already in the diary.
         (select count(*) from public.calendar_events v
           where v.staff_id = s.id
             and v.starts_at >= ((select today from me) + 1)::timestamptz
             and v.starts_at < ((select today from me) + 8)::timestamptz)::integer
    from public.staff s
   where s.active and not s.is_system and coalesce(btrim(s.email), '') <> ''
   order by s.name
$$;

comment on function public.staff_week is
  'One row per active member of staff: what they did this week, what is '
  'waiting on them now, and what is in next week''s diary. Counts only - no '
  'client is named.';

revoke all on function public.staff_week(date) from public, anon, authenticated;

commit;
