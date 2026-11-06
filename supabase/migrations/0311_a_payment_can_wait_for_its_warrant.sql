-- Zion Vocational Rehab CRM — a payment whose warrant is not on file
--
-- Phase 1 found one payment in the whole ledger that the warrant index does
-- not account for: $560 of Job Development, recorded by hand, with no warrant
-- number on it and no line in the index for that money. It was the entire
-- remaining difference between the CRM and the warrants.
--
-- The owner's ruling, 6 November 2026: it was paid, and the warrant is not
-- yet on file. Keep the payment, say so on Billing until it is matched, and
-- when the stub lands in _Warrants let the import match it and stop saying
-- it.
--
-- ── nothing is stored, deliberately ──────────────────────────
--
-- There is no flag column and nothing to clear. A payment whose warrant is
-- not on file is a payment with no warrant number, and that is a question the
-- rows can answer. A stored flag would need somebody - or some later
-- migration - to remember to clear it, and the one thing a ledger cannot
-- afford is a status that outlives the fact behind it. `check-checks` has the
-- same rule the other way round: ask the rule, not the roster.
--
-- The clearing path already exists and is older than this: reconcile_warrant_line
-- matches a payment with a blank warrant number and the right amount against
-- the arriving line, and writes the warrant number, the date and the voucher
-- onto it (0191, and the matching rules as they stand in 0292). So this
-- migration adds no behaviour to the import. It names the state, puts it on a
-- screen, and verify_warrants watches a payment go into it and come out.
--
-- ── and only where a warrant is the way money arrives ────────
--
-- Every authorization on file is Utah VR, and Utah VR pays by warrant. The
-- view says so rather than assuming it: a Private Pay client's payment has no
-- warrant coming and should never sit on a list waiting for one.

begin;

create or replace view public.payment_waiting_for_its_warrant as
  select p.id          as payment_id,
         p.auth_id,
         a.client_id,
         c.name        as client_name,
         coalesce(nullif(a.number, ''), a.service_type) as about,
         a.service_type,
         a.status      as authorization_status,
         p.amount,
         -- The day the money arrived, which is what a payment's date means
         -- here: there is no separate received date and the warrant date is
         -- it.
         p.warrant_date,
         p.voucher,
         p.source,
         p.recorded_by_name,
         p.invoice_id,
         p.created_at,
         public.practice_today() - p.warrant_date as days
    from public.payments p
    join public.authorizations a on a.id = p.auth_id
    join public.clients c on c.id = a.client_id
   where coalesce(p.warrant_no, '') = ''
     and coalesce(a.funding_source, 'Utah VR') = 'Utah VR'
     and public.is_active_staff();

comment on view public.payment_waiting_for_its_warrant is
  'Money recorded as received with no warrant number on it: the stub is not '
  'on file yet. Reconciliation matches these when the warrant arrives and '
  'writes the number onto the payment, which is what takes a row off this '
  'list.';

alter view public.payment_waiting_for_its_warrant set (security_invoker = on);
revoke all on public.payment_waiting_for_its_warrant from anon, authenticated;
grant select on public.payment_waiting_for_its_warrant to authenticated;

commit;
