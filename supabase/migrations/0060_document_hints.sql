-- ─────────────────────────────────────────────────────────────
-- 0060 — the paperwork hint learns about documents
--
-- No new key: documents sit on screens people already have hints for, and
-- reopening everybody's tour for a section on a screen they know is noise.
-- ─────────────────────────────────────────────────────────────
update public.tour_hints
   set body = 'Whichever tax form your engagement calls for — W-9, W-8BEN or W-4 — completed and signed here. Below it, your documents and your certifications: ACRE, CPR and First Aid, background clearance, and your continuing-education hours for the year. Add a copy of a card yourself; log training as you do it. The certificates themselves are recorded by the administrator once they have seen them, and only they can remove a document.'
 where key = 'paperwork';

update public.tour_hints
   set body = 'Invite and deactivate — deactivating removes access the same moment. Pay rates are dated records, so work keeps the rate it was done under. Certifications, clearances and everybody''s documents sit here too; a renewal is recorded beside the old card rather than over it, and opening somebody''s document is written to the access log.'
 where key = 'staff';
