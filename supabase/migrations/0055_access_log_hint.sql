-- ─────────────────────────────────────────────────────────────
-- 0055 — a hint for the access log
--
-- New key, so it reopens the tour for anybody who has not read it. That is
-- the right behaviour here more than anywhere: a screen that answers "who
-- looked at this file" is no use to somebody who does not know it exists.
-- ─────────────────────────────────────────────────────────────
insert into public.tour_hints (key, screen, title, body, roles, sort_order) values
  ('access-log', '/admin/access', 'Who read what',
   'Every time somebody opened a client''s restricted details or intake, a contractor''s tax number, or a filed tax form — including the times they were refused. Written by the database as part of handing the data over, so there is no way to read a restricted field without an entry. Nothing here can be edited or deleted, including by you.',
   array['Admin'], 134)
on conflict (key) do update set
  screen = excluded.screen, title = excluded.title, body = excluded.body,
  roles = excluded.roles, sort_order = excluded.sort_order;
