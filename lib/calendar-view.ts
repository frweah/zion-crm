import "server-only";
import { PRACTICE_TZ } from "@/lib/constants";

/**
 * The Calendar screen's reads and edits (Messaging brief, M), live from the
 * signed-in person's Outlook with their own token. Times come back in the
 * practice's zone (Prefer: outlook.timezone), so a day is the practice's day.
 */
const GRAPH = "https://graph.microsoft.com/v1.0";

export type CalendarItem = {
  id: string;
  subject: string;
  /** Local wall time in the practice's zone, "YYYY-MM-DDTHH:mm:ss". */
  start: string;
  end: string;
  isAllDay: boolean;
  location: string;
  webLink: string;
  showAs: string;
  isCancelled: boolean;
};

type GraphEvent = {
  id: string;
  subject?: string;
  start?: { dateTime?: string };
  end?: { dateTime?: string };
  isAllDay?: boolean;
  location?: { displayName?: string };
  webLink?: string;
  showAs?: string;
  isCancelled?: boolean;
};

export async function listCalendar(token: string, from: Date, to: Date): Promise<CalendarItem[]> {
  const params = new URLSearchParams({
    startDateTime: from.toISOString(),
    endDateTime: to.toISOString(),
    $select: "id,subject,start,end,isAllDay,location,webLink,showAs,isCancelled",
    $top: "250",
    $orderby: "start/dateTime",
  });
  const response = await fetch(`${GRAPH}/me/calendarView?${params}`, {
    headers: { Authorization: `Bearer ${token}`, Prefer: `outlook.timezone="${PRACTICE_TZ}"` },
    cache: "no-store",
  });
  if (!response.ok) throw new Error(`Outlook did not return the calendar (${response.status}).`);
  const data = (await response.json()) as { value?: GraphEvent[] };
  return (data.value ?? []).map((e) => ({
    id: e.id,
    subject: e.subject ?? "(no title)",
    start: (e.start?.dateTime ?? "").slice(0, 19),
    end: (e.end?.dateTime ?? "").slice(0, 19),
    isAllDay: Boolean(e.isAllDay),
    location: e.location?.displayName ?? "",
    webLink: e.webLink ?? "",
    showAs: e.showAs ?? "",
    isCancelled: Boolean(e.isCancelled),
  }));
}

/**
 * Edits an event made in Outlook: its title, times and place. Never its body -
 * that is the person's own text, and the CRM has no copy to write back.
 */
export async function patchOutlookEvent(
  token: string,
  id: string,
  change: { subject: string; startsAt: Date; endsAt: Date; location: string },
): Promise<void> {
  const time = (d: Date) => ({ dateTime: d.toISOString().slice(0, 19), timeZone: "UTC" });
  const response = await fetch(`${GRAPH}/me/events/${encodeURIComponent(id)}`, {
    method: "PATCH",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      subject: change.subject,
      start: time(change.startsAt),
      end: time(change.endsAt),
      location: { displayName: change.location },
    }),
    cache: "no-store",
  });
  if (!response.ok) throw new Error(`Outlook refused the change (${response.status}).`);
}
