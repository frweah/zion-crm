import { createHmac } from "node:crypto";

/**
 * Whether a request really came from Twilio, as a rule rather than a call.
 *
 * This file has no imports but node's own crypto, and reads no environment
 * variable: the auth token is an argument. Both of those are on purpose, and
 * for the reason `lib/text-rows.ts` has no imports — the rule can then be run
 * over made-up requests by `scripts/check-twilio.mjs`, with a made-up token,
 * rather than read and hoped at. A signature check nothing exercises is a
 * signature check that either refuses every client's reply or accepts
 * anybody's, and both of those are quiet.
 *
 * The scheme is Twilio's and not a choice:
 *
 *   1. the full URL they were configured with, query string and all;
 *   2. every POST parameter sorted by name, case-sensitively;
 *   3. each one appended as name then value, with nothing between;
 *   4. HMAC-SHA1 of that string, keyed with the account's auth token;
 *   5. base64.
 *
 * The URL is part of what is signed, which is the half worth understanding:
 * it is what stops a body captured at the inbound hook being replayed at the
 * status hook, and it is also why the path configured at Twilio and the path
 * serving the request have to agree character for character.
 */
export function expectedSignature(
  authToken: string,
  url: string,
  params: Record<string, string>,
): string {
  // Case-sensitive, which is what JavaScript's default sort does: it compares
  // UTF-16 code units, so every capital sorts before every lower-case letter,
  // the same order Twilio means by "Unix-style".
  const sorted = Object.keys(params).sort();
  let data = url;
  for (const key of sorted) data += key + params[key];
  return createHmac("sha1", authToken).update(data, "utf8").digest("base64");
}

/** What a request's headers look like to this file, and no more than that. */
export type HeaderBag = { get(name: string): string | null };

/**
 * The URL Twilio signed, rebuilt from what arrived.
 *
 * `request.url` inside a serverless function is not the URL the caller asked
 * for: the platform rewrites the host and can present the scheme as http
 * behind its own TLS. Signing against that produces a mismatch on every
 * request and a webhook that refuses everything, which is the most expensive
 * way to be secure. So the forwarded headers are read, and the scheme
 * defaults to https because that is the only scheme a Twilio webhook here is
 * ever configured with.
 *
 * The query string is kept, because Twilio signs it. The port is not
 * considered: these webhooks are served on 443 with no port in the URL, and
 * Twilio's rules about when a port is dropped differ between voice and
 * messaging — a port appearing here would be a reason to come back and read
 * their table rather than guess.
 */
export function signedUrl(requestUrl: string, headers: HeaderBag): string {
  const url = new URL(requestUrl);
  const host = headers.get("x-forwarded-host") ?? headers.get("host") ?? url.host;
  const proto = headers.get("x-forwarded-proto")?.split(",")[0]?.trim() || "https";
  return `${proto}://${host}${url.pathname}${url.search}`;
}
