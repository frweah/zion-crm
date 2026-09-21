-- Zion Vocational Rehab CRM — the second consolidation: the person's day
--
-- The sidebar became six groups (owner, 21 Sept 2026): Dashboard, Clients,
-- Inbox, Billing, HR, Admin. The dashboard became the person's day, top to
-- bottom, with something to do on every line - including the alerts, which
-- until now could only be read.
--
-- An alert is the practice's, worked out nightly for a role, so one person
-- cannot resolve it for everybody - the condition is still true in the
-- morning and the alert comes straight back. What one person can do is put
-- it out of their own way until tomorrow. That is kept here, per person, and
-- nobody else's dashboard changes.
--
-- And the screen hints say where things are now.

create table if not exists public.staff_alert_snoozes (
  staff_id        uuid not null references public.staff(id) on delete cascade,
  notification_id uuid not null references public.notifications(id) on delete cascade,
  until           date not null,
  primary key (staff_id, notification_id)
);

comment on table public.staff_alert_snoozes is
  'An alert one person has put aside until a date (0119). Their own dashboard only.';

alter table public.staff_alert_snoozes enable row level security;

drop policy if exists staff_alert_snoozes_own on public.staff_alert_snoozes;
create policy staff_alert_snoozes_own on public.staff_alert_snoozes for all to authenticated
  using (staff_id = (select public.current_staff_id()) and (select public.is_active_staff()))
  with check (staff_id = (select public.current_staff_id()) and (select public.is_active_staff()));

revoke all on public.staff_alert_snoozes from anon;
grant select, insert, update, delete on public.staff_alert_snoozes to authenticated;

-- ── the hints, for the six groups ──────────────────────────
update public.tour_hints set
  title = 'Your day, top to bottom',
  body = 'Start and end your work session at the top, with today''s total. Then what is waiting for your reply - texts, chat and mail, oldest first - your tasks due today or overdue, today''s appointments, your clients with something due, and the alerts. Each line has its action beside it. "+ Add" at the top right writes a note, task, job, interview, placement or work session from wherever you are.'
 where key = 'dashboard';

update public.tour_hints set
  body = 'Every task, everybody''s: under Dashboard now, since your own are on the dashboard and a client''s are on their record. Interview prep and follow-up reminders appear on their own when a date is set on a job - closing one asks how it went and moves the job along.'
 where key = 'tasks';

update public.tour_hints set
  body = 'Whichever tax form your engagement calls for - W-9, W-8BEN or W-4 - completed and signed here, with your documents and your signature. Your certifications are the next tab along, under HR → Certifications.'
 where key = 'paperwork';

update public.tour_hints set
  body = 'Each counselor, their clients, and the log of calls, emails and reports sent - a tab of Clients now, with the directory, the contact log and hours requests chosen at the top. Recording a contact here is what the monthly reporting counts.'
 where key = 'counselors';

insert into public.tour_hints (key, screen, title, body, sort_order, active) values
  ('inbox-mail', '/mail', 'Everything that arrives, in one place',
   'Inbox is your Outlook mail, texts from clients, staff chat, the website chat and your calendar, one tab each. The number on Inbox in the sidebar is everything unread across them. A text is answered on the client''s record, where consent and the sending hours are checked.',
   0, true),
  ('inbox-messages', '/messages', 'Chat, texts and the website chat',
   'Chat is staff talking to staff. Texts and Website chat are clients and visitors: a website chat is answered here, and a text on the client''s record. Unread messages count towards the badge on Inbox.',
   0, true)
on conflict (key) do update set screen = excluded.screen, title = excluded.title, body = excluded.body, active = true;
