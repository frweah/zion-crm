-- ─────────────────────────────────────────────────────────────
-- 0063 — the hours hint learns about expenses
-- ─────────────────────────────────────────────────────────────
update public.tour_hints
   set body = 'Log what you worked, or run the timer. Claim mileage and out-of-pocket expenses here too — mileage is entered as miles and priced at the rate that applied on the day, so nobody does the arithmetic. Hours are append-only: a mistake is corrected by a replacement that records the reason, never by an edit. Submit the statement when the period ends and the hours and the expenses go together, as one payment.'
 where key = 'hours';
