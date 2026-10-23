/** Shared vocabulary, ported from the prototype. */

/**
 * The seven columns of the clients board, in the order the work happens
 * (owner, 22 Oct 2026). Referral became Intake, Placement became Job
 * Placement, Follow-Along became Job Coaching, and Closed stopped being a
 * stage at all - a client who is finished has a status, not a column. 0223
 * remapped every row and the constraint enforces it.
 */
export const STAGES = [
  "Intake",
  "Assessment",
  "Job Development",
  "Job Search",
  "Life Skills",
  "Job Placement",
  "Job Coaching",
] as const;

/** What each column is for, in the one line its header carries. */
export const STAGE_NOTE: Record<(typeof STAGES)[number], string> = {
  Intake: "Referred, not yet assessed",
  Assessment: "The WSA, and what it says",
  "Job Development": "Finding employers",
  "Job Search": "Applying and interviewing",
  "Life Skills": "Skills the work needs",
  "Job Placement": "Hired; the fee to claim",
  "Job Coaching": "Supported on the job",
};

/** The header says "Assessment (WSA)"; the stored value stays "Assessment". */
export const STAGE_LABEL: Partial<Record<(typeof STAGES)[number], string>> = {
  Assessment: "Assessment (WSA)",
};

/**
 * What a column is called on screen, for a stage that arrives as a string.
 *
 * The board reads stages out of the database, where they are text, so every
 * lookup into the three maps above had to be widened or cast. One helper
 * each instead, and the cast is in one place where it can be wrong once.
 */
export function stageLabel(stage: string): string {
  return STAGE_LABEL[stage as (typeof STAGES)[number]] ?? stage;
}

export function stageNote(stage: string): string {
  return STAGE_NOTE[stage as (typeof STAGES)[number]] ?? "";
}

export function stageToken(stage: string): string {
  return STAGE_TOKEN[stage as (typeof STAGES)[number]] ?? "--line-strong";
}

/** The token carrying each column's accent (0223, app/tokens.css). */
export const STAGE_TOKEN: Record<(typeof STAGES)[number], string> = {
  Intake: "--stage-intake",
  Assessment: "--stage-assessment",
  "Job Development": "--stage-job-development",
  "Job Search": "--stage-job-search",
  "Life Skills": "--stage-life-skills",
  "Job Placement": "--stage-job-placement",
  "Job Coaching": "--stage-job-coaching",
};

export const CLIENT_STATUSES = ["Active", "On hold", "Inactive", "Closed"] as const;

export const NOTE_TYPES = [
  "General",
  "Phone call",
  "Meeting",
  "Job search",
  "Application submitted",
  "Interview",
  "Employer contact",
  "Coaching session",
  "Counselor contact",
  "No-show / not responding",
] as const;

// No "HCBS Medicaid": the CRM is the USOR side of a hybrid entity, and waiver
// clients' records live in CareSmartz360 (0226).
export const FUNDING_SOURCES = ["Utah VR", "Private Pay", "Other"] as const;

/** Who may edit client records and pipeline. Matches the prototype's canEditClients. */
export const CAN_EDIT_CLIENTS = ["Admin", "Job Search", "Reports", "Job Coach", "Case Manager"];

/** Who may edit authorizations, the service log and invoices. canEditBilling. */
export const CAN_EDIT_BILLING = ["Admin", "Billing"];

/** Formats a timestamp the way the prototype's fmtStamp does. */
export function fmtStamp(iso: string | null): string {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  return d.toLocaleString(undefined, {
    month: "short",
    day: "numeric",
    year: "numeric",
    hour: "numeric",
    minute: "2-digit",
  });
}

/**
 * Today's date in the viewer's own timezone.
 *
 * Not `toISOString()`, which gives the UTC date: after 6pm in Utah that is
 * already tomorrow. A job coach logging an evening visit would have had the
 * date default to the following day — quietly wrong in a system whose rule is
 * "log hours on the day the service happened", and wrong in a way that
 * survives into USOR billing.
 *
 * The database's own guard still uses current_date (UTC), which is never
 * behind the local date in Utah, so a local date is always accepted.
 */
/**
 * Where the practice is.
 *
 * Every date in this system means a day in Utah — the day a visit happened,
 * the day an invoice was raised, the day somebody was hired. None of them mean
 * a day in UTC, which is where the server thinks it lives.
 */
export const PRACTICE_TZ = "America/Denver";

/**
 * Today, in Utah.
 *
 * This used to read the server clock. On a laptop in Salt Lake City that was
 * right; on Vercel, where the server is UTC, every date stamped between six in
 * the evening and midnight landed on tomorrow. Hours logged after supper were
 * dated the next day, and so were the tasks raised beside them.
 */
export function today(): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: PRACTICE_TZ,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(new Date());
}

