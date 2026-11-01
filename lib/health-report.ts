/**
 * What the Monday health email says, with nothing to read it from.
 *
 * Separated from the route for the reason `lib/report-shape.ts` was separated
 * from `lib/report-period.ts`: `check-health-report.mjs` has to be able to run
 * these words over made-up figures before every build, and a route cannot be
 * imported outside a request.
 *
 * Every line names a number and what to do about it, or says plainly that
 * nothing is known. The one thing this must never do is read as reassuring
 * when it has nothing to be reassuring about - "the suite passes" is not a
 * claim this system can make, and "the suite passed on Thursday, four days
 * ago" is.
 */

export type Health = {
  verify_at: string | null;
  verify_ok: boolean | null;
  verify_detail: string | null;
  backup_at: string | null;
  backup_ok: boolean | null;
  backup_detail: string | null;
  graph_total: number;
  graph_expiring: number;
  graph_soonest: string | null;
  graph_failing: number;
  stale_count: number;
  billing_over_90: number;
  billing_over_90_amount: number | string | null;
  billing_oldest: string | null;
  reports_due: number;
  reports_sent: number;
  reports_overdue: number;
  reports_oldest_unsent: string | null;
};

/** Whole days between a moment and now, for "four days ago". */
export function daysSince(at: string | null, now: Date = new Date()): number | null {
  if (!at) return null;
  const then = new Date(at);
  if (Number.isNaN(then.getTime())) return null;
  return Math.floor((now.getTime() - then.getTime()) / 86400000);
}

/** "4 days ago", "yesterday", "today". */
function ago(days: number): string {
  if (days <= 0) return "today";
  if (days === 1) return "yesterday";
  return `${days} days ago`;
}

const money = (n: number | string | null): string => {
  const v = Number(n ?? 0);
  return `$${v.toLocaleString("en-US", { maximumFractionDigits: 0 })}`;
};

/**
 * The verification suite's line.
 *
 * Three states and they are genuinely different: it passed, it failed, or
 * nobody has run it. The third is the one worth getting right - an email that
 * said nothing would leave somebody assuming the first.
 */
export function verifyLine(h: Health, now?: Date): string {
  const days = daysSince(h.verify_at, now);
  if (days === null) {
    return "Verification suite: never run, or the run was not recorded. Run `node --env-file=.env.local scripts/verify-all.mjs`.";
  }
  if (h.verify_ok === false) {
    return `Verification suite: FAILING as of ${ago(days)} — ${h.verify_detail || "no detail recorded"}.`;
  }
  const stale = days >= 7 ? " That is over a week; run it again." : "";
  return `Verification suite: passed ${ago(days)} — ${h.verify_detail || "no detail recorded"}.${stale}`;
}

/** The backup fingerprint's line, by the same three states. */
export function backupLine(h: Health, now?: Date): string {
  const days = daysSince(h.backup_at, now);
  if (days === null) {
    return "Backup fingerprint: never taken, or the run was not recorded. Run `node --env-file=.env.local scripts/backup-fingerprint.mjs`.";
  }
  if (h.backup_ok === false) {
    return `Backup fingerprint: the last restore check FAILED ${ago(days)} — ${h.backup_detail || "no detail recorded"}.`;
  }
  const stale = days >= 30 ? " That is over a month; take another." : "";
    // A colon rather than a dash, because the detail has a dash of its own and
  // two in one sentence reads as a mistake.
  return `Backup fingerprint: taken ${ago(days)}: ${h.backup_detail || "no detail recorded"}.${stale}`;
}

