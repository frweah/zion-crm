/**
 * Where intake reads from, and whose mail it will act on.
 *
 * Two facts, in one place, because both are load-bearing and both are the kind
 * of thing that gets loosened by accident. The mailbox is service@ and not
 * anybody's personal inbox; the sender must be utah.gov and nothing else, and
 * everything that is not gets left alone with no record and no notification.
 *
 * Here rather than in the route so that scripts/check-intake.mjs can try the
 * cases against the same expression the route uses, instead of a copy of it
 * that could drift into being right about a rule the route no longer has.
 */
export const INTAKE_MAILBOX = "service@zionvocrehab.com";

/**
 * A Utah state address: utah.gov, or any sub-domain of it.
 *
 * Anchored at both ends. Without the anchor "dana@utah.gov.example.com" would
 * pass, and a referral is the one document that creates a client - so the
 * cheapest possible way in is the one worth closing.
 */
const UTAH_GOV = /^[^@\s]+@([a-z0-9-]+\.)*utah\.gov$/i;

export function isFromUtahGov(address: string | null | undefined): boolean {
  return UTAH_GOV.test((address ?? "").trim());
}
