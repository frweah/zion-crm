/**
 * The reports board's shape, its tiles, its chips, and the arithmetic under
 * all three.
 *
 * Separate from the screen for the reason `clients-board-shape` is separate
 * from the stage board: the grid is a client component and this has to be
 * runnable by a check. Every tile is a question about one row, asked here
 * once, so the number on a tile and the rows it filters to are the same
 * arithmetic run twice and cannot disagree.
 *
 * What a row is: one client, one month, one of the five reports. A client
 * getting two services has two rows and their name repeats, which is the
 * owner's ruling 3 - the alternative was a row per client with the templates
 * folded into a cell, and a cell nobody can sort by is a cell nobody reads.
 */

export type ReportBoardRow = {
  row_key: string;
  client_id: string;
  client_name: string;
  client_no: number | null;
  counselor: string | null;
  office: string | null;
  period: string;
  template: string;
  /** Null for a row nobody has started. */
  report_id: string | null;
  /** One of Not started, Draft, Reviewed, Signed, Sent. */
  status: string;
  writer_id: string | null;
  writer: string | null;
  due_on: string | null;
  days_left: number | null;
  signed_at: string | null;
  sent_at: string | null;
  sent_to: string | null;
  /**
   * Whether the practice owes this one by a date.
   *
   * The monthly client report is owed: the scheduler drafts one per client
   * per month and it goes with the invoice. The narrower reports are written
   * when a counselor asks for one, so an unstarted Job Coaching Update is
   * offered rather than late. Overdue reads this, which is why the board did
   * not open with eleven reports nobody had asked for marked red.
   */
  owed: boolean;
  services: string[];
  /** An hourly authorization overlapped the month, so hours were expected. */
  hourly: boolean;
  notes: number;
  contacts: number;
  hours: number;
  weeks_confirmed: number;
  weeks_total: number;
  first_unconfirmed_week: string | null;
  applications: number;
  placements: number;
};

/** The groups, in the order a report goes through them. */
export const GROUPS = ["Not started", "Draft", "Reviewed", "Signed", "Sent"] as const;

/** Sent is folded away: it is the record, not the work. */
export const CLOSED_GROUPS: string[] = ["Sent"];

/**
 * Overdue, which is a flag on a row and a tile, and never a group.
 *
 * A report that is late is late at whatever stage it has reached, so a group
 * called Overdue would take rows out of the four that say what has been done
 * to them. Same arithmetic as `reportOverdue` on the stage board - past its
 * date and not sent - with `owed` added, because a report nobody asked for
 * has no date to be past.
 */
export const overdue = (r: ReportBoardRow, today: string): boolean =>
  Boolean(r.owed && r.due_on && r.due_on < today && r.status !== "Sent");

export const dueThisWeek = (r: ReportBoardRow, today: string): boolean => {
  if (!r.due_on || r.status === "Sent" || r.due_on < today) return false;
  const until = new Date(`${today}T00:00:00Z`);
  until.setUTCDate(until.getUTCDate() + 6);
  return r.due_on <= until.toISOString().slice(0, 10);
};

export type Tile = {
  key: string;
  label: string;
  holds: (r: ReportBoardRow, today: string) => boolean;
};

/**
 * The four tiles that are filters.
 *
 * To file is the fifth thing the brief asks for along the top and is not one
 * of these: it counts items in a panel, not rows in the table, and a tile
 * that filtered the board to nothing would be a tile that lies. It is drawn
 * beside these as a link to the panel.
 */
export const TILES: Tile[] = [
  { key: "overdue", label: "Overdue", holds: overdue },
  { key: "soon", label: "Due this week", holds: dueThisWeek },
  { key: "review", label: "Waiting for review", holds: (r) => r.status === "Draft" },
  { key: "unsent", label: "Signed not yet sent", holds: (r) => r.status === "Signed" },
];

/**
 * What the month has collected, as chips.
 *
 * Only what the drafter actually reads (ruling 5). A text reaches a report
 * once somebody logged it as a contact and a recording once it was confirmed,
 * so neither is a chip of its own: counting them here would tell the person
 * compiling the report that something is in it when it is not.
 *
 * A chip with nothing in it is left off, except the three the owner named as
 * red - no notes at all, no hours on an hourly service, a week nobody has
 * confirmed - because those three are the whole reason the column exists.
 */
