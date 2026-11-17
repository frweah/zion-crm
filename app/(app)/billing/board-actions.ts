"use server";

import { revalidatePath } from "next/cache";
import { requireStaff } from "@/lib/session";
import { can } from "@/lib/roles";
import { createClient } from "@/lib/supabase/server";

/**
 * What the board writes, and why there is nothing new behind any of it.
 *
 * Three cells on the board accept typing or a click: Submitted on, Paid on,
 * and the status pill. Each one calls the same database function the
 * authorization record calls, so an edit made on the board and the same edit
 * made on the record go through the same checks, write the same correction
 * log, and are refused in the same words (brief, Part 2).
 *
 *   Submitted on  → edit_authorization, which gained the field in 0366 and
 *                   refuses a date when no invoice number has been raised.
 *   Paid on       → record_payment, with the amount defaulting to what was
 *                   invoiced, which moves the row to Paid. A warrant matched
 *                   later still takes precedence on the amount, as it did
 *                   before (owner, 17 November 2026).
 *   The pill      → set_authorization_status, which since 0367 refuses
 *                   Submitted until there is a number that went to USOR.
 *
 * None of these is reachable without a billing edit grant, and each database
 * function asks again for itself: the check here saves somebody a refusal
 * they could not act on, it does not stand in for the one that matters.
 */

export type CellState = { error: string | null; ok: string | null };

async function billingHands() {
  const me = await requireStaff();
  if (!can(me, "billing", "edit")) {
    throw new Error("Editing on the board is Billing's, or an Admin's.");
  }
  return { me, supabase: await createClient() };
}

/** The screens a change on the board is visible on. */
function done(clientId: string, authId: string) {
  revalidatePath("/billing");
  revalidatePath(`/billing/authorizations/${authId}`);
  revalidatePath(`/clients/${clientId}`);
  revalidatePath("/insights/money");
}

/** The database's own sentence, which names the field. Ours could not. */
const refusal = (message: string) => ({
  error: message.replace(/^.*?:\s*/, "").trim() || message,
  ok: null,
});

const DAY = /^\d{4}-\d{2}-\d{2}$/;

/** The day the packet went to USOR. */
export async function setSubmittedOn(_prev: CellState, formData: FormData): Promise<CellState> {
  const { supabase } = await billingHands();
  const authId = String(formData.get("auth_id") ?? "");
  const clientId = String(formData.get("client_id") ?? "");
  const day = String(formData.get("day") ?? "").trim();
  if (day && !DAY.test(day)) return { error: "That date does not look right.", ok: null };

  const { error } = await supabase.rpc("edit_authorization", {
    p_auth: authId,
    p_fields: { submitted_on: day },
    p_reason: "Typed on the billing board",
  });
  if (error) return refusal(error.message);

  done(clientId, authId);
  return { error: null, ok: day ? "Submitted on saved." : "Submitted on cleared." };
}

/**
 * The day the money arrived.
 *
 * This records a payment, which is what the day means: there is no column
 * that holds "money arrived" without a payment behind it, and inventing one
 * would be the second write path the brief forbids. The amount defaults to
 * what was invoiced and the screen shows it before the click.
 */
export async function setPaidOn(_prev: CellState, formData: FormData): Promise<CellState> {
  const { supabase } = await billingHands();
  const authId = String(formData.get("auth_id") ?? "");
  const clientId = String(formData.get("client_id") ?? "");
  const day = String(formData.get("day") ?? "").trim();
  const amount = String(formData.get("amount") ?? "").trim();
  if (!DAY.test(day)) return { error: "That date does not look right.", ok: null };
  if (amount && !/^\d+(\.\d{1,2})?$/.test(amount)) {
    return { error: "That amount does not look like money.", ok: null };
  }

  const { error } = await supabase.rpc("record_payment", {
    p_auth: authId,
    p_received: day,
    p_amount: amount ? Number(amount) : null,
    // The board never sends a warrant or a voucher. Admin puts those on from
    // Admin → Warrants, and record_payment refuses them from anybody else.
    p_warrant: null,
    p_voucher: null,
  });
  if (error) return refusal(error.message);

  done(clientId, authId);
  return { error: null, ok: "Recorded, and this authorization is Paid." };
}

/**
 * The pill: Outstanding, or Waiting on payment.
 *
 * Two of the five statuses, under the words the board uses for them. Paid and
 * Closed are not here - Paid is reached by recording what arrived or by a
 * matched warrant, and Closed is a decision with a reason, taken on the
 * authorization record.
 */
export async function setBoardStatus(_prev: CellState, formData: FormData): Promise<CellState> {
  const { supabase } = await billingHands();
  const authId = String(formData.get("auth_id") ?? "");
  const clientId = String(formData.get("client_id") ?? "");
  const status = String(formData.get("status") ?? "").trim();
  if (status !== "Due" && status !== "Submitted") {
    return { error: "The board sets Outstanding or Waiting on payment.", ok: null };
  }

  const { data, error } = await supabase.rpc("set_authorization_status", {
    p_auth: authId,
    p_status: status,
    p_reason: null,
    p_received: null,
  });
  if (error) return refusal(error.message);

  done(clientId, authId);
  return { error: null, ok: (data as string | null) ?? "Saved." };
}