export function graphLine(h: Health): string {
  if (h.graph_total === 0) {
    return "Microsoft 365: no mailbox subscriptions, so nothing is arriving by itself. Reconnect from the dashboard.";
  }
  const parts = [`Microsoft 365: ${h.graph_total} mailbox subscription${h.graph_total === 1 ? "" : "s"}`];
  if (h.graph_soonest) {
    parts.push(`the soonest expires ${h.graph_soonest.slice(0, 10)}`);
  }
  if (h.graph_expiring > 0) {
    parts.push(`${h.graph_expiring} expire inside three days and the renewer has not taken them`);
  }
  if (h.graph_failing > 0) {
    parts.push(`${h.graph_failing} last reported an error`);
  }
  return parts.join(", ") + ".";
}

export function billingLine(h: Health): string {
  const stale =
    h.stale_count === 0
      ? "nothing in the Stale view"
      : `${h.stale_count} in the Stale view, past saving and waiting to be closed`;
  const old =
    h.billing_over_90 === 0
      ? "nothing submitted over 90 days ago and unpaid"
      : `${h.billing_over_90} submitted over 90 days ago and unpaid, ${money(h.billing_over_90_amount)}`;
  const oldest = h.billing_oldest ? ` Oldest unpaid submission: ${h.billing_oldest}.` : "";
  return `Billing: ${stale}; ${old}.${oldest}`;
}

export function reportsLine(h: Health): string {
  const overdue =
    h.reports_overdue === 0
      ? "none overdue"
      : `${h.reports_overdue} overdue`;
  const oldest = h.reports_oldest_unsent
    ? ` Oldest not sent covers ${h.reports_oldest_unsent.slice(0, 7)}.`
    : "";
  return `Reports: ${h.reports_due} waiting to go, ${h.reports_sent} sent, ${overdue}.${oldest}`;
}

/**
 * The whole email.
 *
 * The subject says whether anything needs doing, because a subject that reads
 * the same every week is a subject nobody reads. What counts as needing doing
 * is narrow on purpose: a failing verify run, a failing restore check, a
 * subscription about to lapse, money over ninety days old, or an overdue
 * report. A full Stale view is not an alarm - it is a list of things to close
 * when somebody has an afternoon.
 */
export function healthEmail(h: Health, on: string, now?: Date): { subject: string; body: string } {
  const verifyDays = daysSince(h.verify_at, now);
  const needs: string[] = [];
  // One item about the suite, not two. A failing run that is also nine days
  // old is one thing to look at and reporting it twice makes the list read as
  // longer than it is.
  if (h.verify_ok === false) needs.push("the verify suite is failing");
  else if (verifyDays === null) needs.push("nothing has run the verify suite");
  else if (verifyDays >= 7) needs.push("the verify suite is over a week old");
  // The same three states as the suite, and the same rule: one item each.
  const backupDays = daysSince(h.backup_at, now);
  if (h.backup_ok === false) needs.push("the last restore check failed");
  else if (backupDays === null) needs.push("no backup fingerprint has ever been taken");
  else if (backupDays >= 30) needs.push("the backup fingerprint is over a month old");
  if (h.graph_total === 0) needs.push("no mailbox is connected");
  if (h.graph_expiring > 0) needs.push("a mailbox subscription is about to lapse");
  if (h.billing_over_90 > 0) needs.push("money is over 90 days old");
  if (h.reports_overdue > 0) needs.push("a report is overdue");

  // One thing wrong is named in the subject; several are counted. A subject
  // that only ever said "1 thing to look at" would make the commonest case -
  // the verify suite failing, which is the line that matters most - look the
  // same as a fingerprint nobody has taken for a month.
  const subject =
    needs.length === 0
      ? `Monday health — all clear (${on})`
      : needs.length === 1
        ? `Monday health — ${needs[0]} (${on})`
        : `Monday health — ${needs.length} things to look at (${on})`;

  const body = [
    needs.length === 0
      ? "Nothing needs doing. The detail is below."
      : `To look at: ${needs.join("; ")}.`,
    "",
    verifyLine(h, now),
    backupLine(h, now),
    graphLine(h),
    billingLine(h),
    reportsLine(h),
  ].join("\n");

  return { subject, body };
}
