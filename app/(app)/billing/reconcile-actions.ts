"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";
import { CAN_EDIT_BILLING, today } from "@/lib/constants";
import { parseCc, sendEmail } from "@/lib/email";
import { readBillingOffices } from "@/lib/billing-offices";
import { buildReconciliation } from "@/lib/reconcile";

export type ReconcileState = { error: string | null; ok: string | null };

/**
 * Send a reconciliation to a billing office, after the person has read it.
 *
 * The To is always the office's billing address - it is not a field on the
 * form, so it cannot be mistyped into somebody else's inbox. The CC, subject
 * and wording are the sender's to change. What is logged against each case is
 * rebuilt here, from the database, at the moment of sending.
 */
export async function sendReconciliation(_prev: ReconcileState, formData: FormData): Promise<ReconcileState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };
  if (!CAN_EDIT_BILLING.includes(me.role)) {
    return { error: "Only billing staff reconcile with a billing office.", ok: null };
  }
  if (formData.get("confirmed") !== "yes") {
    return { error: "Read the email and confirm before it is sent.", ok: null };
  }

  const subject = String(formData.get("subject") ?? "").trim();
  const body = String(formData.get("body") ?? "").trim();
  if (!subject || !body) return { error: "The email needs a subject and a message.", ok: null };

  const supabase = await createClient();
  const { byId } = await readBillingOffices(supabase);
  const bo = byId.get(String(formData.get("billing_office_id") ?? ""));
  if (!bo) return { error: "That billing office is not on file.", ok: null };

  const built = await buildReconciliation(supabase, bo, me.name);
  if (!built.ok) return { error: `The reconciliation could not be read: ${built.error}`, ok: null };
  const { recon } = built;
  if (recon.cases.length === 0) {
    return { error: `Nothing is waiting on ${bo.name}: no unpaid invoice and nothing about to lapse.`, ok: null };
  }

  const { cc, bad } = parseCc(String(formData.get("cc") ?? ""), recon.to);
  if (bad.length) {
    return { error: `These do not look like email addresses: ${bad.join(", ")}. Fix or remove them.`, ok: null };
  }

  const sent = await sendEmail({ to: recon.to, cc, subject, text: body });
  if (!sent.ok) return { error: `Not sent. ${sent.error}`, ok: null };

  // Once per case, so each client's history shows it and each counselor's
  // contacts include it; the billing office is named so its own history reads back.
  const copied = cc.length ? `, copied to ${cc.join(", ")}` : "";
  const { error: logError } = await supabase.from("contact_log").insert(
    recon.cases.map((c) => ({
      counselor_id: c.counselor_id,
      client_id: c.client_id,
      date: today(),
      method: "Email",
      topic: `Billing reconciliation with ${bo.name}`,
      outcome: `Emailed to ${recon.to}${copied}. Listed: ${c.lines.join("; ")}.`,
      staff_id: me.id,
      billing_office_id: bo.id,
    })),
  );

  revalidatePath("/billing");
  revalidatePath("/counselors");

  const logged = logError
    ? ` It was sent, but the contact log could not be written (${logError.message}) - add it by hand.`
    : ` Logged on ${recon.cases.length} ${recon.cases.length === 1 ? "case" : "cases"} in the contact log.`;
  return { error: null, ok: `Sent to ${bo.name} (${recon.to})${copied}.${logged}` };
}