/**
 * Whether a date is one somebody meant.
 *
 * `/^\d{4}-\d{2}-\d{2}$/` was the whole of date validation in several places,
 * and it accepts 0226-03-14 and 9999-12-31. A slipped year is the commonest
 * typing mistake there is on a date field, and in this system it is not
 * cosmetic: an authorization dated backwards is reported expired for ever and
 * raises an alert nobody can clear, and one dated forwards never falls due
 * and is never billed, with nothing to say so (stress test finding 8).
 *
 * The same window the database holds (0210): not before 1990, not more than
 * five years ahead. The database is where the rule really lives, because the
 * intake cron and the filing rules read dates off documents rather than off a
 * form — this is so a person gets a sentence instead of a database error.
 */
export const DATE_FLOOR = "1990-01-01";

export function dateCeiling(): string {
  const d = new Date(`${today()}T00:00:00`);
  d.setFullYear(d.getFullYear() + 5);
  return d.toISOString().slice(0, 10);
}

/** The complaint, or null when the date is fine. Blank is fine; absent is not wrong. */
export function dateComplaint(value: string, what = "That date"): string | null {
  if (!value) return null;
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return `${what} does not look right.`;
  if (value < DATE_FLOOR || value > dateCeiling()) {
    return `${what} is ${value}. A date here is between ${DATE_FLOOR} and ${dateCeiling()} — check the year.`;
  }
  return null;
}

/** Currency, matching the prototype's money(). */
export function money(n: number | null | undefined): string {
  return (
    "$" +
    Number(n ?? 0).toLocaleString(undefined, {
      minimumFractionDigits: 2,
      maximumFractionDigits: 2,
    })
  );
}

export function daysBetween(a: string, b: string): number {
  return Math.round((new Date(b).getTime() - new Date(a).getTime()) / 86400000);
}

/** Monday-to-Sunday week, or calendar month, containing the anchor date. */
export function periodRange(kind: "Weekly" | "Monthly", anchor: string): [string, string] {
  const d = new Date(anchor + "T00:00:00");
  if (kind === "Weekly") {
    const dow = (d.getDay() + 6) % 7;
    const start = new Date(d);
    start.setDate(d.getDate() - dow);
    const end = new Date(start);
    end.setDate(start.getDate() + 6);
    return [start.toISOString().slice(0, 10), end.toISOString().slice(0, 10)];
  }
  const start = anchor.slice(0, 7) + "-01";
  const end = new Date(d.getFullYear(), d.getMonth() + 1, 0);
  return [start, end.toISOString().slice(0, 10)];
}

/** USOR 95 job-coaching service codes, verbatim from the form. */
export const COACHING_CODES = [
  "1. Attend employer training (client and job coach)",
  "2. Meet with worksite sups and natural supports",
  "3. Review, train, teach essential job duties with client",
  "4. Provide individualized training for learning job tasks",
  "5. Perform onsite follow-up checks with client",
  "6. Provide direct interventions on the job",
  "7. Identify and set up accommodations (employer & VR)",
  "8. Build and coordinate natural supports for continued work success",
  "9. Shadow and observe client while on worksite",
  "10. Develop and implement support plan after job coach fades",
  "11. Develop work culture skills (breaks, sick days, etc.)",
  "12. Develop work conditioning and hardening",
  "13. Provide support and encouragement",
  "14. Provide *Other Support (approved in advance by VR)",
  "15. Provide transportation training",
] as const;

export const SERVICE_TYPES = [
  "Job Coaching",
  "Job Development",
  "Job Development + HQ Indicator",
  "Job Placement",
  "Job Placement (SE)",
  "WSA Tier 1",
  "WSA Tier 2",
  "HQ Indicator",
  "Temporary Work Experience",
  "Life Skills",
  "CRP Group Training",
  "Job Readiness",
  "Supported Employment",
  "Follow-Along",
  "Other",
] as const;

/**
 * The short code a service goes by in conversation and on a worksheet.
 *
 * The owner's layout (20 Sept 2026) prefixes every authorization with it, so
 * a list of four reads at a glance instead of being four long phrases that
 * begin with the same word. The full service name is still shown beside it -
 * the code is a handle, not a replacement.
 */
export const SERVICE_CODE: Record<string, string> = {
  "Job Coaching": "JC",
  "Job Development": "JD",
  "Job Development + HQ Indicator": "JD+HQ",
  "Job Placement": "JP",
  "Job Placement (SE)": "JP-SE",
  "WSA Tier 1": "WSA1",
  "WSA Tier 2": "WSA2",
  "HQ Indicator": "HQ",
  "Temporary Work Experience": "TWE",
  "Life Skills": "LS",
  "CRP Group Training": "CGT",
  "Job Readiness": "JR",
  "Supported Employment": "SE",
  "Follow-Along": "FA",
  Other: "—",
};

export const serviceCode = (service: string): string =>
  SERVICE_CODE[service] ?? service.slice(0, 3).toUpperCase();

/** Rate defaults from the CRP schedule, used to pre-fill a new authorization. */
/*
 * SERVICE_DEFAULTS was here: a hard-coded copy of the rate schedule, in the
 * CRM's service names rather than the workbook's. It said Job Development + HQ
 * Indicator was 560; the schedule says 1,120, and the practice has billed it
 * at 1,120 twelve times. Two copies of a price is one too many (§11), and the
 * copy that was wrong was the one the form filled in.
 *
 * Rates come from public.rate_schedule, through service_rate() (§13.13).
 */

