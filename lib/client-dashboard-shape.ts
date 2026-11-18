/**
 * The client dashboard's shape, and the arithmetic on its money strip.
 *
 * Separate from `lib/client-dashboard.ts` for the reason `billing-board-shape`
 * is separate from `billing-board`: that one is `server-only` because it holds
 * the reads, and a client component that imports a server-only module fails
 * the build. Nothing here touches the database.
 *
 * The strip is worked out from the same rows the board draws, so the figure
 * on the record and the figure on Billing › Authorizations cannot drift: they
 * are the same numbers added up twice rather than two queries that agree
 * today.
 */
import type { BoardAuthorization } from "@/lib/billing-board-shape";

export type HoursLine = {
  /** The service an hourly authorization is for: Job development, Job coaching. */
  service: string;
  hours: number;
};

export type ReportStanding = {
  status: string;
  due_on: string | null;
  sent_at: string | null;
};

export type JobStanding = {
  status: string | null;
  /** The day the client reached that status. */
  since: string | null;
  open: number;
  byStatus: { status: string; count: number }[];
  lastPlacement: { employer: string; title: string; start_date: string | null } | null;
  next: {
    match_id: string;
    status: string;
    employer: string;
    title: string;
    when: string | null;
    detail: string;
    who: string;
  }[];
};

export type LastContact = {
  at: string;
  /** How they were reached, in the word a person would use: text, email, call. */
  channel: string;
} | null;

/** What the money strip says, from the client's board rows. */
export type MoneyStrip = {
  authorized: number;
  billed: number;
  outstanding: number;
  paid: number;
  authorizations: number;
  invoices: number;
  /** The only invoice number, where there is only one. */
  invoiceNumber: string | null;
  needsInvoice: number;
  lastPaidOn: string | null;
};

export function moneyStrip(rows: BoardAuthorization[]): MoneyStrip {
  const numbers = new Set<string>();
  let invoices = 0;
  let lastPaidOn: string | null = null;
  for (const r of rows) {
    invoices += r.invoice_count;
    if (r.invoice_number) numbers.add(r.invoice_number);
    if (r.paid_on && (!lastPaidOn || r.paid_on > lastPaidOn)) lastPaidOn = r.paid_on;
  }
  return {
    authorized: rows.reduce((n, r) => n + r.authorized, 0),
    billed: rows.reduce((n, r) => n + r.invoiced, 0),
    outstanding: rows.reduce((n, r) => n + r.outstanding, 0),
    paid: rows.reduce((n, r) => n + r.paid, 0),
    authorizations: rows.length,
    invoices,
    invoiceNumber: numbers.size === 1 ? [...numbers][0] : null,
    // The one figure on the strip that is a job of work rather than a sum.
    needsInvoice: rows.filter((r) => r.grp === "Needs invoice").length,
    lastPaidOn,
  };
}

/**
 * Which kinds in the stream count as having been in touch with the client.
 *
 * A note is not contact: somebody writing up a meeting a week later would
 * otherwise move "last contact" to today. A text, an email, a logged
 * counselor contact and an appointment are.
 */
export const CONTACT_KINDS: Record<string, string> = {
  Text: "text",
  Mail: "email",
  Counselor: "counselor contact",
  Appointment: "appointment",
};
