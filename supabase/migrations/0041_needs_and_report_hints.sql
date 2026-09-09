-- ─────────────────────────────────────────────────────────────
-- 0041 — two screens that arrived after the tour was written
--
-- The hints are data precisely so that adding a screen can ask people to
-- read about it. Adding the /needs key reopens "Guided tour completed" for
-- anyone who has not seen it, which is the intended behaviour and is what
-- verify_tour checks.
-- ─────────────────────────────────────────────────────────────
insert into public.tour_hints (key, screen, title, body, roles, sort_order) values
  ('needs', '/needs', 'The five things that might need you',
   'Tasks due, interviews this week, follow-ups due, clients nothing has happened to in a month, and paperwork that is holding up an invoice. The counters on the dashboard open these same lists — they are counted by the same query, so a number never disagrees with what it opens.',
   null, 15)
on conflict (key) do update set
  screen = excluded.screen, title = excluded.title, body = excluded.body,
  roles = excluded.roles, sort_order = excluded.sort_order;

-- The client record hint predates the progress report being sendable.
update public.tour_hints
   set body = 'Activity is everything that has happened, in one order. Jobs we have tried and the paperwork USOR still wants sit under stage history on Overview. Forms, files, notes, placements and the progress report each have their own tab — the report can be emailed to the counselor from there, and is logged as a contact when it is.'
 where key = 'client-record';
