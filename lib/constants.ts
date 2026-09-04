/** Shared vocabulary, ported from the prototype. */

export const STAGES = [
  "Referral",
  "Intake",
  "Assessment",
  "Job Development",
  "Placement",
  "Job Coaching",
  "Follow-Along",
  "Closed",
] as const;

export const CLIENT_STATUSES = ["Active", "On hold", "Closed"] as const;

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

export const FUNDING_SOURCES = ["Utah VR", "HCBS Medicaid", "Private Pay", "Other"] as const;

/** Who may edit client records and pipeline. Matches the prototype's canEditClients. */
export const CAN_EDIT_CLIENTS = ["Admin", "Job Search", "Reports"];

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
export function today(): string {
  const d = new Date();
  return new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 10);
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

/** Rate defaults from the CRP schedule, used to pre-fill a new authorization. */
export const SERVICE_DEFAULTS: Record<string, { rate: number; rateType: "Hourly" | "Flat Fee" }> = {
  "Job Coaching": { rate: 45, rateType: "Hourly" },
  "Job Development": { rate: 560, rateType: "Flat Fee" },
  "Job Development + HQ Indicator": { rate: 560, rateType: "Flat Fee" },
  "Job Placement": { rate: 2250, rateType: "Flat Fee" },
  "Job Placement (SE)": { rate: 3375, rateType: "Flat Fee" },
  "WSA Tier 1": { rate: 270, rateType: "Flat Fee" },
  "WSA Tier 2": { rate: 585, rateType: "Flat Fee" },
  "HQ Indicator": { rate: 560, rateType: "Flat Fee" },
  "Temporary Work Experience": { rate: 500, rateType: "Flat Fee" },
  "Life Skills": { rate: 45, rateType: "Hourly" },
  "CRP Group Training": { rate: 17, rateType: "Hourly" },
};

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
export const CAN_LOG_HOURS = ["Admin", "Billing", "Job Search"];

/** Median, rounded. Null for an empty set — never 0, which would read as a real figure. */
export function median(values: number[]): number | null {
  if (values.length === 0) return null;
  const a = [...values].sort((x, y) => x - y);
  const m = Math.floor(a.length / 2);
  return a.length % 2 ? a[m] : Math.round((a[m - 1] + a[m]) / 2);
}

/** Stages that mean a client reached job development or beyond. */
export const POST_JD_STAGES = ["Job Development", "Placement", "Job Coaching", "Follow-Along"];