export type Chip = { key: string; label: string; bad?: boolean };

export function collected(r: ReportBoardRow): Chip[] {
  const chips: Chip[] = [];

  chips.push({
    key: "notes",
    label: r.notes === 0 ? "no notes" : `${r.notes} ${r.notes === 1 ? "note" : "notes"}`,
    bad: r.notes === 0,
  });

  if (r.contacts > 0) {
    chips.push({ key: "contacts", label: `${r.contacts} contacts and calls` });
  }

  if (r.hourly && r.hours === 0) {
    chips.push({ key: "hours", label: "no hours logged", bad: true });
  } else if (r.hours > 0) {
    chips.push({ key: "hours", label: `${r.hours} hr` });
  }

  if (r.weeks_total > 0) {
    const open = r.weeks_total - r.weeks_confirmed;
    chips.push({
      key: "weeks",
      label:
        open > 0
          ? `${open} of ${r.weeks_total} weeks unconfirmed`
          : `${r.weeks_total} weeks confirmed`,
      bad: open > 0,
    });
  }

  if (r.applications > 0) {
    chips.push({
      key: "applications",
      label: `${r.applications} ${r.applications === 1 ? "application" : "applications"}`,
    });
  }

  if (r.placements > 0) {
    chips.push({
      key: "placements",
      label: `${r.placements} ${r.placements === 1 ? "placement" : "placements"}`,
    });
  }

  return chips;
}

/** A row is missing a source the month expected. */
export const missingASource = (r: ReportBoardRow): boolean =>
  collected(r).some((c) => c.bad);

/** What a group's footer says: how many, how many late, how many short of a source. */
export function groupFooter(rows: ReportBoardRow[], today: string) {
  return {
    count: rows.length,
    overdue: rows.filter((r) => overdue(r, today)).length,
    missing: rows.filter(missingASource).length,
  };
}

/**
 * Who may sign and send, which is narrower than who may write.
 *
 * The database says this and says it last (`report_hands`, 0377); this is so
 * a button is not offered to somebody it would refuse. Reports and Admin for
 * any report, and the writer for their own.
 */
export const canSign = (
  r: ReportBoardRow,
  me: { id: string; role: string },
): boolean => ["Admin", "Reports"].includes(me.role) || r.writer_id === me.id;

/** Who may set the writer or the date: Reports and Admin (ruling 1). */
export const canAssign = (role: string): boolean => ["Admin", "Reports"].includes(role);

/** What `report_board_rows` returned, as rows. */
export function toReportBoardRows(data: unknown): ReportBoardRow[] {
  return ((data ?? []) as Record<string, unknown>[]).map((r) => ({
    row_key: String(r.row_key),
    client_id: String(r.client_id),
    client_name: String(r.client_name ?? ""),
    client_no: r.client_no === null || r.client_no === undefined ? null : Number(r.client_no),
    counselor: (r.counselor as string | null) ?? null,
    office: (r.office as string | null) ?? null,
    period: String(r.period),
    template: String(r.template ?? ""),
    report_id: (r.report_id as string | null) ?? null,
    status: String(r.status ?? "Not started"),
    writer_id: (r.writer_id as string | null) ?? null,
    writer: (r.writer as string | null) ?? null,
    due_on: (r.due_on as string | null) ?? null,
    days_left: r.days_left === null || r.days_left === undefined ? null : Number(r.days_left),
    signed_at: (r.signed_at as string | null) ?? null,
    sent_at: (r.sent_at as string | null) ?? null,
    sent_to: (r.sent_to as string | null) ?? null,
    owed: Boolean(r.owed),
    services: (r.services as string[] | null) ?? [],
    hourly: Boolean(r.hourly),
    notes: Number(r.notes ?? 0),
    contacts: Number(r.contacts ?? 0),
    hours: Number(r.hours ?? 0),
    weeks_confirmed: Number(r.weeks_confirmed ?? 0),
    weeks_total: Number(r.weeks_total ?? 0),
    first_unconfirmed_week: (r.first_unconfirmed_week as string | null) ?? null,
    applications: Number(r.applications ?? 0),
    placements: Number(r.placements ?? 0),
  }));
}
