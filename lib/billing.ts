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
