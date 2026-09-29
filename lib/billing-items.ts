/**
 * The billing item, as every screen says it (0123/0124).
 *
 * The statuses are the practice's, in the order Margaret reads them, and the
 * database holds the same list: if one is added here and not there, an item
 * simply refuses to take it, which is the right way round.
 *
 * Deliberately no "Approved": USOR's first answer is the warrant, so Paid
 * follows Pending (owner, 29 Sept 2026). "Closed" is not the end of the road
 * either - Paid is - which is why it sits apart from the run of statuses.
 */
export const ITEM_STATUSES = [
  "Referral received",
  "Authorization received",
  "Service in progress",
  "Service period complete",
  "Ready for billing",
  "Billing review",
  "Submitted",
  "Pending",
  "Correction needed",
  "Paid",
] as const;

export type ItemStatus = (typeof ITEM_STATUSES)[number] | "Closed";

/** Closed is reached from anywhere, with a reason, and is not part of the run. */
export const CLOSED: ItemStatus = "Closed";

/**
 * What each status means to somebody reading a list of them. Shown under the
 * count on the overview, so nobody has to remember whose turn it is.
 */
export const STATUS_MEANING: Record<string, string> = {
  "Referral received": "the referral is in, nothing is authorized yet",
  "Authorization received": "approved for the service, not started",
  "Service in progress": "being worked now",
  "Service period complete": "the work is finished; not yet checked",
  "Ready for billing": "checked, waiting to be reviewed",
  "Billing review": "on the checklist now",
  Submitted: "sent to the billing office",
  Pending: "sent, waiting on USOR",
  "Correction needed": "came back; something has to change",
  Paid: "the warrant arrived",
  Closed: "ended without payment, with a reason",
};

/** The statuses that mean somebody here still has to do something. */
export const OURS = [
  "Referral received",
  "Authorization received",
  "Service in progress",
  "Service period complete",
  "Ready for billing",
  "Billing review",
  "Correction needed",
] as const;

/** Sent, and waiting on somebody else. */
export const THEIRS = ["Submitted", "Pending"] as const;

export type ItemRow = {
  id: string;
  client_id: string;
  client_name: string;
  client_no: string | null;
  service: string;
  period: string | null;
  status: string;
  auth_number: string | null;
  auth_status: string | null;
  auth_end: string | null;
  service_start: string | null;
  service_end: string | null;
  first_work_day: string | null;
  billing_type: string | null;
  usor_forms: string[] | null;
  recurrence: string | null;
  hours: number | null;
  rate: number | null;
  value: number | null;
  assigned_staff_id: string | null;
  assigned_staff: string | null;
  recipient: string | null;
  submitted_at: string | null;
  paid_on: string | null;
  paid_amount: number | null;
  followup_due: string | null;
  zero_hours_flagged: boolean;
  correction_note: string | null;
  closed_reason: string | null;
  signed: boolean;
};

/** "September 2026" for a month, or "one-off" for a service that does not recur. */
export function periodLabel(period: string | null): string {
  if (!period) return "one-off";
  const [y, m] = period.split("-");
  return `${new Date(Number(y), Number(m) - 1, 1).toLocaleString("en-US", { month: "long" })} ${y}`;
}

/** USOR 95 and 93. Empty when the service has no form of its own. */
export function formsLabel(forms: string[] | null): string {
  if (!forms || forms.length === 0) return "—";
  return `USOR ${forms.join(" + ")}`;
}
