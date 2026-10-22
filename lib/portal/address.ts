/**
 * Where the client portal lives.
 *
 * Its own address since 21 Oct 2026: portal.zionvocrehab.com, so a client is
 * never sent to the CRM's address and the staff app is not reachable from the
 * portal's (middleware.ts routes the portal host to /portal and nothing
 * else). zionvocrehab.com/portal on the website forwards there too.
 *
 * Until the portal host is live - its DNS record added and
 * NEXT_PUBLIC_PORTAL_HOST set - the portal keeps answering at
 * <crm>/portal, and everything that names the address names that one.
 */
export const PORTAL_HOSTS = ["portal.zionvocrehab.com"];

export function portalHost(): string {
  return (process.env.NEXT_PUBLIC_PORTAL_HOST ?? "").trim().toLowerCase();
}

/** The full address, for invitations, notices and the staff panel. */
export function portalAddress(): string {
  const host = portalHost();
  if (host) return `https://${host}`;
  return `${(process.env.NEXT_PUBLIC_SITE_URL ?? "").replace(/\/$/, "")}/portal`;
}

/** The same, as a person types it: no https://. */
export function portalAddressToType(): string {
  return portalAddress().replace(/^https?:\/\//, "");
}
