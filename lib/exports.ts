/**
 * The monthly export.
 *
 * Six files a month, for the accountant, the CPA at year end, and anybody who
 * asks for something the CRM does not have a screen for. Everything here is a
 * plain CSV: no spreadsheet, no zip, nothing that needs a library to open.
 *
 * Two rules hold this together and both are checked by scripts/check-exports:
 *
 *   Nothing restricted leaves. A date of birth, an address, an SSN or a TIN
 *   is readable by some roles inside the app for a reason; a file on somebody's
 *   laptop has no roles. So the columns are declared here rather than built
 *   from a "select *", and the check refuses a restricted name.
 *
 *   Every kind offered is a kind that exists. A download link that 404s
 *   at month end, with an accountant waiting, is worse than no link.
 *
 * Kept out of the route so the page can list the same names, and out of
 * "server-only" so the check can read it under bare node.
 */

export type ExportKind = {
  key: string;
  label: string;
  detail: string;
  /** Admin only, because it carries what people were paid. */
  adminOnly?: boolean;
};

export const EXPORTS: ExportKind[] = [
  {
    key: "service-hours",
    label: "Service hours",
    detail:
      "Every billable and non-billable hour logged against an authorization in the month, with the client, the service and who logged it.",
  },
  {
    key: "invoices",
    label: "Invoices and payments",
    detail:
      "Invoices raised in the month, and separately what was paid in the month — a warrant often lands in a different month from the invoice.",
  },
  {
    key: "authorizations",
    label: "Authorizations",
    detail:
      "Every authorization open at any point in the month, with what is authorized, earned, invoiced and received.",
  },
  {
    key: "placements",
    label: "Placements",
    detail: "Placements that started in the month, with the employer, the job and the checks.",
  },
  {
    key: "referrals",
    label: "Referrals and caseload",
    detail:
      "Clients referred in the month, and the state of the whole active caseload at the end of it. No restricted detail — no dates of birth, no addresses.",
  },
  {
    key: "contractor-hours",
    label: "Contractor hours",
    detail:
      "Work sessions by staff member with the category and, where a rate is on file, what the hours came to. This is payroll, so Admin only.",
    adminOnly: true,
  },
];

/** Names that must never appear in a column list. */
export const RESTRICTED_COLUMNS = [
  "dob",
  "date_of_birth",
  "address",
  "street",
  "ssn",
  "tin",
  "tin_encrypted",
  "sensitive",
  "accommodation",
  "access_encrypted",
  "refresh_encrypted",
  "employer_ein",
];

export function exportsFor(role: string): ExportKind[] {
  return EXPORTS.filter((e) => !e.adminOnly || role === "Admin");
}

/** One CSV cell, quoted only when it has to be. */
export function csvCell(value: unknown): string {
  if (value === null || value === undefined) return "";
  const s = String(value);
  return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

/**
 * A CSV, with a byte order mark.
 *
 * Excel opens a UTF-8 file as the local codepage unless it sees one, which
 * turns every name with an accent in it into mojibake on the accountant's
 * screen — and the names in this system are the whole point.
 */
export function toCsv(headers: string[], rows: unknown[][]): string {
  const lines = [headers.map(csvCell).join(",")];
  for (const row of rows) lines.push(row.map(csvCell).join(","));
  return "﻿" + lines.join("\r\n") + "\r\n";
}

/** The month a request asked for, or the current one. */
export function monthRange(month: string | null): { month: string; start: string; end: string } {
  const m = /^\d{4}-\d{2}$/.test(month ?? "") ? month! : new Date().toISOString().slice(0, 7);
  const [y, mm] = m.split("-").map(Number);
  const start = `${m}-01`;
  const end = new Date(Date.UTC(y, mm, 0)).toISOString().slice(0, 10);
  return { month: m, start, end };
}
