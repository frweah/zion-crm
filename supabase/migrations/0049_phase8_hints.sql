-- ─────────────────────────────────────────────────────────────
-- 0049 — the screens Phase 8 added, in the tour
--
-- Six new screens is exactly the situation item 0 was written for: the
-- improvements people ask for after a fortnight describe things the system
-- already does, because nobody told them. Adding these keys reopens "Guided
-- tour completed" for anybody who has not read them, which is the intended
-- behaviour and what verify_tour checks.
-- ─────────────────────────────────────────────────────────────
insert into public.tour_hints (key, screen, title, body, roles, sort_order) values
  ('revenue', '/revenue', 'What is authorized, earned and owed',
   'Money in four figures: authorized and not yet earned, earned and not yet invoiced, invoiced and not yet paid, and received. Hourly work earns by the hour; a flat fee earns on completion, so a flat fee with hours against it and no completion recorded has earned nothing. "Worth watching" is the part to read — quiet authorizations, ones about to expire, and anything a USOR form is blocking.',
   array['Admin', 'Billing'], 85),

  ('referrals', '/referrals', 'How far people get, and how long they wait',
   'The front of the pipeline: who is standing at Referral, Intake or Assessment, how many days they have been there, and how many have nothing authorized at all. Days waiting count from the last time somebody entered the stage they are in, so going out and coming back restarts the clock.',
   null, 25),

  ('outcomes', '/outcomes', 'One page to hand to somebody',
   'Clients served, placements, retention, wages and money received over a period you choose, with the practice name and vendor number at the top. It prints — use your browser to make a PDF. Anything not in the record shows a dash and says why underneath, rather than a zero somebody might quote.',
   array['Admin', 'Reports'], 105),

  ('capacity', '/capacity', 'Who should the next referral go to',
   'Caseload carried, work owed on it, and hours actually delivered — three separate questions, deliberately not added into one score. Where delivery is far below what is owed, the constraint is time rather than referrals, and another referral makes it worse.',
   array['Admin'], 106),

  ('exports', '/exports', 'The month as files',
   'Six CSVs for the accountant or the CPA: service hours, invoices and payments, authorizations, placements, referrals, and contractor hours. Each is read through your own account, so it holds what you can see and no more. Nothing restricted is exported at all — no dates of birth, no addresses, no tax numbers.',
   array['Admin', 'Billing'], 107),

  ('auth-import', '/billing/import', 'Read the authorization instead of typing it',
   'Upload the PDF USOR sent and the rules read the number, client, service, hours, rate and dates off it, each showing the line it came from. Nothing is created until you check it and press the button. A scanned or photographed authorization has no text to read and still has to be typed in.',
   array['Admin', 'Billing'], 86)
on conflict (key) do update set
  screen = excluded.screen, title = excluded.title, body = excluded.body,
  roles = excluded.roles, sort_order = excluded.sort_order;
