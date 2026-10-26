import type { ParsedAuthorization } from "@/lib/authorization-parse";

/**
 * The authorization's statuses, in one place (Billing Simplification Brief).
 *
 * §4 replaced Open / Paid / Closed with four working states and Closed. The
 * old Open meant "not finished", and twelve screens asked for it by name;
 * §11 says a fact lives in one place, so they ask here instead. The next
 * person to add a status has one list to change.
 */
export const AUTHORIZATION_STATUSES = [
  "Authorized",
  "Due",
  "Submitted",
  "Paid",
  "Closed",
] as const;

export type AuthorizationStatus = (typeof AUTHORIZATION_STATUSES)[number];

/**
 * Still being worked: what the old `status = 'Open'` meant.
 *
 * Submitted is in it. An authorization that has gone to USOR and not been
 * paid is very much still live work - that is the whole point of the 14-day
 * chase - and leaving it out is how a submitted authorization falls off
 * everybody's screen until somebody notices the money never came.
 */
export const LIVE_STATUSES = ["Authorized", "Due", "Submitted"] as const;

/** Off the working list: §9 puts these under History and in Admin → Money. */
export const SETTLED_STATUSES = ["Paid", "Closed"] as const;

/** What each status says to the person reading it. */
export const STATUS_MEANING: Record<AuthorizationStatus, string> = {
  Authorized: "Entered, not yet due to be billed",
  Due: "Ready to bill",
  Submitted: "Sent to USOR, waiting on payment",
  Paid: "Warrant matched",
  Closed: "Ended without being billed",
};

export const isLive = (status: string): boolean =>
  (LIVE_STATUSES as readonly string[]).includes(status);

/**
 * The starting state of the two billing forms, and the shape of each.
 *
 * These lived in the `"use server"` action files beside the actions that
 * return them, which reads well and is forbidden: a `"use server"` file may
 * export nothing but async functions, because every export becomes a callable
 * server endpoint and an object cannot be called. Next.js does not catch it
 * at build time. It throws when the module is first required on a request —
 * `A "use server" file can only export async functions, found object` — which
 * is a 500 on the screen and nothing in the browser console.
 *
 * So they live here, where a constant is only a constant. The actions import
 * them exactly as the forms do.
 */
export type BatchState = {
  error: string | null;
  ok: string | null;
  rows: { auth_number: string; client_name: string; outcome: string; detail: string }[];
};

export const EMPTY_BATCH: BatchState = { error: null, ok: null, rows: [] };

export type ImportState = {
  error: string | null;
  ok: string | null;
  parsed: ParsedAuthorization | null;
  filename: string | null;
  /**
   * Where the PDF is waiting while somebody checks what was read off it.
   *
   * §12.1 says the authorization is saved "with the PDF referenced", and §11
   * says the PDF exists once. So the file is kept at the moment it is read,
   * under a staging path, and moved into the client's own folder when the
   * client is known - which is at the confirm step, not this one. One object,
   * moved; never two.
   */
  stagedPath: string | null;
  bytes: number | null;
};

export const emptyImport: ImportState = {
  error: null,
  ok: null,
  parsed: null,
  filename: null,
  stagedPath: null,
  bytes: null,
};

/**
 * What to call an authorization USOR has not numbered yet (owner, 26 Oct 2026).
 *
 * Four of the practice's authorizations carry a placeholder label - "coaching
 * 1006" - from the spreadsheet import, and two carry nothing at all. Both
 * kinds were being shown where a V-number goes, so the list read as though
 * USOR had issued a number called "coaching 1006". It had not.
 *
 * The label never pretends. It says there is no number, and then says the two
 * things that actually identify the record to a person: what the service is
 * and who it is for. The placeholder's own text is not shown anywhere,
 * because it is the CRM's filing note and means nothing to USOR or to
 * anybody reading a list.
 */
export function authorizationLabel(a: {
  number?: string | null;
  has_usor_number?: boolean | null;
  service_type?: string | null;
  client_name?: string | null;
}): string {
  const numbered =
    a.has_usor_number ?? /^V[0-9]+/i.test((a.number ?? "").trim());
  const service = a.service_type ?? "";
  const client = a.client_name ?? "";

  if (numbered) return (a.number ?? "").trim();
  const said = [service, client].filter(Boolean).join(", ");
  return said ? `No number yet — ${said}` : "No number yet";
}

/** The same, for a place that has the client's name in its own column. */
export function authorizationNumberLabel(a: {
  number?: string | null;
  has_usor_number?: boolean | null;
}): string {
  const numbered = a.has_usor_number ?? /^V[0-9]+/i.test((a.number ?? "").trim());
  return numbered ? (a.number ?? "").trim() : "No number yet";
}
