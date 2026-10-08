"use server";

import { revalidatePath } from "next/cache";
import { requireStaff } from "@/lib/session";
import { can } from "@/lib/roles";
import { createClient } from "@/lib/supabase/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { sendEmail, type Attachment } from "@/lib/email";
import { today } from "@/lib/constants";

/**
 * What can be done to an authorization (Billing Simplification Brief §§4, 12.4).
 *
 * There are five moves and no way to type a status. Submit is what sending the
 * packet does; Paid is what a warrant does; the rest are a decision somebody
 * made and had to give a reason for. A status that can be typed is a status
 * that stops meaning anything.
 *
 * Every refusal in here is the database's. The checklist on the record says in
 * advance what the trigger would say after - they read the same tests - so a
 * person should never meet one of these errors by surprise. When they do, the
 * message is the database's own, because it knows which of the dates is wrong
 * and this file does not.
 */

export type ActionState = { error: string | null; ok: string | null };

async function billingHands() {
  const me = await requireStaff();
  if (!can(me, "billing", "edit")) throw new Error("Billing edits are Billing's, or an Admin's.");
  return { me, supabase: await createClient() };
}

const done = (authId: string, clientId?: string) => {
  revalidatePath(`/billing/authorizations/${authId}`);
  revalidatePath("/billing");
  if (clientId) revalidatePath(`/clients/${clientId}`);
};

/** The database's message, which names the field, rather than ours, which cannot. */
const refusal = (message: string) => ({ error: message.replace(/^.*?:\s*/, "").trim() || message, ok: null });

/** Ready to bill. The bill-by date and the checklist decide when, not this. */
export async function markDue(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const { supabase } = await billingHands();
  const id = String(formData.get("auth_id") ?? "");
  const { error } = await supabase.from("authorizations").update({ status: "Due" }).eq("id", id);
  if (error) return refusal(error.message);
  done(id);
  return { error: null, ok: "Ready to bill." };
}

/**
 * Submit sends (§12.4).
 *
 * One action: the packet goes to the billing office, the counselor is copied,
 * the status becomes Submitted, the follow-up clock starts and the contact log
 * gets a line. There is no separate "mark submitted", because the two drifting
 * apart is how an authorization comes to say it was sent on a day nothing left
 * the building.
 *
 * The order matters. The email goes first and the status moves only if Resend
 * accepted it: an authorization that says Submitted when nothing was sent is
 * worse than one that says Due when something was. If the status change is
 * then refused, the person is told the packet went but the record did not
 * move - which is recoverable, and silence would not be.
 *
 * The addresses come from the record, never from the form. The packet is
 * whatever is attached to this authorization, by reference (§11) - the signed
 * authorization and the signed USOR forms. No copy is made anywhere.
 */
export async function submitAuthorization(
  _prev: ActionState,
  formData: FormData,
): Promise<ActionState> {
  const { me, supabase } = await billingHands();
  const id = String(formData.get("auth_id") ?? "");

  const { data: rec } = await supabase
    .from("authorization_record")
    // One literal, not a concatenation: the generated types read the column
    // list out of the string itself, and a `+` turns the whole row into a
    // guess.
    .select(
      "id, client_id, client_name, number, service_type, period, status, amount, rate_type, hours_logged, service_start, service_end, billing_office_email, billing_office_name, counselor_name, counselor_email, can_submit, missing_forms",
    )
    .eq("id", id)
    .maybeSingle();

  if (!rec) return { error: "That authorization is not there any more.", ok: null };
  if (rec.status === "Submitted") return { error: null, ok: "It had already been submitted." };
  if (!rec.can_submit) {
    return {
      error: "The checklist on this record says it cannot be submitted yet. The lines marked “stops this” say why.",
      ok: null,
    };
  }
  if (!rec.billing_office_email) {
    return {
      error: `There is no billing office address for ${rec.client_name}. It comes from the counselor's office, on the client's record.`,
      ok: null,
    };
  }

  // The packet: what is attached to this authorization, sent as bytes so
  // nobody at USOR has to sign in to anything to read it.
  const { data: files } = await supabase
    .from("attachments")
    .select("filename, storage_path, category")
    .eq("auth_id", id)
    .in("category", ["Authorization", "Signed USOR form"]);

  const admin = createAdminClient();
  const attachments: Attachment[] = [];
  for (const f of files ?? []) {
    const { data: blob } = await admin.storage.from("client-files").download(f.storage_path);
    if (blob) attachments.push({ filename: f.filename, bytes: new Uint8Array(await blob.arrayBuffer()) });
  }
  if (attachments.length === 0) {
    return {
      error: "There is nothing attached to send. Attach the signed authorization and the signed forms first.",
      ok: null,
    };
  }

  const period = rec.period
    ? new Date(`${rec.period}T00:00:00`).toLocaleDateString("en-US", { month: "long", year: "numeric" })
    : [rec.service_start, rec.service_end].filter(Boolean).join(" to ");
  const amount = Number(rec.amount ?? 0).toLocaleString("en-US", { style: "currency", currency: "USD" });

  const subject = `${rec.client_name} — ${rec.service_type}${period ? ` — ${period}` : ""} — authorization ${rec.number || "(no number)"}`;
  const text = [
    `Billing for ${rec.client_name}.`,
    "",
    `Authorization: ${rec.number || "(no number)"}`,
    `Service: ${rec.service_type}`,
    period ? `Period: ${period}` : null,
    rec.rate_type === "Hourly" ? `Hours: ${Number(rec.hours_logged ?? 0)}` : null,
    `Amount: ${amount}`,
    "",
    `Attached: ${(files ?? []).map((f) => f.filename).join(", ")}`,
    "",
    "Zion Vocational Rehabilitation",
  ]
    .filter((l) => l !== null)
    .join("\n");

  // The counselor is copied, unless they are the billing office - the
  // same-person rule, so nobody gets the same packet twice.
  const to = rec.billing_office_email;
  const cc =
    rec.counselor_email && rec.counselor_email.toLowerCase() !== to.toLowerCase()
      ? [rec.counselor_email]
      : [];

  const sent = await sendEmail({ to, cc, subject, text, attachments });
  if (!sent.ok) return { error: `Nothing was sent, so nothing was marked submitted. ${sent.error}`, ok: null };

  const { error } = await supabase.from("authorizations").update({ status: "Submitted" }).eq("id", id);

  await supabase.from("contact_log").insert({
    client_id: rec.client_id,
    date: today(),
    method: "Billing submitted",
    topic: `${rec.service_type}${period ? ` (${period})` : ""} — authorization ${rec.number || "(no number)"}`,
    outcome: `Packet emailed to ${to}${cc.length ? `, copy to ${cc[0]}` : ""} — ${amount}`,
    staff_id: me.id,
  });

  done(id, rec.client_id ?? undefined);

  if (error) {
    return {
      error: `The packet went to ${to}, but the record would not move to Submitted: ${error.message}`,
      ok: null,
    };
  }
  return {
    error: null,
    ok: `Sent to ${to}${cc.length ? `, copied to ${cc[0]}` : ""}. Payment is expected within 14 days; it will be chased after that.`,
  };
}

