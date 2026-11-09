-- Zion Vocational Rehab CRM — an invoice number is Margaret's, or it is nothing
--
-- "Zion invoice numbers are real and come from Margaret's invoicing — 954423
-- and 955515 prove it. Replace the placeholder numbers on the open invoices
-- with the real ones from her records; the sequence continues from her
-- highest, not the ledger's."
--
-- Three days ago the ruling was to keep 955662–955666 and let the sequence
-- continue from them. Warrant F15677921 arrived this morning and settled what
-- those five numbers actually are. The stub names the invoices USOR paid:
--
--   V1037901  invoice 954423 claim C  $360.00
--   V1037898  invoice 955515 claim C  $2,250.00
--
-- Those are Margaret's numbers, from her invoicing, on the paper that went to
-- the state. The CRM's own 955662 and 955664 were never sent to anybody: they
-- were handed out by a database sequence on 6 November for five invoices that
-- had already gone out under numbers nobody had typed in. Two of the five now
-- have theirs. **The other three have no number this practice knows**, and the
-- honest way to say that is to say nothing:
--
--   955663  V1037893  $560.00    number not known
--   955665  V1028166  $450.00    number not known
--   955666  V1045641  $560.00    number not known
--
-- `number` becomes nullable and those three become null. A made-up number is
-- worse than a blank one in two different ways: USOR cannot find the claim it
-- names, and the next invoice the CRM raises continues from it — so an invented
-- 955666 pushes every real number afterwards six places past where Margaret's
-- own numbering had got to. That is the gap this keeps closing.
--
-- ── and where the next number comes from ─────────────────────
--
-- From the highest number anybody can point at, which is two tables rather
-- than one. The ledger holds the invoices this practice has recorded. The
-- warrant stubs hold every invoice number USOR has ever paid us against,
-- printed in the description — "954423-C" — and there are 598 of them. The
-- highest across both is the floor, and it is read rather than written down:
-- 0323 carried 955636 as a constant, and 955636 is exactly the highest number
-- on a warrant stub. A figure that can be derived should be derived, because a
-- constant goes stale the first time a warrant arrives and nobody notices.

begin;

alter table public.invoices alter column number drop not null;

comment on column public.invoices.number is
  'The Zion invoice number, as sent to USOR. Null means the invoice went out '
  'before the CRM numbered them and nobody has read the number off '
  'Margaret''s copy yet — not that it has no number.';

-- ── the two the warrant proves ───────────────────────────────

update public.invoices
   set number = 955515, claim = 'C',
       note = btrim(coalesce(note, '') || ' Invoice number read off warrant F15677921 (3 November 2026), '
              || 'which pays this claim: 955515-C. It was recorded as 955662, a number the CRM '
              || 'handed out on 6 November because Margaret''s had not been read yet.')
 where number = 955662 and amount = 2250.00;

update public.invoices
   set number = 954423, claim = 'C',
       note = btrim(coalesce(note, '') || ' Invoice number read off warrant F15677921 (3 November 2026), '
              || 'which pays this claim: 954423-C. It was recorded as 955664, a number the CRM '
              || 'handed out on 6 November because Margaret''s had not been read yet.')
 where number = 955664 and amount = 360.00;

-- ── and the three nobody has read yet ────────────────────────

update public.invoices
   set number = null,
       note = btrim(coalesce(note, '') || ' Sent by Margaret before the CRM numbered invoices. '
              || 'It was recorded as ' || number || ', a number the CRM handed out on 6 November '
              || 'rather than one that was ever on an invoice. The number on her copy goes here.')
 where number in (955663, 955665, 955666);

-- ── the next number ──────────────────────────────────────────

create or replace function public.invoice_number_from_the_ledger()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_floor bigint;
begin
  if new.number is not null then
    return new;
  end if;

  -- Two people raising an invoice in the same second must not be handed the
  -- same number. A sequence is the usual answer and was the wrong one here:
  -- it is deliberately not rolled back, and every verification script builds
  -- its fixtures inside a transaction that is thrown away, so forty runs of
  -- the suite spent a hundred and thirty-eight claim numbers (0323).
  perform pg_advisory_xact_lock(hashtext('public.invoices.number'));

  /*
   * The highest number anybody can point at.
   *
   * The ledger, and the warrant stubs. A stub prints the invoice number it
   * pays in the description - "954423-C Sample-V1037901-360.00" - so every
   * invoice USOR has ever paid us against is on one, whether or not this
   * practice ever recorded it. Reading both means a number Margaret used and
   * nobody entered still cannot be handed out a second time.
   *
   * A query inside a volatile function takes a fresh snapshot, so it sees the
   * rows its own statement has already written: two invoices raised by one
   * statement take two different numbers. Measured 6 November, and asserted
   * in verify_invoice_numbers so it will be noticed if it ever stops being
   * true.
   */
  select greatest(
           coalesce((select max(i.number) from public.invoices i), 0),
           coalesce((select max(l.client_code::bigint) from public.warrant_lines l
                      where l.client_code ~ '^[0-9]{6}$'), 0)
         ) + 1
    into v_floor;

  new.number := v_floor;
  return new;
end;
$$;

comment on function public.invoice_number_from_the_ledger is
  'The next Zion invoice number: one past the highest number in the ledger or '
  'on any warrant stub the practice has read. No sequence, so a rolled-back '
  'fixture spends nothing.';

revoke all on function public.invoice_number_from_the_ledger() from public, anon, authenticated;

commit;
