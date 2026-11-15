-- Zion Vocational Rehab CRM — a warrant number in prose
--
-- 0360 closed the warrant columns and 0361 closed the functions. Neither
-- touches the place most of the warrant numbers actually are: free text.
--
-- 282 notes name a warrant in words - 124 on authorizations, 158 on invoices -
-- and both of those notes sit on screens the owner named by hand: "not on the
-- Billing page, the authorization record, the invoice, or the client Billing
-- tab". A column grant cannot close a sentence.
--
-- ── where they came from, and why this loses nothing ─────────
--
-- All 282 are machine-written provenance from the workbook import. Eight
-- templates, no client names, and every one of them says where the record came
-- from rather than anything about the work:
--
--   USOR authorization #<n> · warrant F15xxxxxx
--   From the warrant index: warrant F15xxxxxx, voucher 26Axxxxx. The invoice
--     document is not on file, so what was invoiced is taken to be what was
--     paid. ...
--   ... Invoice number read off warrant F15xxxxxx (3 November 2026), which
--     pays this claim: xxxxxx-C. ...
--
-- The warrant number itself is already held on `payments.warrant_no`,
-- `invoices.warrant` and `authorizations.warrant`, which is where Admin reads
-- it. So the number comes out of the prose and nothing is lost: the sentence
-- keeps saying where the record came from, the claim number stays (Billing may
-- see a claim), and the warrant goes to the one place that holds it.
--
-- ── the triggers ─────────────────────────────────────────────
--
-- `note` is a logged field, so 282 notes changing in one statement would write
-- 282 correction-log rows saying a note moved - and on `authorizations` the
-- log is exactly where a bulk edit should not appear, because the log is for
-- somebody changing a record. The user triggers come off for the statement and
-- go back on inside the same transaction.

begin;

alter table public.authorizations disable trigger user;
alter table public.invoices disable trigger user;

/*
 * " · warrant F15xxxxxx" at the end of the import note. What is left is
 * "USOR authorization #xxxxx", which is the whole of what the note was for.
 */
update public.authorizations
   set note = btrim(regexp_replace(note, '\s*·\s*warrant\s+[A-Z]?[0-9]{6,}', '', 'g'))
 where coalesce(note, '') ~ 'warrant\s+[A-Z]?[0-9]{6,}';

/*
 * Two shapes on the invoice note.
 *
 * The first names the index and then both numbers; the index is the provenance
 * and the numbers are not, so the sentence becomes "From the warrant index."
 *
 * The second reads the invoice number off a named warrant. There the warrant
 * is the source of a fact and the sentence needs it, so only the number goes:
 * "read off the warrant (3 November 2026), which pays this claim: xxxxxx-C".
 */
update public.invoices
   set note = btrim(regexp_replace(
                regexp_replace(
                  note,
                  'From the warrant index:\s*warrant\s+[A-Z]?[0-9]{6,},\s*voucher\s+[0-9A-Za-z-]+\.',
                  'From the warrant index.', 'g'),
                'read off warrant\s+[A-Z]?[0-9]{6,}',
                'read off the warrant', 'g'))
 where coalesce(note, '') ~ 'warrant\s+[A-Z]?[0-9]{6,}'
    or coalesce(note, '') ~ 'voucher\s+[0-9A-Za-z-]{4,}';

alter table public.authorizations enable trigger user;
alter table public.invoices enable trigger user;

/*
 * And the assertion, in the same transaction that made the change: a note
 * still carrying a number means a shape nobody wrote a rule for, and the right
 * answer to that is to stop rather than to leave it half done.
 */
do $$
declare n integer;
begin
  select count(*) into n
    from (select note from public.authorizations
           union all select note from public.invoices) t
   where coalesce(note, '') ~ 'warrant\s+[A-Z]?[0-9]{6,}'
      or coalesce(note, '') ~ 'voucher\s+[0-9A-Za-z-]{4,}';
  if n <> 0 then
    raise exception '% note(s) still name a warrant or a voucher number.', n;
  end if;
  raise notice 'no note names a warrant or a voucher number';
end $$;

commit;