/** A month with nothing in it, or work that was never done: closed, with a reason. */
export async function closeAuthorization(
  _prev: ActionState,
  formData: FormData,
): Promise<ActionState> {
  const { supabase } = await billingHands();
  const id = String(formData.get("auth_id") ?? "");
  const reason = String(formData.get("closed_reason") ?? "").trim();
  if (!reason) return { error: "Say why it is being closed. Somebody will ask.", ok: null };

  const { error } = await supabase
    .from("authorizations")
    .update({ status: "Closed", closed_reason: reason })
    .eq("id", id);
  if (error) return refusal(error.message);
  done(id);
  return { error: null, ok: "Closed, with the reason on the record." };
}

/**
 * Moving the date an authorization goes stale (§2).
 *
 * The reason is required by the database at the moment the date moves, not
 * asked for afterwards. This only passes it along.
 */
export async function moveStaleDate(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const { supabase } = await billingHands();
  const id = String(formData.get("auth_id") ?? "");
  const date = String(formData.get("stale_date") ?? "").trim();
  const reason = String(formData.get("stale_reason") ?? "").trim();
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) return { error: "That date does not look right.", ok: null };
  if (!reason) return { error: "Say why the date is moving.", ok: null };

  const { error } = await supabase
    .from("authorizations")
    .update({ stale_date: date, stale_reason: reason })
    .eq("id", id);
  if (error) return refusal(error.message);
  done(id);
  return { error: null, ok: "Moved, and the reason is on the record." };
}

/** When the work happened, which is not the same as when it was authorized (§4). */
export async function recordServiceDates(
  _prev: ActionState,
  formData: FormData,
): Promise<ActionState> {
  const { supabase } = await billingHands();
  const id = String(formData.get("auth_id") ?? "");
  const start = String(formData.get("service_start") ?? "").trim();
  const end = String(formData.get("service_end") ?? "").trim();
  if (!start) return { error: "When did the work start?", ok: null };

  const { error } = await supabase
    .from("authorizations")
    .update({ service_start: start, service_end: end || null })
    .eq("id", id);
  if (error) return refusal(error.message);
  done(id);
  return { error: null, ok: "Recorded." };
}

/**
 * A coaching month with no hours logged (§13.8).
 *
 * Far more often this is a month whose hours were never logged than a month
 * with no service, which is why it asks rather than closing quietly. The
 * nightly sweep closes the ones nobody answers.
 */
export async function resolveZeroHours(
  _prev: ActionState,
  formData: FormData,
): Promise<ActionState> {
  const { me, supabase } = await billingHands();
  const id = String(formData.get("auth_id") ?? "");
  const answer = String(formData.get("answer") ?? "");

  if (answer === "no service") {
    const { error } = await supabase
      .from("authorizations")
      .update({ status: "Closed", closed_reason: "No service provided this month" })
      .eq("id", id);
    if (error) return refusal(error.message);
    done(id);
    return { error: null, ok: "Closed: no service this month." };
  }

  const { error } = await supabase
    .from("authorizations")
    .update({ zero_hours_confirmed_by: me.id, zero_hours_confirmed_at: new Date().toISOString() })
    .eq("id", id);
  if (error) return refusal(error.message);
  done(id);
  return { error: null, ok: "Noted. Log the hours and it will price itself." };
}
