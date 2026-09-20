import { createHash, randomBytes } from "node:crypto";

/**
 * The website chat (Messaging brief, C), server side.
 *
 * The widget runs on zionrehabcenter.com, which is somebody else's origin, so
 * every call it makes lands here and is made again against the database by
 * the service role. The visitor's browser never holds a database key, never
 * reads a table, and can only ever name the one conversation its token opens.
 *
 * Which sites may call is a list, not a wildcard: a chat endpoint that any
 * page on the internet may post to is a form anybody can fill in for you.
 */
const SITES = [
  "https://zionrehabcenter.com",
  "https://www.zionrehabcenter.com",
];

/** Where the widget is allowed to be. Local origins only while developing. */
export function allowedOrigins(): string[] {
  const configured = (process.env.WEBSITE_ORIGINS ?? "")
    .split(",")
    .map((o) => o.trim().replace(/\/$/, ""))
    .filter(Boolean);
  const sites = configured.length > 0 ? configured : SITES;
  return process.env.NODE_ENV === "production"
    ? sites
    : [...sites, "http://localhost:3000", "http://127.0.0.1:3000"];
}

/**
 * The CORS headers for a reply, or null if this origin is not one of ours.
 *
 * A request with no Origin at all is somebody's curl, not a browser on the
 * website; it is answered without the header and the browser rule never
 * comes into it.
 */
export function corsHeaders(origin: string | null): Record<string, string> | null {
  if (!origin) return {};
  if (!allowedOrigins().includes(origin.replace(/\/$/, ""))) return null;
  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Allow-Headers": "content-type",
    "Access-Control-Max-Age": "86400",
    Vary: "Origin",
  };
}

/** A token for the visitor's tab, and the hash the database keeps instead. */
export function newSessionToken(): { token: string; hash: string } {
  const token = randomBytes(32).toString("hex");
  return { token, hash: hashToken(token) };
}

export function hashToken(token: string): string {
  return createHash("sha256").update(token).digest("hex");
}

/**
 * Enough to stop one machine opening a hundred conversations, and nothing
 * that says where anybody was: the address is salted with a secret this
 * deployment already holds, so the stored value cannot be walked back to an
 * address by anybody reading the table.
 */
export function hashAddress(request: Request): string {
  const forwarded = request.headers.get("x-forwarded-for") ?? "";
  const ip = forwarded.split(",")[0].trim() || request.headers.get("x-real-ip") || "";
  if (!ip) return "";
  const salt = process.env.WEB_CHAT_IP_SALT ?? process.env.SUPABASE_SERVICE_ROLE_KEY ?? "";
  return createHash("sha256").update(`${ip}:${salt}`).digest("hex").slice(0, 32);
}

/** What the widget may send us, whatever it actually sent. */
export function readString(value: unknown, max: number): string {
  return typeof value === "string" ? value.slice(0, max).trim() : "";
}
