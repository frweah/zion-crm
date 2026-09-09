import { CAN_EDIT_CLIENTS } from "./constants.ts";

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
] as const;

export type QuickKind = (typeof QUICK_KINDS)[number]["key"];

/** Which kinds this person may use, in the order above. */
export function kindsForRole(role: string): QuickKind[] {
  const canEdit = CAN_EDIT_CLIENTS.includes(role);
  return QUICK_KINDS.filter((k) =>
    k.key === "session" ? true : canEdit,
  ).map((k) => k.key);
}
