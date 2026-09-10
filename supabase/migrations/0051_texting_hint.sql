-- ─────────────────────────────────────────────────────────────
-- 0051 — the client-record hint learns about texting
--
-- Not a new screen, so not a new hint key: texting lives on the record people
-- already open. The one sentence worth carrying is the one that stops somebody
-- assuming the reminders are going out.
-- ─────────────────────────────────────────────────────────────
update public.tour_hints
   set body = 'Activity is everything that has happened, in one order. Jobs we have tried and the paperwork USOR still wants sit under stage history on Overview, and so does texting — a client is sent nothing until somebody records that they agreed to it, and replying STOP withdraws that by itself. Forms, files, notes, placements and the progress report each have their own tab.'
 where key = 'client-record';
