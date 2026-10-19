"use server";

import { revalidatePath } from "next/cache";
import { requireStaff } from "@/lib/session";
import { EMPTY_BATCH, type BatchState } from "@/lib/billing";
import { can } from "@/lib/roles";
import { createClient } from "@/lib/supabase/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { sendEmail, type Attachment } from "@/lib/email";
import { today } from "@/lib/constants";
import { createForm } from "../../clients/[id]/forms/actions";

/**
 * What can be done to an authorization (Billing Simplification Brief §§4,
 * 12.4, and the owner's billing unlock of 14 Oct 2026).
 *
 * The first half of this file is the flow: submit is what sending the packet
 * does, and each move is a decision somebody made and had to give a reason
 * for. That was once the whole file, on the principle that a status which can
 * be typed is a status that stops meaning anything.
 *
 * The owner has overruled that, and was right to. The principle described an
 * authorization being worked now; the practice also has 139 already paid and
 * a queue of work settled months ago that the flow gave no way to say was
 * settled. So the second half of this file records payments, edits every
 * field, and clears rows in batches.
 *
 * What replaces the principle is not nothing. A status is still never a free
 * text field: Paid goes through record_payment, so there is no authorization
 * saying Paid with no payment behind it, and Closed still needs its reason.
 * A correction to the number, the hours, the rate or the amount paid is
 * refused without a reason, and written to the correction log by the database
 * rather than by this file - so it is written however the change arrives.
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

/**
 * Produce a USOR form from the record (§13.10).
 *
 * "Forms are generated, not filled." The CRM recorded the hours as they
 * happened, it knows the client, the counselor, the authorization and the
 * month - so nobody should retype a month of coaching onto USOR 95. The form
 * comes up filled in, and what staff do is read it against what they remember
 * and sign it.
 *
 * This is the same createForm the client's record uses, reached from the
 * authorization the form is for, so the two cannot produce different forms.
 * The month is the authorization's own period where it has one; a monthly form
 * on a one-off service takes this month.
 */
export async function generateForm(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const { supabase } = await billingHands();
  const id = String(formData.get("auth_id") ?? "");
  const templateId = String(formData.get("template_id") ?? "");

  const { data: rec } = await supabase
    .from("authorization_record")
    .select("id, client_id, period, service_type")
    .eq("id", id)
    .maybeSingle();
  if (!rec) return { error: "That authorization is not there any more.", ok: null };

  const month = rec.period
    ? String(rec.period).slice(0, 7)
    : new Date().toISOString().slice(0, 7);

  const body = new FormData();
  body.set("client_id", String(rec.client_id));
  body.set("template_id", templateId);
  body.set("auth_id", id);
  body.set("month", month);

  // createForm redirects to the form it made, which is where somebody reads and
  // signs it. A redirect from a server action throws, so there is nothing after
  // this line on the happy path.
  return createForm({ error: null, ok: null }, body);
}

/* ════════════════════════════════════════════════════════════
 * The unlock (owner, 14 Oct 2026)
 * ══════════════════════════════════════════════════════════ */

/**
 * Money that arrived, recorded against one authorization.
 *
 * The date defaults to today and the amount to what the authorization comes
 * to, both in the database rather than here, so the working list's bulk clear
 * and this form cannot disagree about what a default is. The warrant number is
 * optional because the common case - clearing something settled months ago -
 * is a remittance that says what arrived and when, with the stub still to
 * come. When the stub does arrive, the warrant reader recognises this payment
 * and claims it rather than paying the authorization twice (0191).
 */
export async function recordPayment(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const { supabase } = await billingHands();
  const id = String(formData.get("auth_id") ?? "");
  const received = String(formData.get("received") ?? "").trim();
  const amount = String(formData.get("amount") ?? "").trim();
  const warrant = String(formData.get("warrant") ?? "").trim();

  if (received && !/^\d{4}-\d{2}-\d{2}$/.test(received)) {
    return { error: "That date does not look right.", ok: null };
  }
  if (amount && !/^\d+(\.\d{1,2})?$/.test(amount)) {
    return { error: "That amount does not look like money.", ok: null };
  }

  const { error } = await supabase.rpc("record_payment", {
    p_auth: id,
    p_received: received || null,
    p_amount: amount ? Number(amount) : null,
    p_warrant: warrant || null,
    p_voucher: null,
  });
  if (error) return refusal(error.message);

  done(id);
  return { error: null, ok: "Recorded, and this authorization is Paid. Nothing else moved." };
}

/**
 * Every field on the record.
 *
 * The form sends what it shows and the database touches only the keys it is
 * given, so a screen that grows a field needs no change here. The reason is
 * always offered and only sometimes required - the database decides which,
 * because it is the one that knows whether the old value was empty, and
 * filling in a blank is not a correction.
 */
const EDITABLE = [
  "number",
  "service_type",
  "funding_source",
  "total_hours",
  "rate_type",
  "rate",
  "start_date",
  "end_date",
  "received_on",
  "bill_by",
  "service_start",
  "service_end",
  "recipient",
  "paid_on",
  "paid_amount",
  "warrant",
  "note",
] as const;

