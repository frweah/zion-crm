-- ─────────────────────────────────────────────────────────────
-- 0065 — a hint for the document inbox
--
-- A new key, so the tour reopens for anybody who has not read it. Worth it
-- here: this is the only screen in the CRM showing things that arrived by
-- themselves, and the first question anybody sensible asks about such a
-- screen is what it has already done on its own. The answer is nothing, and
-- it should not have to be discovered.
-- ─────────────────────────────────────────────────────────────
insert into public.tour_hints (key, screen, title, body, roles, sort_order) values
  ('document-inbox', '/admin/inbox', 'Documents that arrived by themselves',
   'A small program on the office PC watches the client folders and posts anything new here. It reads each PDF and says what it is — an authorization, a USOR form, a warrant — but it files nothing and changes nothing: every one of these is a proposal waiting for you. Nothing on the machine is ever moved, renamed or deleted; a file is remembered by its contents, so renaming one does not make it arrive again. Folders whose name is not a client sit at the top until somebody says whose they are, and once said, everything already waiting from that folder catches up.',
   array['Admin', 'Billing', 'Job Search', 'Reports'], 136)
on conflict (key) do update set
  screen = excluded.screen, title = excluded.title, body = excluded.body,
  roles = excluded.roles, sort_order = excluded.sort_order;
