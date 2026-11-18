/**
 * The stage board's shape, its tiles, and the arithmetic under both.
 *
 * Separate from `lib/clients-board.ts` for the reason `billing-board-shape` is
 * separate from `billing-board`: that one is `server-only` because it holds
 * the read, and the grid that draws these rows is a client component.
 *
 * Every tile is a question about a row, asked here once. A tile that counted
 * one thing while the rows it filtered to counted another would be worse than
 * no tile, and that is the shape of bug this file exists to make impossible:
 * the count is `rows.filter(tile.holds).length`, not a second query.
 */

export type ClientBoardRow = {
  client_id: string;
  name: string;
  stage: string;
  counselor: string | null;
  office: string | null;
  assigned_staff_id: string | null;
  assigned_to: string | null;
  job_status: string | null;
  job_status_on: string | null;
  last_contact_at: string | null;
  /** The kind as the stream names it: Text, Mail, Counselor, Appointment. */
  last_contact_kind: string | null;
  next_task_id: string | null;
  next_task_title: string | null;
  next_task_owner: string | null;
  next_task_due: string | null;
  days_in_stage: number;
  report_status: string | null;
  report_due_on: string | null;
  attention: string | null;
  attention_urgency: number | null;
  goal: string | null;
  services: string[];
  funding_source: string | null;
  availability: string | null;
  applied_7d: number;
  next_interview: string | null;
  last_note: string | null;
  last_note_on: string | null;
  authorization_ends_on: string | null;
  flagged_for_review: string | null;
  /** Merged in by the reader, which is where the billing offices live. */
  billing_office: string;
};

/** Days between a day and an instant, in whole days, never negative. */
export function daysSince(at: string | null, today: string): number | null {
  if (!at) return null;
  const then = Date.parse(at.length === 10 ? `${at}T00:00:00Z` : at);
  const now = Date.parse(`${today}T00:00:00Z`);
  if (Number.isNaN(then) || Number.isNaN(now)) return null;
  return Math.max(Math.floor((now - then) / 86400000), 0);
}

/** Nobody has reached this client in a fortnight, or ever. */
export const outOfContact = (r: ClientBoardRow, today: string) => {
  const n = daysSince(r.last_contact_at, today);
  return n === null || n >= 14;
};

export const taskOverdue = (r: ClientBoardRow, today: string) =>
  Boolean(r.next_task_due && r.next_task_due < today);

export const reportOverdue = (r: ClientBoardRow, today: string) =>
  Boolean(r.report_due_on && r.report_due_on < today && r.report_status !== "Sent");

export type Tile = {
  key: string;
  label: string;
  holds: (r: ClientBoardRow, today: string) => boolean;
};

/**
 * The tiles, which are filters rather than counts (brief, Part 2).
 *
 * Total and New this month are counts, and the owner put them back on the
 * All clients strip where a count belongs. What is left is five things
 * somebody has to do something about - and each one reads as a sentence
 * about one client, which is why a tile can filter the board to exactly the
 * rows it counted.
 */
export const TILES: Tile[] = [
  { key: "contact", label: "No contact 14+ days", holds: outOfContact },
  { key: "report", label: "Report overdue", holds: reportOverdue },
  {
    key: "authorization",
    label: "Authorization ends within 30 days",
    holds: (r) => Boolean(r.authorization_ends_on),
  },
  { key: "staff", label: "No assigned staff", holds: (r) => !r.assigned_staff_id },
  { key: "flagged", label: "Flagged for review", holds: (r) => Boolean(r.flagged_for_review) },
];

/** What a group's footer says: the three things somebody is behind on. */
export function groupFooter(rows: ClientBoardRow[], today: string) {
  return {
    outOfContact: rows.filter((r) => outOfContact(r, today)).length,
    tasksOverdue: rows.filter((r) => taskOverdue(r, today)).length,
    reportsOverdue: rows.filter((r) => reportOverdue(r, today)).length,
  };
}

/** The average days in stage a group's header carries, rounded. */
export function averageDays(rows: ClientBoardRow[]): number {
  if (!rows.length) return 0;
  return Math.round(rows.reduce((n, r) => n + r.days_in_stage, 0) / rows.length);
}

/** A contact kind in the word a person would use. */
export const CHANNEL: Record<string, string> = {
  Text: "text",
  Mail: "email",
  Counselor: "counselor",
  Appointment: "appointment",
};

/** Days in stage worth a second look, and days without contact. */
export const LONG_IN_STAGE = 45;
export const OUT_OF_CONTACT = 14;

/**
 * What `clients_board_rows` returned, as rows.
 *
 * The billing office is the one column the function cannot answer: it is
 * worked out from the counselor's office by `readBillingOffices`, which the
 * Clients screen already reads for its filters. So it is passed in rather
 * than read twice.
 */
export function toClientBoardRows(
  data: unknown,
  officeOf: (clientId: string) => string,
): ClientBoardRow[] {
  return ((data ?? []) as Record<string, unknown>[]).map((r) => ({
    client_id: String(r.client_id),
    name: String(r.name ?? ""),
    stage: String(r.stage ?? ""),
    counselor: (r.counselor as string | null) ?? null,
    office: (r.office as string | null) ?? null,
    assigned_staff_id: (r.assigned_staff_id as string | null) ?? null,
    assigned_to: (r.assigned_to as string | null) ?? null,
    job_status: (r.job_status as string | null) ?? null,
    job_status_on: (r.job_status_on as string | null) ?? null,
    last_contact_at: (r.last_contact_at as string | null) ?? null,
    last_contact_kind: (r.last_contact_kind as string | null) ?? null,
    next_task_id: (r.next_task_id as string | null) ?? null,
    next_task_title: (r.next_task_title as string | null) ?? null,
    next_task_owner: (r.next_task_owner as string | null) ?? null,
    next_task_due: (r.next_task_due as string | null) ?? null,
    days_in_stage: Number(r.days_in_stage ?? 0),
    report_status: (r.report_status as string | null) ?? null,
    report_due_on: (r.report_due_on as string | null) ?? null,
    attention: (r.attention as string | null) ?? null,
    attention_urgency:
      r.attention_urgency === null || r.attention_urgency === undefined
        ? null
        : Number(r.attention_urgency),
    goal: (r.goal as string | null) ?? null,
    services: (r.services as string[] | null) ?? [],
    funding_source: (r.funding_source as string | null) ?? null,
    availability: (r.availability as string | null) ?? null,
    applied_7d: Number(r.applied_7d ?? 0),
    next_interview: (r.next_interview as string | null) ?? null,
    last_note: (r.last_note as string | null) ?? null,
    last_note_on: (r.last_note_on as string | null) ?? null,
    authorization_ends_on: (r.authorization_ends_on as string | null) ?? null,
    flagged_for_review: (r.flagged_for_review as string | null) ?? null,
    billing_office: officeOf(String(r.client_id)),
  }));
}
