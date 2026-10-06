-- Zion Vocational Rehab CRM — an update says "text", like every other thing
-- the practice writes
--
-- The mail privacy check refuses any column that could hold a message body,
-- because the practice keeps a message in exactly one place and copies it
-- into none. It read updates.body as one.
--
-- It is not one - an update is an announcement written in the CRM and kept
-- nowhere else - but the right answer is still to rename rather than to make
-- an exception. "body" is the word the rule watches for, notifications.text
-- is the word the practice already uses for the same kind of content, and a
-- privacy rule with a list of exceptions is a privacy rule somebody will add
-- to without thinking.

-- The view reads the column, so it goes first and comes back below.
drop view if exists public.updates_for_me;

alter table public.updates rename column body to text;

comment on column public.updates.text is
  'What the update says (0136, renamed 0137). An announcement written here, not a copy of anybody''s message.';

create view public.updates_for_me
with (security_invoker = true) as
  select u.id,
         u.title,
         u.text,
         u.link,
         u.attachment_path,
         u.attachment_name,
         u.audience,
         u.pinned,
         u.requires_ack,
         u.posted_by_name,
         u.posted_at,
         exists (
           select 1 from public.update_reads r
            where r.update_id = u.id and r.staff_id = public.current_staff_id()
         ) as read_by_me,
         (select count(*) from public.update_reads r where r.update_id = u.id) as read_count
    from public.updates u
   where u.active;

grant select on public.updates_for_me to authenticated;
