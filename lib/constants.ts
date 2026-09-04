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

export function today(): string {
  return new Date().toISOString().slice(0, 10);
}
