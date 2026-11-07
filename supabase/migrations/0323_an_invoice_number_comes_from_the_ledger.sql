-- Zion Vocational Rehab CRM — an invoice number comes from the ledger
--
-- Owner, 6 November 2026: "keep the ledger numbers 955662-955666; the
-- sequence continues from them."
--
-- It did not. The sequence stood at 955804 and the next invoice the practice
-- sent would have been numbered 955805, which is a hundred and thirty-eight
-- numbers past the end of the ledger.
--
-- ── where the hundred and thirty-eight went ──────────────────
--
-- A sequence is deliberately not transactional: nextval is not rolled back,
-- so two sessions can never be handed the same number. That is the right
-- behaviour for a counter and the wrong one for this counter, because of what
-- else runs against this database.
--
-- Every verification script builds its fixtures against production inside
-- begin/rollback (see check-verify-scripts.mjs). verify_invoices.sql raises
-- three invoices each run. The rows go away; the numbers do not. Forty-odd
-- runs of the suite had quietly spent a hundred and thirty-eight of the
-- practice's invoice numbers on invoices that never existed.
--
-- The same thing had already happened once, before anybody was watching: the
-- warrant index ends at 955636 and the five invoices Phase 3 raised carry
-- 955662 to 955666, so twenty-five numbers went the same way in October. The
-- owner's ruling keeps those five numbers where they are. This migration
-- stops the gap growing a third time.
--
-- ── so the ledger decides, not a counter ─────────────────────
--
-- The next invoice number is one more than the highest in the ledger, worked
-- out when the row is written. A rolled-back fixture leaves no row and so
-- leaves no mark: there is nothing to restore afterwards and nothing to
-- remember. It also means the question "what will the next invoice be" has an
-- answer anybody can read off the table, which is not true of a sequence.
--
-- Two numbers are being traded away and both are worth saying out loud:
--
--   A number is reused if the newest invoice is deleted. Nothing deletes one:
--   the only policies on this table for a signed-in person are the
--   system_read_only trio, and every write goes through submit_invoice or
--   raise_invoice.
--
--   Two people submitting at the same instant would both read the same
--   maximum. Hence the advisory lock, which is held for the rest of the
--   transaction and released by the commit or the rollback either way: the
--   second submission waits for the first to finish and then reads a ledger
--   with the first invoice in it.
--
-- The floor is 955636, the last number in the warrant index, so an empty
-- ledger starts where 0306 said it starts rather than at 1.

begin;

alter table public.invoices alter column number drop default;

create or replace function public.invoice_number_from_the_ledger()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  -- A number given explicitly is kept: that is how the warrant index was
  -- backfilled, and how a fixture can name one it does not mind sharing.
  if new.number is not null then
    return new;
  end if;

  -- Serialised against anything else asking the same question, for the rest
  -- of this transaction. hashtext of the column's name rather than a magic
  -- integer, so a second lock on something else cannot collide with it by
  -- accident.
  perform pg_advisory_xact_lock(hashtext('public.invoices.number'));

  /**
   * One statement writing two invoices is fine, and that was worth checking.
   *
   * A BEFORE ROW trigger is documented as unable to see the rows its own
   * statement has already written, which would hand both rows of a two-row
   * insert the same number and have the unique index refuse the second -
   * and verify_invoices.sql raises two claims in one statement. It does not
   * happen: a query inside a volatile plpgsql function runs with a fresh
   * snapshot, so the second row's trigger sees the first row. Measured 6
   * November 2026, and asserted in verify_invoice_numbers.sql, which is
   * where it will be noticed if it ever stops being true.
   *
   * A transaction-local floor was carried here for a day as belt and
   * braces, and taken out again: no fault injection could make it matter,
   * and a mechanism nothing can falsify is a comment pretending to be code.
   */
  select greatest(coalesce(max(i.number), 0), 955636) + 1
    into new.number
    from public.invoices i;

  return new;
end;
$function$;

revoke all on function public.invoice_number_from_the_ledger() from public, anon, authenticated;

comment on function public.invoice_number_from_the_ledger() is
  'The next Zion invoice number: one past the highest in the ledger. A '
  'rolled-back fixture spends nothing, which a sequence cannot promise.';

drop trigger if exists invoices_number on public.invoices;
create trigger invoices_number
  before insert on public.invoices
  for each row execute function public.invoice_number_from_the_ledger();

-- Nothing reads it any more, and leaving it there is leaving the thing that
-- caused this where a later default can find it.
drop sequence if exists public.zion_invoice_number;

commit;
