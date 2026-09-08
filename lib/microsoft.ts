import "server-only";
import { createHash, randomBytes } from "node:crypto";

/**
 * Microsoft Graph — the OAuth half.
 *
 * Authorization code flow with PKCE, as a confidential client: the code
 * exchange happens on the server with the client secret, and no token ever
 * reaches the browser.
 *
 * Single tenant. The tenant id is in the URL rather than "common", so only
 * accounts in the practice's own directory can connect — a personal Microsoft
 * account cannot be attached to a staff member by accident.
 */

const TENANT = process.env.MICROSOFT_TENANT_ID;
const CLIENT_ID = process.env.MICROSOFT_CLIENT_ID;
const CLIENT_SECRET = process.env.MICROSOFT_CLIENT_SECRET;

export function microsoftConfigured(): boolean {
  return Boolean(TENANT && CLIENT_ID && CLIENT_SECRET);
}

function required(name: string, value: string | undefined): string {
  if (!value) throw new Error(`${name} is not set. The Microsoft connection cannot be used.`);
  return value;
}

/**
 * The permissions asked for.
 *
 * Exactly what the sync does and nothing more.
 *
 * Calendars.ReadWrite because events are pushed as well as read.
 *
 * Mail.Read, not Mail.ReadWrite and emphatically not Mail.Send. The CRM logs
 * correspondence and never composes it — everything this system sends still
 * goes through Resend, under its own identity, where it can be seen. Asking
 * for Mail.Send would let it send as the person who consented, which is not a
 * power anybody asked for and not one worth holding unused.
 *
 * offline_access is what makes a refresh token possible; without it the
 * connection would silently stop working in about an hour.
 */
export const MICROSOFT_SCOPES = [
  "offline_access",
  "openid",
  "profile",
  "email",
  "User.Read",
  "Calendars.ReadWrite",
  "Mail.Read",
];

/**
 * The extra permission for reading the practice's shared mailbox.
 *
 * Asked for only by the Admin who connects that mailbox, not by everybody.
 * Rei and Margaret have no business being asked to consent to reading a
 * mailbox they will never read, and a permission granted "just in case" is a
 * permission nobody remembers agreeing to.
 *
 * It does not, by itself, open anything: Mail.Read.Shared reaches exactly the
 * mailboxes Exchange has already given that person access to.
 */
export const SHARED_MAILBOX_SCOPE = "Mail.Read.Shared";

export function scopesFor(shared: boolean): string[] {
  return shared ? [...MICROSOFT_SCOPES, SHARED_MAILBOX_SCOPE] : MICROSOFT_SCOPES;
}

const AUTH_BASE = (tenant: string) =>
  `https://login.microsoftonline.com/${tenant}/oauth2/v2.0`;

export function redirectUri(): string {
  const site = required("NEXT_PUBLIC_SITE_URL", process.env.NEXT_PUBLIC_SITE_URL);
  return `${site.replace(/\/$/, "")}/api/auth/microsoft/callback`;
}

/** A PKCE pair. The verifier stays on our side; only its hash is sent. */
export function pkce(): { verifier: string; challenge: string } {
  const verifier = randomBytes(32).toString("base64url");
  const challenge = createHash("sha256").update(verifier).digest("base64url");
  return { verifier, challenge };
}

export function authorizeUrl(state: string, challenge: string, shared = false): string {
  const params = new URLSearchParams({
    client_id: required("MICROSOFT_CLIENT_ID", CLIENT_ID),
    response_type: "code",
    redirect_uri: redirectUri(),
    response_mode: "query",
    scope: scopesFor(shared).join(" "),
    state,
    code_challenge: challenge,
    code_challenge_method: "S256",
    // Force the account chooser. Without it, somebody signed into a personal
    // Microsoft account in the same browser connects that one without noticing.
    prompt: "select_account",
  });
  return `${AUTH_BASE(required("MICROSOFT_TENANT_ID", TENANT))}/authorize?${params}`;
}

export type TokenSet = {
  accessToken: string;
  refreshToken: string | null;
  expiresAt: Date;
  scope: string;
};

async function tokenRequest(body: Record<string, string>): Promise<TokenSet> {
  const response = await fetch(`${AUTH_BASE(required("MICROSOFT_TENANT_ID", TENANT))}/token`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: required("MICROSOFT_CLIENT_ID", CLIENT_ID),
      client_secret: required("MICROSOFT_CLIENT_SECRET", CLIENT_SECRET),
      ...body,
    }),
    cache: "no-store",
  });

  const data = (await response.json()) as Record<string, unknown>;

  if (!response.ok) {
    // Microsoft's error_description is long but it is the only thing that says
    // what is actually wrong, and the commonest cause — a secret ID pasted in
    // place of a secret value — says so plainly.
    const description = String(data.error_description ?? data.error ?? response.statusText);
    throw new Error(description.split("\r\n")[0]);
  }

  return {
    accessToken: String(data.access_token),
    refreshToken: data.refresh_token ? String(data.refresh_token) : null,
    expiresAt: new Date(Date.now() + Number(data.expires_in ?? 3600) * 1000),
    scope: String(data.scope ?? ""),
  };
}

export function exchangeCode(code: string, verifier: string): Promise<TokenSet> {
  return tokenRequest({
    grant_type: "authorization_code",
    code,
    redirect_uri: redirectUri(),
    code_verifier: verifier,
  });
}

export function refreshTokens(refreshToken: string): Promise<TokenSet> {
  return tokenRequest({
    grant_type: "refresh_token",
    refresh_token: refreshToken,
    scope: MICROSOFT_SCOPES.join(" "),
  });
}

export type MicrosoftUser = {
  id: string;
  email: string;
  displayName: string;
};

/** Who the token belongs to, so the connection can say whose mailbox it is. */
export async function fetchMe(accessToken: string): Promise<MicrosoftUser> {
  const response = await fetch("https://graph.microsoft.com/v1.0/me", {
    headers: { Authorization: `Bearer ${accessToken}` },
    cache: "no-store",
  });

  if (!response.ok) {
    throw new Error(`Microsoft Graph refused the token (${response.status}).`);
  }

  const data = (await response.json()) as Record<string, unknown>;
  return {
    id: String(data.id ?? ""),
    email: String(data.mail ?? data.userPrincipalName ?? ""),
    displayName: String(data.displayName ?? ""),
  };
}
