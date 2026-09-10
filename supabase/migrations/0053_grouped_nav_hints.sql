-- ─────────────────────────────────────────────────────────────
-- 0053 — the hints follow the screens into their groups
--
-- Nine screens moved when the sidebar became eight groups. A hint is matched
-- to a screen by path prefix, so a hint left pointing at /revenue is a hint
-- nobody will ever see again — and it fails silently, which is the worst way
-- for a nudge to stop working.
--
-- The keys do not change, so nobody who has already read one is asked to read
-- it again.
-- ─────────────────────────────────────────────────────────────
update public.tour_hints set screen = '/dashboard/needs'    where key = 'needs';
update public.tour_hints set screen = '/billing/forms'      where key = 'forms';
update public.tour_hints set screen = '/billing/revenue'    where key = 'revenue';
update public.tour_hints set screen = '/insights/reports'   where key = 'reports';
update public.tour_hints set screen = '/insights/outcomes'  where key = 'outcomes';
update public.tour_hints set screen = '/insights/capacity'  where key = 'capacity';
update public.tour_hints set screen = '/admin/exports'      where key = 'exports';
update public.tour_hints set screen = '/admin/contractors'  where key = 'contractors';
update public.tour_hints set screen = '/admin/staff'        where key = 'staff';

-- The dashboard hint mentioned the counters that are now a tab beside it.
update public.tour_hints
   set body = 'Your open tasks, anything overdue, and alerts the system raised overnight. "Needs attention" beside it counts the five things that might need somebody today. Connect Outlook here, and start a work session if you log hours. "+ Add" at the top right writes a note, task, job, interview, placement or work session from wherever you are.'
 where key = 'dashboard';

-- Paperwork is now only your own paperwork: the employer block that sat at the
-- bottom of it has moved to Admin → Settings, where a field about the company
-- makes sense on a screen about the company.
update public.tour_hints
   set body = 'Whichever form your engagement calls for — W-9, W-8BEN or W-4 — completed and signed in the app. Only the administrator can open the finished PDF.'
 where key = 'paperwork';

-- ─────────────────────────────────────────────────────────────
-- One new one, for the screen that did not exist
-- ─────────────────────────────────────────────────────────────
insert into public.tour_hints (key, screen, title, body, roles, sort_order) values
  ('settings', '/admin/settings', 'What the practice is',
   'The legal entity for tax filings, kept apart from the dba that goes to USOR and to clients — the two are different on purpose and are not to be reconciled. It also says where the settings that are not here live, and why they are where they are.',
   array['Admin'], 135)
on conflict (key) do update set
  screen = excluded.screen, title = excluded.title, body = excluded.body,
  roles = excluded.roles, sort_order = excluded.sort_order;