export async function editAuthorization(
  _prev: ActionState,
  formData: FormData,
): Promise<ActionState> {
  const { supabase } = await billingHands();
  const id = String(formData.get("auth_id") ?? "");
  const reason = String(formData.get("reason") ?? "").trim();

  const fields: Record<string, string> = {};
  for (const key of EDITABLE) {
    // Absent is not the same as empty: a field the form did not show is left
    // alone, and one it showed blank is being cleared on purpose.
    if (formData.has(key)) fields[key] = String(formData.get(key) ?? "").trim();
  }
  if (Object.keys(fields).length === 0) return { error: "Nothing was sent to change.", ok: null };

  const { data, error } = await supabase.rpc("edit_authorization", {
    p_auth: id,
    p_fields: fields,
    p_reason: reason || null,
  });
  if (error) return refusal(error.message);

  done(id);
  const changed = (data ?? []) as { field: string | null }[];
  if (changed.length === 0) return { error: null, ok: "Nothing had changed." };
  return {
    error: null,
    ok: "Saved: " + changed.map((c) => c.field).filter(Boolean).join(", ") + ".",
  };
}

/** Straight to Paid or Closed, from the record or from a row on the list. */
export async function setStatus(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const { supabase } = await billingHands();
  const id = String(formData.get("auth_id") ?? "");
  const status = String(formData.get("status") ?? "").trim();
  const reason = String(formData.get("reason") ?? "").trim();
  const received = String(formData.get("received") ?? "").trim();

  if (status === "Closed" && !reason) {
    return { error: "Say why it is being closed. Somebody will ask.", ok: null };
  }

  const { data, error } = await supabase.rpc("set_authorization_status", {
    p_auth: id,
    p_status: status,
    p_reason: reason || null,
    p_received: received || null,
  });
  if (error) return refusal(error.message);

  done(id);
  return { error: null, ok: data ?? "Saved." };
}

/* ── clearing a batch ────────────────────────────────────────
 *
 * The rows that did not go through come back with the result, because a batch
 * where some rows were left alone is the normal case rather than the
 * exception: six of the practice's twenty-one open authorizations come to
 * nothing, and a person told "10 of 13 cleared" and nothing else has to go
 * looking for the three.
 */

type BatchRow = {
  auth_id: string | null;
  auth_number: string | null;
  client_name: string | null;
  outcome: string | null;
  detail: string | null;
};

function batchResult(rows: BatchRow[], did: string): BatchState {
  const shown = rows.map((r) => ({
    auth_number: r.auth_number ?? "",
    client_name: r.client_name ?? "",
    outcome: r.outcome ?? "",
    detail: r.detail ?? "",
  }));
  const went = shown.filter((r) => r.outcome === did).length;
  const held = shown.filter((r) => r.outcome !== did);
  const one = held.length === 1;
  return {
    error: null,
    ok:
      held.length === 0
        ? `${went} ${went === 1 ? "row" : "rows"} ${did}.`
        : `${went} of ${shown.length} ${did}. The ${one ? "other is" : "others are"} below, with what stopped ${one ? "it" : "them"}.`,
    rows: held,
  };
}

/** Mark several paid, with one received date. */
export async function bulkMarkPaid(_prev: BatchState, formData: FormData): Promise<BatchState> {
  const { supabase } = await billingHands();
  const ids = formData.getAll("auth_ids").map(String).filter(Boolean);
  const received = String(formData.get("received") ?? "").trim();

  if (ids.length === 0) return { ...EMPTY_BATCH, error: "Choose the rows to mark paid." };
  if (received && !/^\d{4}-\d{2}-\d{2}$/.test(received)) {
    return { ...EMPTY_BATCH, error: "That date does not look right." };
  }

  const { data, error } = await supabase.rpc("bulk_mark_paid", {
    p_auths: ids,
    p_received: received || null,
  });
  if (error) return { ...EMPTY_BATCH, error: refusal(error.message).error };

  revalidatePath("/billing");
  for (const id of ids) revalidatePath(`/billing/authorizations/${id}`);
  return batchResult((data ?? []) as BatchRow[], "paid");
}

/** Close several, with one reason. */
export async function bulkCloseAuthorizations(
  _prev: BatchState,
  formData: FormData,
): Promise<BatchState> {
  const { supabase } = await billingHands();
  const ids = formData.getAll("auth_ids").map(String).filter(Boolean);
  const reason = String(formData.get("reason") ?? "").trim();

  if (ids.length === 0) return { ...EMPTY_BATCH, error: "Choose the rows to close." };
  if (!reason) return { ...EMPTY_BATCH, error: "Say why they are being closed. Somebody will ask." };

  const { data, error } = await supabase.rpc("bulk_close", { p_auths: ids, p_reason: reason });
  if (error) return { ...EMPTY_BATCH, error: refusal(error.message).error };

  revalidatePath("/billing");
  for (const id of ids) revalidatePath(`/billing/authorizations/${id}`);
  return batchResult((data ?? []) as BatchRow[], "closed");
}
