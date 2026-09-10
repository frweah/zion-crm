-- ─────────────────────────────────────────────────────────────
-- 0069 — a hint for the retention screen
--
-- A new key, so the tour reopens. Worth it: the first thing anybody should
-- know about a screen headed "Retention" is that it does not delete anything,
-- and the second is that every period on it is unchecked until somebody
-- checks it. Neither is guessable from looking.
-- ─────────────────────────────────────────────────────────────
insert into public.tour_hints (key, screen, title, body, roles, sort_order) values
  ('retention', '/admin/retention', 'How long records are kept',
   'Nothing on this screen destroys anything — there is no job, no timer and no trigger. It says how long each kind of record is kept, which closed records have passed that point, and what was decided about each one. Every period starts out unconfirmed and nothing is ever reported as due under a period nobody has checked, so the first job is to check each one against the rule beside it — USOR and your accountant, not this screen. A legal hold takes a record off the list entirely, and a destruction cannot be recorded against a held record or one still inside its period. What you write down here cannot be edited or deleted afterwards, including by you.',
   array['Admin'], 138)
on conflict (key) do update set
  screen = excluded.screen, title = excluded.title, body = excluded.body,
  roles = excluded.roles, sort_order = excluded.sort_order;
