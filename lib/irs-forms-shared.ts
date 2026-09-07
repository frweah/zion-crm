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
