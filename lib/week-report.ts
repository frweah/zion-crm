/**
 * What the Friday email says about somebody's week, with nothing to read it
 * from.
 *
 * Separated from the route the way `lib/health-report.ts` is, and for the same
 * reason: `check-week-report.mjs` runs these words over made-up figures before
 * every build, and a route cannot be imported outside a request. So this file
 * has no imports.
 *
 * Two rules it is held to. **It never says a week was busy when the records
 * say nothing happened** - a cheerful line over five zeros is how somebody
 * learns to stop reading the email. And **it names no client**, so the email
 * can be read on a phone in public: counts, hours and dates only, which is
 * the rule the Monday email follows.
 *
 * **What it leads with is what the brief asked for**, in the owner's order:
 * things waiting to be filed, clients who have gone quiet, and reports due or
 * overdue. The week's own figures - hours, notes, calls, tasks - come after
 * them, because they are what happened and the three above are what to do.
 */

export type Week = {
  staff_name: string;
  email: string;
  role: string;
  week_start: string;
  week_end: string;
  billable_hours: number | string | null;
  clocked_hours: number | string | null;
  notes_written: number;
  contacts_logged: number;
  tasks_done: number;
  tasks_open: number;
  tasks_overdue: number;
  clients_carried: number;
  appointments: number;
  /** The three the brief names, counted in 0319. */
  to_file_waiting: number;
  quiet_clients: number;
  reports_due: number;
  reports_overdue: number;
};

const n = (v: number | string | null | undefined): number => Number(v ?? 0);

/** "12.5 hours", "1 hour", with the half hours that time sheets actually hold. */
function hours(v: number | string | null): string {
  const x = n(v);
  const said = Number.isInteger(x) ? String(x) : x.toFixed(2).replace(/0$/, "");
  return `${said} ${x === 1 ? "hour" : "hours"}`;
}

/** "3 tasks", "1 task". */
function count(x: number, one: string, many: string): string {
  return `${x} ${x === 1 ? one : many}`;
}

/** Monday to Friday, as a person would write it: "2 to 6 Nov". */
export function span(from: string, to: string): string {
  const day = (s: string) => new Date(`${s}T00:00:00Z`);
  const month = (d: Date) =>
    d.toLocaleDateString("en-GB", { month: "short", timeZone: "UTC" });
  const a = day(from);
  const b = day(to);
  if (Number.isNaN(a.getTime()) || Number.isNaN(b.getTime())) return `${from} to ${to}`;
  const same = month(a) === month(b);
  return same
    ? `${a.getUTCDate()} to ${b.getUTCDate()} ${month(b)}`
    : `${a.getUTCDate()} ${month(a)} to ${b.getUTCDate()} ${month(b)}`;
}

/**
 * What they did, or the plain fact that the records hold nothing.
 *
 * Every part is left out when it is zero, which is what keeps the line short
 * for the people whose week is two of these things. All of them zero is its
 * own sentence rather than an empty list: a Billing week with nothing logged
 * is ordinary, and a Job Search week with nothing logged is worth seeing.
 */
export function didLine(w: Week): string {
  const parts: string[] = [];
  if (n(w.clocked_hours) > 0) parts.push(`${hours(w.clocked_hours)} on the clock`);
  if (n(w.billable_hours) > 0) parts.push(`${hours(w.billable_hours)} billable`);
  if (w.notes_written > 0) parts.push(count(w.notes_written, "note", "notes"));
  if (w.contacts_logged > 0) parts.push(count(w.contacts_logged, "call logged", "calls logged"));
  if (w.tasks_done > 0) parts.push(`${count(w.tasks_done, "task", "tasks")} finished`);
  if (parts.length === 0) return "Nothing is recorded against you this week.";
  return `This week: ${parts.join(", ")}.`;
}

/** What is waiting now, which is the half somebody acts on. */
export function waitingLine(w: Week): string {
  if (w.tasks_open === 0) return "Nothing is waiting on you.";
  if (w.tasks_overdue === 0) {
    return `Waiting on you: ${count(w.tasks_open, "task", "tasks")}, none past its date.`;
  }
  return `Waiting on you: ${count(w.tasks_open, "task", "tasks")}, ${w.tasks_overdue} of them past their date.`;
}

/** And what is already in next week. */
export function aheadLine(w: Week): string {
  const parts: string[] = [];
  if (w.appointments > 0) {
    parts.push(`${count(w.appointments, "appointment", "appointments")} in the diary`);
  }
  if (w.clients_carried > 0) {
    parts.push(`${count(w.clients_carried, "client", "clients")} on your list`);
  }
  if (parts.length === 0) return "Next week: nothing in the diary.";
  return `Next week: ${parts.join(", and ")}.`;
}

/**
 * The three things to do something about, each left out when there is nothing
 * to say. All three silent is its own sentence: somebody with an empty inbox,
 * no quiet clients and no report owing should be told that plainly rather than
 * reading three lines of zeros to work it out.
 */
export function owedLines(w: Week): string[] {
  const lines: string[] = [];
  if (w.to_file_waiting > 0) {
    lines.push(`To file: ${count(w.to_file_waiting, "thing", "things")} waiting on My day.`);
  }
  if (w.quiet_clients > 0) {
    lines.push(
      `Quiet: ${count(w.quiet_clients, "client", "clients")} with nothing on the record for a fortnight.`,
    );
  }
  if (w.reports_due > 0) {
    const late =
      w.reports_overdue === 0
        ? "none past its date"
        : w.reports_overdue >= w.reports_due
          ? "all of them past their date"
          : `${w.reports_overdue} past their date`;
    lines.push(`Reports: ${count(w.reports_due, "report", "reports")} to finish, ${late}.`);
  }
  if (lines.length === 0) {
    return ["Nothing is waiting to be filed, nobody has gone quiet, and no report is owing."];
  }
  return lines;
}

/**
 * The email.
 *
 * The subject carries the most pressing of the three, because a subject that
 * always says the same words is a subject nobody reads. Reports first: they
 * are the thing with a date the state is waiting on.
 */
export function weekEmail(w: Week, on: string): { subject: string; body: string } {
  const lead =
    w.reports_overdue > 0
      ? `${count(w.reports_overdue, "report", "reports")} past their date`
      : w.to_file_waiting > 0
        ? `${count(w.to_file_waiting, "thing", "things")} to file`
        : w.quiet_clients > 0
          ? `${count(w.quiet_clients, "client", "clients")} gone quiet`
          : w.reports_due > 0
            ? `${count(w.reports_due, "report", "reports")} to finish`
            : w.tasks_overdue > 0
              ? `${count(w.tasks_overdue, "task", "tasks")} past their date`
              : "nothing waiting";
  const subject = `Your week — ${lead} (${on})`;

  const body = [
    `${w.staff_name}, your week of ${span(w.week_start, w.week_end)}.`,
    "",
    ...owedLines(w),
    "",
    didLine(w),
    waitingLine(w),
    aheadLine(w),
  ].join("\n");

  return { subject, body };
}
