import { CAN_EDIT_CLIENTS, CAN_LOG_HOURS } from "./constants.ts";

/**
 * What the "+" in the header offers.
 *
 * Kept out of the actions file so the modal can read the labels — a "use
 * server" module may only export async functions.
 */
export const QUICK_KINDS = [
  { key: "note", label: "Note", hint: "A call, a visit, something said" },
  { key: "task", label: "Task", hint: "Something to do, with a date" },
  { key: "job", label: "Job", hint: "A position this client has gone for" },
  { key: "interview", label: "Interview", hint: "A date on a job already added" },
  { key: "placement", label: "Placement", hint: "They started work" },
  { key: "session", label: "Work session", hint: "Hours you worked" },
  /**
   * The two billing actions, and only these two (§13.14).
   *
   * "Log hours" is billable time against an authorization, which is a
   * different thing from the work session above: a session is what somebody
   * did with their day, and these are the hours the practice bills for. Both
   * are offered because both get logged, and conflating them is how a month of
   * coaching ends up as nobody's billable time.
   *
   * There is no invoice here, and there never will be: §10 leaves one way to
   * create a bill, which is entering an authorization.
   */
  { key: "hours", label: "Log hours", hint: "Billable hours against an authorization" },
  { key: "authorization", label: "Add authorization", hint: "Read off the PDF USOR sent" },
] as const;

export type QuickKind = (typeof QUICK_KINDS)[number]["key"];

/** Which kinds this person may use, in the order above. */
export function kindsForRole(role: string): QuickKind[] {
  const canEdit = CAN_EDIT_CLIENTS.includes(role);
  // Billing's own: entering an authorization is Admin's and Billing's, and
  // logging billable hours is theirs plus whoever does the work.
  const canBill = role === "Admin" || role === "Billing";
  const canLogHours = canBill || CAN_LOG_HOURS.includes(role);
  return QUICK_KINDS.filter((k) => {
    if (k.key === "session") return true;
    if (k.key === "hours") return canLogHours;
    if (k.key === "authorization") return canBill;
    return canEdit;
  }).map((k) => k.key);
}
