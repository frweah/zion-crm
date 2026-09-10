-- ─────────────────────────────────────────────────────────────
-- 0057 — the tour learns about certifications
--
-- Two hints, and the one on Paperwork matters more: the person whose CPR card
-- is about to run out is the person who can do something about it, and they
-- will not go looking on a screen they think is only about tax forms.
-- ─────────────────────────────────────────────────────────────
update public.tour_hints
   set title = 'Your paperwork, and what you are certified to do',
       body = 'Whichever tax form your engagement calls for — W-9, W-8BEN or W-4 — completed and signed here. Below it, your certifications: ACRE, CPR and First Aid, background clearance, and your continuing-education hours for the year. Log training as you do it; the certificates themselves are recorded by the administrator once they have seen them.'
 where key = 'paperwork';

update public.tour_hints
   set body = 'Invite and deactivate — deactivating removes access the same moment. Pay rates are dated records, so work keeps the rate it was done under. Certifications and clearances sit here too, with a renewal recorded beside the old card rather than over it. Onboarding items the system can answer for itself are answered for itself.'
 where key = 'staff';
