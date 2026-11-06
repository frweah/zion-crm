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
 * The email.
 *
 * The subject carries the one thing that is actually late, because a subject
 * that always says the same words is a subject nobody reads. Everything else
 * is in the four lines below it.
 */
export function weekEmail(w: Week, on: string): { subject: string; body: string } {
  const subject =
    w.tasks_overdue > 0
      ? `Your week — ${count(w.tasks_overdue, "task", "tasks")} past their date (${on})`
      : `Your week — nothing past its date (${on})`;

  const body = [
    `${w.staff_name}, your week of ${span(w.week_start, w.week_end)}.`,
    "",
    didLine(w),
    waitingLine(w),
    aheadLine(w),
  ].join("\n");

  return { subject, body };
}
