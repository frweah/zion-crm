-- Zion Vocational Rehab CRM — the week email says the three things it was
-- asked for
--
-- Item G, in the owner's own words: "FRIDAY 'YOUR WEEK' EMAIL per staff
-- member, 15:00 Mountain: To file items, clients with no confirmed activity in
-- 14 days, reports due or overdue."
--
-- 0316 built the email and counted the week's work - hours, notes, calls,
-- tasks - which is true and useful and is not the list. Those three are what
-- a person is supposed to act on when it arrives, so they are counted here
-- and the email leads with them.
--
-- ── "no confirmed activity" has one definition already ───────
--
-- client_last_activity_for (0207) is the practice's answer to "when did
-- anything last happen on this record": notes, tasks finished, forms,
-- contacts, placements, service hours, appointments, mail and texts. Every
-- one of those is something on the record, and - since the "To file" inbox
-- (0317) - something on the record is something somebody confirmed. So
-- "confirmed activity" is that function, rather than a second definition that
-- would drift from the one My day already uses.
--
-- ── and reports are owned, not caseloaded ────────────────────
--
-- A report's owner is who it is due from, which is not always who carries the
-- client now: a client reassigned mid-month leaves the week with the person
-- who did the work. The reports screens read them by owner and so does this.

begin;

-- A new column in the result is a new return type, which create-or-replace
-- will not do. Dropped and made again rather than given a second name: there
-- is one answer to "what was somebody's week" and two functions called nearly
-- the same thing is how a route ends up asking the older one.
drop function if exists public.staff_week(date);

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
  appointments     integer,
  to_file_waiting  integer,
  quiet_clients    integer,
  reports_due      integer,
  reports_overdue  integer
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
         coalesce((select sum(e.hours) from public.service_entries e
                    where e.staff_id = s.id and not e.non_billable
                      and e.date between (select week_start from span) and (select week_end from span)), 0),
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
         (select count(*) from public.tasks t
           where t.assigned_staff_id = s.id and t.status = 'Open' and t.removed_at is null)::integer,
         (select count(*) from public.tasks t
           where t.assigned_staff_id = s.id and t.status = 'Open' and t.removed_at is null
             and t.due is not null and t.due < (select today from me))::integer,
         (select count(*) from public.clients c
           where c.assigned_staff_id = s.id and c.status = 'Active' and c.merged_into is null)::integer,
         (select count(*) from public.calendar_events v
           where v.staff_id = s.id
             and v.starts_at >= ((select today from me) + 1)::timestamptz
             and v.starts_at < ((select today from me) + 8)::timestamptz)::integer,

         -- ── the three the brief names ──────────────────────
         (select count(*) from public.to_file f
           where f.staff_id = s.id and f.state = 'Waiting')::integer,
         -- Their active clients where nothing has happened on the record for
         -- a fortnight. A client with no activity at all is quiet too, which
         -- is why the null is counted rather than skipped.
         (select count(*)
            from public.clients c
            left join public.client_last_activity_for(
                   array(select x.id from public.clients x
                          where x.assigned_staff_id = s.id and x.status = 'Active'
                            and x.merged_into is null)) la on la.client_id = c.id
           where c.assigned_staff_id = s.id and c.status = 'Active' and c.merged_into is null
             and (la.last_activity_at is null
                  or la.last_activity_at < ((select today from me) - 13)::timestamptz))::integer,
         -- Reports they owe: the months to sign and send, and the weeks to
         -- confirm. Due counts everything not yet sent; overdue is the part
         -- whose date has passed, and it is a subset rather than a separate
         -- list, because "3 due, 1 overdue" is one sentence somebody can act
         -- on and "2 due and 1 overdue" reads as three things.
         ((select count(*) from public.client_reports r
            where r.owner_id = s.id and r.status <> 'Sent')
          + (select count(*) from public.client_weekly_reports w
              where w.owner_id = s.id and w.status = 'Draft'))::integer,
         ((select count(*) from public.client_reports r
            where r.owner_id = s.id and r.status <> 'Sent' and r.due_on < (select today from me))
          + (select count(*) from public.client_weekly_reports w
              where w.owner_id = s.id and w.status = 'Draft' and w.due_on < (select today from me)))::integer
    from public.staff s
   where s.active and not s.is_system and coalesce(btrim(s.email), '') <> ''
   order by s.name
$$;

comment on function public.staff_week is
  'One row per active member of staff: the three things the Friday email is '
  'for - what is waiting to be filed, which of their clients have gone quiet, '
  'and what reports they owe - and what they did this week. Counts only: no '
  'client is named.';

revoke all on function public.staff_week(date) from public, anon, authenticated;

commit;
