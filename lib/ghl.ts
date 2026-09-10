import "server-only";

/**
 * GoHighLevel, as much of it as texting needs.
 *
 * A plain fetch against the LeadConnector API rather than an SDK, for the same
 * reason lib/email.ts is: three endpoints, one shape, and one less dependency
 * to keep current in a system that will outlive this build.
 *
 * The token is scoped to the Zion sub-account. The agency-level key that
 * preceded it was revoked, and nothing here should ever want agency scope —
 * if a call starts failing for want of it, the answer is that the call is
 * reaching for something that is not ours.
 *
 * Every function returns a result rather than throwing, because the caller
 * has to tell the difference between "the client has it" and "nothing was
 * sent". A message recorded as sent when it was not is worse than an error.
 */

const BASE = "https://services.leadconnectorhq.com";

/** The API dates its own shapes. Contacts and conversations disagree. */
const CONTACTS_VERSION = "2021-07-28";
const CONVERSATIONS_VERSION = "2021-04-15";

export type GhlResult<T> = { ok: true; data: T } | { ok: false; error: string };

export function smsConfigured(): boolean {
  return Boolean(process.env.GHL_API_KEY && process.env.GHL_LOCATION_ID);
}

function headers(version: string): Record<string, string> {
  return {
    Authorization: `Bearer ${process.env.GHL_API_KEY}`,
    Version: version,
    Accept: "application/json",
    "Content-Type": "application/json",
  };
}

async function call<T>(
  path: string,
  version: string,
  init?: RequestInit,
): Promise<GhlResult<T>> {
  if (!smsConfigured()) {
    return {
      ok: false,
      error:
        "Texting is not set up. Add GHL_API_KEY and GHL_LOCATION_ID, then try again.",
    };
  }

  try {
    const res = await fetch(`${BASE}${path}`, {
      ...init,
      headers: { ...headers(version), ...(init?.headers ?? {}) },
      cache: "no-store",
    });

    const text = await res.text();
    let body: unknown = null;
    try {
      body = text ? JSON.parse(text) : null;
    } catch {
      body = null;
    }

    if (!res.ok) {
      const message =
        (body as { message?: string | string[] } | null)?.message ??
        text.slice(0, 200) ??
        `HTTP ${res.status}`;
      return {
        ok: false,
        error: `${res.status} ${Array.isArray(message) ? message.join("; ") : message}`,
      };
    }

    return { ok: true, data: body as T };
  } catch (err) {
    return {
      ok: false,
      error: err instanceof Error ? err.message : "The request could not be made.",
    };
  }
}

/**
 * The contact this number belongs to, if GoHighLevel already knows it.
 *
 * Looked up rather than created wherever possible: 67 of the 72 active
 * clients came across from GoHighLevel in the first place and already carry
 * their contact id.
 */
export async function findContactByPhone(phone: string): Promise<GhlResult<string | null>> {
  const location = process.env.GHL_LOCATION_ID!;
  const result = await call<{ contact?: { id?: string } | null }>(
    `/contacts/search/duplicate?locationId=${encodeURIComponent(location)}&number=${encodeURIComponent(phone)}`,
    CONTACTS_VERSION,
  );
  if (!result.ok) return result;
  return { ok: true, data: result.data?.contact?.id ?? null };
}

/**
 * Make sure there is a contact to text.
 *
 * Upsert rather than create: GoHighLevel matches on the number, so running
 * this twice does not leave the practice with two of the same person.
 */
export async function upsertContact(params: {
  phone: string;
  name: string;
}): Promise<GhlResult<string>> {
  const [firstName, ...rest] = params.name.trim().split(/\s+/);
  const result = await call<{ contact?: { id?: string } }>("/contacts/upsert", CONTACTS_VERSION, {
    method: "POST",
    body: JSON.stringify({
      locationId: process.env.GHL_LOCATION_ID,
      phone: params.phone,
      firstName: firstName || params.name,
      lastName: rest.join(" "),
      source: "Zion CRM",
    }),
  });

  if (!result.ok) return result;
  const id = result.data?.contact?.id;
  return id
    ? { ok: true, data: id }
    : { ok: false, error: "GoHighLevel accepted the contact but returned no id for it." };
}

/** Send one text. Returns the provider's id for it, which is our receipt. */
export async function sendSms(params: {
  contactId: string;
  message: string;
}): Promise<GhlResult<string>> {
  const result = await call<{ messageId?: string; msg?: string }>(
    "/conversations/messages",
    CONVERSATIONS_VERSION,
    {
      method: "POST",
      body: JSON.stringify({
        type: "SMS",
        contactId: params.contactId,
        message: params.message,
        fromNumber: process.env.GHL_FROM_NUMBER,
      }),
    },
  );

  if (!result.ok) return result;
  return { ok: true, data: result.data?.messageId ?? "" };
}
