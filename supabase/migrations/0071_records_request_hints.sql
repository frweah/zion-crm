-- ─────────────────────────────────────────────────────────────
-- 0071 — a hint for records requests
--
-- A new key. The thing worth saying up front is the thing that is not
-- obvious: gathering a record does not send it anywhere, and the reason it
-- does not is that a case note can name somebody who did not ask for
-- anything.
-- ─────────────────────────────────────────────────────────────
insert into public.tour_hints (key, screen, title, body, roles, sort_order) values
  ('records-request', '/admin/records-request', 'When somebody asks for their file',
   'Log the request when it arrives — who asked and when — so "we were asked and had not answered yet" is visible rather than remembered. Opening one gathers everything held about that person into a single document you can read and print: their record and restricted details, notes, forms, authorizations, invoices, hours, texts, appointments, the files held, and who has opened their file. Nothing is sent from here. Notes carry the roles they were written for, because a note meant for one role may name another client or a family member, and deciding what may go out is a judgement rather than a query. Gathering a record is itself recorded in the access log against your name.',
   array['Admin'], 140)
on conflict (key) do update set
  screen = excluded.screen, title = excluded.title, body = excluded.body,
  roles = excluded.roles, sort_order = excluded.sort_order;
