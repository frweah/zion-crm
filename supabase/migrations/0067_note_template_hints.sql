-- ─────────────────────────────────────────────────────────────
-- 0067 — the client record hint learns about the note headings
--
-- The same key, not a new one. A text box that now opens with headings in it
-- is not a new screen, and reopening the tour for everybody to announce it
-- would spend attention the next real change will need.
--
-- There is no hint keyed 'notes' — the Notes tab lives under the client
-- record, and 'client-record' is the hint that covers it. Worth writing down,
-- because the first attempt at this migration updated a key that does not
-- exist and reported success: an UPDATE matching no rows is not an error.
-- ─────────────────────────────────────────────────────────────
update public.tour_hints
   set body = 'Activity is everything that has happened, in one order. Jobs we have tried and the paperwork USOR still wants sit under stage history on Overview, and so does texting — a client is sent nothing until somebody records that they agreed to it, and replying STOP withdraws that by itself. Forms, files, notes, placements and the progress report each have their own tab. On Notes, choosing an activity type puts that type''s headings in the box: a starting point, never a form, and never written over anything you have already typed.'
 where key = 'client-record';
