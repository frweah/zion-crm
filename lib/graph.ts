import "server-only";
import { refreshTokens } from "@/lib/microsoft";

/**
 * Microsoft Graph — the calls themselves.
 *
 * Everything here takes an access token rather than fetching one, so the two
 * ways a token can be obtained — a signed-in person, or the unattended sweep —
 * stay in the callers where the difference is visible, and this file cannot
 * accidentally read somebody's token in the wrong context.
 */

const GRAPH = "https://graph.microsoft.com/v1.0";

export type TokenBundle = {
  accessToken: string;
  refreshToken: string | null;
  expiresAt: Date | null;
};

/**
 * A token that is good for the next few minutes.
 *
 * The margin matters: a token valid for another ten seconds passes any
 * expiry check and then expires in the middle of a sweep, which reads as a
 * permissions failure and sends somebody looking in the wrong place.
 */
export async function ensureFreshToken(
  bundle: TokenBundle,
  save: (t: { accessToken: string; refreshToken: string | null; expiresAt: Date }) => Promise<void>,
): Promise<string> {
  const soon = Date.now() + 5 * 60 * 1000;
  const stillGood = bundle.expiresAt && bundle.expiresAt.getTime() > soon;

  if (stillGood) return bundle.accessToken;

  if (!bundle.refreshToken) {
    throw new Error("The connection has expired and there is no refresh token. Reconnect Outlook.");
  }

  const fresh = await refreshTokens(bundle.refreshToken);
  await save({
    accessToken: fresh.accessToken,
    refreshToken: fresh.refreshToken,
    expiresAt: fresh.expiresAt,
  });
  return fresh.accessToken;
}

