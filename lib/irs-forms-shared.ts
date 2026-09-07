/**
 * The parts of the IRS form definitions the browser needs.
 *
 * lib/irs-forms.ts is server-only — it reads the PDFs off disk — so a client
 * component cannot import from it at all. The list of classifications is the
 * one thing both sides need to agree on: the form offers them, the action
 * validates against them, and the filler maps them to boxes by position. One
 * list, so they cannot drift apart.
 */

/** The seven boxes on line 3a of Form W-9, in the order they are printed. */
export const W9_CLASSIFICATIONS = [
  "Individual/sole proprietor",
  "C corporation",
  "S corporation",
  "Partnership",
  "Trust/estate",
  "LLC",
  "Other",
] as const;

export type W9Classification = (typeof W9_CLASSIFICATIONS)[number];

/** The three boxes in Step 1(c) of Form W-4, in the order they are printed. */
export const W4_FILING_STATUSES = [
  "Single or Married filing separately",
  "Married filing jointly or Qualifying surviving spouse",
  "Head of household",
] as const;

export type W4FilingStatus = (typeof W4_FILING_STATUSES)[number];

/**
 * What Step 3 multiplies by, taken from the face of the 2026 Form W-4.
 *
 * These are set by statute and the IRS reprints them on the form each year —
 * the child figure was $2,000 before 2026. If the PDF in assets/irs-forms is
 * ever replaced, read the new form and change these to match, because nothing
 * in the file itself will tell you they moved. The screen shows the
 * multiplication it is doing so a wrong figure here is visible before anyone
 * signs.
 */
export const W4_CREDITS = {
  formYear: 2026,
  perQualifyingChild: 2200,
  perOtherDependent: 500,
} as const;
