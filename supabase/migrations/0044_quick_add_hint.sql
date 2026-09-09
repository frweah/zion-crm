-- ─────────────────────────────────────────────────────────────
-- 0044 — the dashboard hint learns about the "+"
--
-- Not a new hint key. The button is on every screen, so there is no screen it
-- belongs to, and reopening everybody's tour for a button they can already see
-- would be noise. The people who have not read the dashboard hint yet are the
-- ones who most need telling.
-- ─────────────────────────────────────────────────────────────
update public.tour_hints
   set body = 'Your open tasks, anything overdue, and alerts the system raised overnight, plus five counters for what needs somebody today. Connect Outlook here, and start a work session if you log hours. "+ Add" at the top right writes a note, task, job, interview, placement or work session from wherever you are.'
 where key = 'dashboard';