async function graph<T>(
  token: string,
  path: string,
  init: RequestInit = {},
): Promise<T> {
  const response = await fetch(path.startsWith("http") ? path : `${GRAPH}${path}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      ...(init.headers ?? {}),
    },
    cache: "no-store",
  });

  if (!response.ok) {
    let detail = response.statusText;
    try {
      const body = (await response.json()) as { error?: { message?: string; code?: string } };
      detail = body.error?.message ?? body.error?.code ?? detail;
    } catch {
      // A non-JSON error body is still an error; the status is what matters.
    }
    if (response.status === 403) {
      detail = `${detail} — the permission for this may not have been granted. Reconnect Outlook.`;
    }
    throw new Error(`Microsoft Graph ${response.status}: ${detail}`);
  }

  if (response.status === 204) return undefined as T;
  return (await response.json()) as T;
}

// ─────────────────────────────────────────────────────────────
// Calendar
// ─────────────────────────────────────────────────────────────

export type GraphEvent = {
  id: string;
  subject?: string;
  bodyPreview?: string;
  webLink?: string;
  location?: { displayName?: string };
  start?: { dateTime?: string; timeZone?: string };
  end?: { dateTime?: string; timeZone?: string };
  isCancelled?: boolean;
};

export type PushableEvent = {
  title: string;
  startsAt: Date;
  endsAt: Date;
  location: string;
  note: string;
  /** Written into the subject so the event can be matched back to a client. */
  clientNo: number | null;
};

/**
 * The tag that ties an Outlook event to a client.
 *
 * Pushed events carry it so that an event edited or moved in Outlook can still
 * be recognised on the way back. It is also what somebody types by hand when
 * they create the appointment in Outlook rather than here.
 */
export const clientTag = (clientNo: number) => `[Client #${clientNo}]`;

const TAG_PATTERN = /\[\s*client\s*#\s*(\d{1,10})\s*\]/i;

export function clientNoFromSubject(subject: string | undefined): number | null {
  const match = TAG_PATTERN.exec(subject ?? "");
  return match ? Number(match[1]) : null;
}

function subjectWithTag(event: PushableEvent): string {
  if (event.clientNo === null) return event.title;
  const tag = clientTag(event.clientNo);
  return event.title.includes(tag) ? event.title : `${event.title} ${tag}`;
}

/** Graph wants a local date-time and a zone, not an offset. */
function graphTime(d: Date) {
  return { dateTime: d.toISOString().slice(0, 19), timeZone: "UTC" };
}

export async function createEvent(
  token: string,
  event: PushableEvent,
): Promise<{ id: string; webLink: string }> {
  const created = await graph<GraphEvent>(token, "/me/events", {
    method: "POST",
    body: JSON.stringify({
      subject: subjectWithTag(event),
      body: { contentType: "text", content: event.note },
      start: graphTime(event.startsAt),
      end: graphTime(event.endsAt),
      location: event.location ? { displayName: event.location } : undefined,
    }),
  });
  return { id: created.id, webLink: created.webLink ?? "" };
}

export async function updateEvent(
  token: string,
  eventId: string,
  event: PushableEvent,
): Promise<void> {
  await graph(token, `/me/events/${encodeURIComponent(eventId)}`, {
    method: "PATCH",
    body: JSON.stringify({
      subject: subjectWithTag(event),
      body: { contentType: "text", content: event.note },
      start: graphTime(event.startsAt),
      end: graphTime(event.endsAt),
      location: event.location ? { displayName: event.location } : undefined,
    }),
  });
}

export async function deleteEvent(token: string, eventId: string): Promise<void> {
  await graph(token, `/me/events/${encodeURIComponent(eventId)}`, { method: "DELETE" });
}

/** Events in a window, for the pull. */
export async function listEvents(
  token: string,
  from: Date,
  to: Date,
): Promise<GraphEvent[]> {
  const params = new URLSearchParams({
    startDateTime: from.toISOString(),
    endDateTime: to.toISOString(),
    $select: "id,subject,bodyPreview,webLink,location,start,end,isCancelled",
    $top: "200",
    $orderby: "start/dateTime",
  });
  const data = await graph<{ value: GraphEvent[] }>(
    token,
    `/me/calendarView?${params}`,
  );
  return data.value ?? [];
}

// ─────────────────────────────────────────────────────────────
// Mail
//
// $select is the whole safeguard here. The body is never requested, so it
// cannot be logged by mistake, cannot appear in an error, and cannot sit in
// memory waiting for somebody to decide it would be useful.
// ─────────────────────────────────────────────────────────────

export type GraphMessage = {
  id: string;
  conversationId?: string;
  subject?: string;
  receivedDateTime?: string;
  sentDateTime?: string;
  webLink?: string;
  from?: { emailAddress?: { address?: string } };
  toRecipients?: { emailAddress?: { address?: string } }[];
  ccRecipients?: { emailAddress?: { address?: string } }[];
};

/**
 * Messages since a watermark, oldest first.
 *
 * Oldest first is the whole point. A newest-first page walks backwards from
 * now, so a mailbox with more messages than one page holds would have its
 * older mail cut off — and because the watermark then moves to the present,
 * that mail would never be looked at again. Working forwards means a run that
 * hits the cap simply leaves the watermark where it got to, and the next run
 * carries on from there.
 *
 * Several pages per run, so a backlog clears over a few nights rather than
 * one page at a time.
 */
export async function listMessagesSince(
  token: string,
  since: Date,
  maxPages = 5,
  /**
   * Whose mailbox. Omitted, it is the signed-in person's own. Given an
   * address, it is a shared mailbox read under Mail.Read.Shared — which works
   * only because Exchange has granted that person access to it, so the reach
   * of this is decided by an Exchange administrator rather than by us.
   */
  mailbox?: string,
): Promise<{ messages: GraphMessage[]; truncated: boolean }> {
  const root = mailbox ? `/users/${encodeURIComponent(mailbox)}` : "/me";
  const params = new URLSearchParams({
    $select: "id,conversationId,subject,receivedDateTime,sentDateTime,webLink,from,toRecipients,ccRecipients",
    $filter: `receivedDateTime ge ${since.toISOString()}`,
    $top: "200",
    $orderby: "receivedDateTime asc",
  });

  const messages: GraphMessage[] = [];
  let next: string | null = `${root}/messages?${params}`;
  let pages = 0;

  while (next && pages < maxPages) {
    const data: { value?: GraphMessage[]; "@odata.nextLink"?: string } = await graph(token, next);
    messages.push(...(data.value ?? []));
    next = data["@odata.nextLink"] ?? null;
    pages += 1;
  }

  return { messages, truncated: Boolean(next) };
}

/** Every address on a message, lower-cased, for matching. */
export function addressesOf(message: GraphMessage): string[] {
  const all = [
    message.from?.emailAddress?.address,
    ...(message.toRecipients ?? []).map((r) => r.emailAddress?.address),
    ...(message.ccRecipients ?? []).map((r) => r.emailAddress?.address),
  ];
  return all.filter((a): a is string => Boolean(a)).map((a) => a.toLowerCase().trim());
}