/** Accounts-receivable ageing, as the prototype buckets it. */
export function arBuckets(
  invoices: { status: string; date: string; amount: number }[],
): Record<"0-30" | "31-60" | "61-90" | "90+" | "total", number> {
  const b = { "0-30": 0, "31-60": 0, "61-90": 0, "90+": 0, total: 0 };
  for (const i of invoices) {
    if (i.status !== "Sent") continue;
    const d = daysBetween(i.date, today());
    const k = d < 31 ? "0-30" : d < 61 ? "31-60" : d < 91 ? "61-90" : "90+";
    b[k] += Number(i.amount);
    b.total += Number(i.amount);
  }
  return b;
}

/**
 * Who may log service hours. Wider than CAN_EDIT_BILLING: job coaches log
 * their own hours, per the "Logging service hours" SOP, confirmed by the owner.
 */
export const CAN_LOG_HOURS = ["Admin", "Billing", "Job Search", "Job Coach"];

/**
 * Which authorizations a Job Coach may log hours against.
 *
 * The role is "Job Search permissions plus logging billable hours on coaching
 * authorizations" (Intake Automation Brief), and the second half is the point
 * of it - so it is a filter on the authorization rather than an unqualified
 * yes. Everybody else who may log hours may log them against anything.
 */
export const COACHING_SERVICES = ["Job Coaching"];
export const isCoachingService = (service: string | null | undefined) =>
  COACHING_SERVICES.some((s) => (service ?? "").startsWith(s));

/** Median, rounded. Null for an empty set — never 0, which would read as a real figure. */
export function median(values: number[]): number | null {
  if (values.length === 0) return null;
  const a = [...values].sort((x, y) => x - y);
  const m = Math.floor(a.length / 2);
  return a.length % 2 ? a[m] : Math.round((a[m - 1] + a[m]) / 2);
}

/** Stages that mean a client reached job development or beyond. */
export const POST_JD_STAGES = ["Job Development", "Job Search", "Job Placement", "Job Coaching"];

/**
 * The steps a job goes through, in Margaret's words and in order.
 *
 * One list, because the same names appear on the leads board, on the client's
 * job tracker, in a database constraint and in the trigger that writes the
 * note. Renaming them in Phase 7 left four copies disagreeing, and the board
 * would have hit the constraint the next time somebody used it.
 */
export const JOB_STATUSES = [
  "Saved",
  "Applied",
  "Follow-up",
  "Interview",
  "Offer",
  "Hired",
  "Not selected",
  // The client stepped away - declined an offer, backed out (0117).
  "Withdrawn",
] as const;

/** A job that is over, one way or the other. */
export const JOB_DONE = ["Hired", "Not selected", "Withdrawn"] as const;

/** How an interview happens, whether the client said they will go, and what came of it (0117). */
export const INTERVIEW_KINDS = ["In person", "Video", "Phone"] as const;
export const INTERVIEW_CONFIRMED = ["Confirmed", "Unconfirmed"] as const;
export const INTERVIEW_RESULTS = ["Done", "Rescheduled", "Cancelled", "Backed out", "No-show", "Unscheduled"] as const;

export type JobStatus = (typeof JOB_STATUSES)[number];

/** Where an opening is, on the Jobs screen. Server and client both read it. */
export const LEAD_STATUSES = ["Open", "Submitted", "Interviewing", "Filled", "Closed"] as const;

/** Where a job has got to, for a chip: good, over, or still going. */
export function jobStatusTone(status: string): "ok" | "warn" | "" {
  if (status === "Hired") return "ok";
  if (status === "Not selected" || status === "Withdrawn") return "";
  return "warn";
}

/**
 * A pay rate, written the way it was agreed.
 *
 * Shared rather than written twice, because the obvious way to format money is
 * two decimals — and two decimals is what turned an agreed 5.625 an hour into
 * 5.63 on somebody's record. A second screen showing rates was the likeliest
 * place for that to come back.
 */
export function formatPayRate(rate: number, unit: string): string {
  const amount = Number(rate).toLocaleString("en-US", {
    style: "currency",
    currency: "USD",
    minimumFractionDigits: 2,
    maximumFractionDigits: 4,
  });
  return unit === "Hourly" ? `${amount} an hour` : `${amount} flat`;
}

/**
 * How long ago, in words, for a sync time (0240).
 *
 * The question somebody asks of a sync time is never "when" - it is "is this
 * current". "4 minutes ago" answers that and a timestamp does not. Over a day
 * old it stops being reassuring and becomes a thing to look into, so it says
 * the day instead and lets the reader decide.
 */
export function fmtAgo(iso: string | null): string {
  if (!iso) return "never";
  const then = new Date(iso).getTime();
  if (Number.isNaN(then)) return "never";
  const seconds = Math.round((Date.now() - then) / 1000);
  if (seconds < 90) return "just now";
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `${minutes} minutes ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return hours === 1 ? "an hour ago" : `${hours} hours ago`;
  return fmtStamp(iso);
}
