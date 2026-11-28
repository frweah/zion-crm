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
  /**
   * The worst thing needing doing for this client, from `next_steps`
   * (0405), and every kind of thing firing for them.
   *
   * The board used to carry two of these worked out for itself - the
   * authorization sentence and the next open task - and a third decided
   * here in TypeScript, where a fortnight of silence was fourteen days
   * of four contact kinds while the threads board counted fourteen days
   * of anything at all. `next_kinds` is what the tiles filter on, so a
   * tile and the cell beside it cannot answer different questions.
   */
  next_step: string | null;
  next_step_severity: number | null;
  next_step_href: string | null;
  next_kinds: string[];
  days_in_stage: number;
  report_status: string | null;
  report_due_on: string | null;
  goal: string | null;
  services: string[];
  funding_source: string | null;
  availability: string | null;
  applied_7d: number;
  next_interview: string | null;
  last_note: string | null;
  last_note_on: string | null;
  flagged_for_review: string | null;
  /**
   * The oldest stage change still waiting on Admin (Part 3), or nulls.
   *
   * The reason comes with it because the decision is made on this row: an
   * Approve that sends somebody to another screen to read one sentence is an
   * Approve pressed without reading it.
   */
  stage_request_id: string | null;
  stage_request_to: string | null;
  stage_request_by: string | null;
  stage_request_at: string | null;
  stage_request_reason: string | null;
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

/**
 * Whether a kind of work is outstanding for this client.
 *
 * The one question this file asks about what needs doing, and it reads the
 * engine's answer rather than deciding. Two rules lived here before - a
 * fortnight of silence and an overdue task - and each disagreed with
 * something: the silence with the threads board, which counts any channel,
 * and the task with the record, which did not mention tasks at all.
 */
export const has = (r: ClientBoardRow, kind: string) => r.next_kinds.includes(kind);

/** Something wants doing today. */
export const dueToday = (r: ClientBoardRow) => (r.next_step_severity ?? 9) <= 1;

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
  { key: "today", label: "Wants doing today", holds: dueToday },
  { key: "contact", label: "Quiet a fortnight", holds: (r) => has(r, "quiet") },
  { key: "report", label: "Report overdue", holds: reportOverdue },
  {
    key: "authorization",
    label: "Authorization needs attention",
    holds: (r) => has(r, "authorization"),
  },
  { key: "staff", label: "No assigned staff", holds: (r) => !r.assigned_staff_id },
  { key: "flagged", label: "Flagged for review", holds: (r) => Boolean(r.flagged_for_review) },
];

/** A stage change is waiting on somebody. */
export const requestWaiting = (r: ClientBoardRow) => Boolean(r.stage_request_id);

/**
 * The sixth tile, Admin's (brief, Part 3).
 *
 * It is the only tile whose work nobody else can do: a Job Coach looking at
 * "requests waiting" would be reading a number they cannot act on, and a tile
 * that is not a thing to do is a count, which belongs on the All clients
 * strip. Same shape as the other five, so it filters the same way.
 */
export const REQUESTS_TILE: Tile = {
  key: "requested",
  label: "Stage-change requests waiting",
  holds: requestWaiting,
};

/** The tiles this person gets, which is the five plus Admin's sixth. */
export const tilesFor = (isAdmin: boolean): Tile[] =>
  isAdmin ? [...TILES, REQUESTS_TILE] : TILES;

/** What a group's footer says: the three things somebody is behind on. */
export function groupFooter(rows: ClientBoardRow[], today: string) {
  return {
    quiet: rows.filter((r) => has(r, "quiet")).length,
    dueToday: rows.filter(dueToday).length,
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
    next_step: (r.next_step as string | null) ?? null,
    next_step_severity:
      r.next_step_severity === null || r.next_step_severity === undefined
        ? null
        : Number(r.next_step_severity),
    next_step_href: (r.next_step_href as string | null) ?? null,
    next_kinds: Array.isArray(r.next_kinds) ? (r.next_kinds as string[]) : [],
    days_in_stage: Number(r.days_in_stage ?? 0),
    report_status: (r.report_status as string | null) ?? null,
    report_due_on: (r.report_due_on as string | null) ?? null,
    goal: (r.goal as string | null) ?? null,
    services: (r.services as string[] | null) ?? [],
    funding_source: (r.funding_source as string | null) ?? null,
    availability: (r.availability as string | null) ?? null,
    applied_7d: Number(r.applied_7d ?? 0),
    next_interview: (r.next_interview as string | null) ?? null,
    last_note: (r.last_note as string | null) ?? null,
    last_note_on: (r.last_note_on as string | null) ?? null,
    flagged_for_review: (r.flagged_for_review as string | null) ?? null,
    stage_request_id: (r.stage_request_id as string | null) ?? null,
    stage_request_to: (r.stage_request_to as string | null) ?? null,
    stage_request_by: (r.stage_request_by as string | null) ?? null,
    stage_request_at: (r.stage_request_at as string | null) ?? null,
    stage_request_reason: (r.stage_request_reason as string | null) ?? null,
    billing_office: officeOf(String(r.client_id)),
  }));
}
