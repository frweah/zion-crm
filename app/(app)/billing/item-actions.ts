"use server";

import { revalidatePath } from "next/cache";
import { requireStaff } from "@/lib/session";
import { can } from "@/lib/roles";
import { createClient } from "@/lib/supabase/server";
import { today } from "@/lib/constants";

/**
 * What can be done to a billing item (her §14).
 *
 * Each of these is one move, named the way Margaret names it, and each leaves
 * the record able to say who did it - the database writes the history from
 * the status change itself, so there is no way to make one of these moves
 * without it being recorded.
 *
 * Two of them are deliberately not a choice of status: Submit is what the
 * send does, and Record payment is what a warrant does. A person cannot type
 * either status onto an item, here or anywhere, because a status that can be
 * typed is a status that stops meaning anything (her 12.8, 12.9).
 */
async function billingHands() {
  const me = await requireStaff();
  if (!can(me, "billing", "edit")) throw new Error("Billing edits are Billing's, or an Admin's.");
  return { me, supabase: await createClient() };
}

const done = (itemId: string) => {
  revalidatePath(`/billing/items/${itemId}`);
  revalidatePath("/billing");
};

/** The work is finished: the period is complete and the dates are the work's own. */
export async function markServiceComplete(itemId: string, formData: FormData) {
  const { supabase } = await billingHands();
  const start = String(formData.get("service_start") ?? "").trim();
  const end = String(formData.get("service_end") ?? "").trim();
  if (!start || !end) throw new Error("Record when the work started and finished.");

  const { error } = await supabase
    .from("billing_items")
    .update({ service_start: start, service_end: end, status: "Service period complete" })
    .eq("id", itemId);
  if (error) throw new Error(error.message);
  done(itemId);
}

/** A coaching month with no hours, once somebody has looked: which was it? */
export async function resolveZeroHours(itemId: string, formData: FormData) {
  const { me, supabase } = await billingHands();
  const answer = String(formData.get("answer") ?? "");

  if (answer === "no service") {
    const { error } = await supabase
      .from("billing_items")
      .update({
        status: "Closed",
        closed_reason: "No service provided this month",
        closed_at: new Date().toISOString(),
        closed_by: me.id,
        zero_hours_flagged: false,
        zero_hours_confirmed_by: me.id,
        zero_hours_confirmed_at: new Date().toISOString(),
      })
      .eq("id", itemId);
    if (error) throw new Error(error.message);
  } else {
    // The hours exist and were not logged: the month goes back to being
    // worked, and the flag comes off once they are in.
    const { error } = await supabase
      .from("billing_items")
      .update({ status: "Service in progress", zero_hours_flagged: false })
      .eq("id", itemId);
    if (error) throw new Error(error.message);
  }
  done(itemId);
}

/** Onto the checklist. */
export async function sendForReview(itemId: string) {
  const { supabase } = await billingHands();
  const { error } = await supabase.from("billing_items").update({ status: "Billing review" }).eq("id", itemId);
  if (error) throw new Error(error.message);
  done(itemId);
}

/**
 * Sends the packet, and only then says Submitted.
 *
 * The gate is asked again here rather than trusted from the screen: the
 * screen was drawn at some point in the past, and the item may have changed
 * since - or the button may not have been pressed by the screen at all.
 */
export async function submitItem(itemId: string, formData: FormData) {
  const { me, supabase } = await billingHands();
  const recipient = String(formData.get("recipient") ?? "").trim();
  if (!recipient.includes("@")) throw new Error("There is no billing office address to send this to.");

  const { data: ready, error: gateError } = await supabase.rpc("billing_item_ready", { p_item: itemId });
  if (gateError) throw new Error(gateError.message);
  if (!ready) throw new Error("Some of the checks still fail. The list on the item says which.");

  const { error } = await supabase
    .from("billing_items")
    .update({
      status: "Submitted",
      recipient,
      submitted_at: new Date().toISOString(),
      submitted_by: me.id,
      followup_due: null,
    })
    .eq("id", itemId);
  if (error) throw new Error(error.message);
  done(itemId);
}

/** It came back with something to change. */
export async function requestCorrection(itemId: string, formData: FormData) {
  const { supabase } = await billingHands();
  const note = String(formData.get("note") ?? "").trim();
  if (!note) throw new Error("Say what has to change - the next person to open this was not on the call.");

  const { error } = await supabase
    .from("billing_items")
    .update({ status: "Correction needed", correction_note: note })
    .eq("id", itemId);
  if (error) throw new Error(error.message);
  done(itemId);
}

/** A payment that did not arrive through a warrant, recorded by hand and logged as such. */
export async function recordPayment(itemId: string, formData: FormData) {
  const { supabase } = await billingHands();
  const paidOn = String(formData.get("paid_on") ?? "").trim() || today();
  const amount = Number(formData.get("paid_amount") ?? 0);
  const warrant = String(formData.get("warrant") ?? "").trim() || null;
  if (!(amount > 0)) throw new Error("A payment has an amount.");

  const { error } = await supabase
    .from("billing_items")
    .update({ status: "Paid", paid_on: paidOn, paid_amount: amount, warrant, followup_due: null })
    .eq("id", itemId);
  if (error) throw new Error(error.message);
  done(itemId);
}

/** Ended without payment. The reason is the point of this action. */
export async function closeItem(itemId: string, formData: FormData) {
  const { me, supabase } = await billingHands();
  const reason = String(formData.get("reason") ?? "").trim();
  if (!reason) throw new Error("Closing an item takes a reason.");

  const { error } = await supabase
    .from("billing_items")
    .update({ status: "Closed", closed_reason: reason, closed_at: new Date().toISOString(), closed_by: me.id })
    .eq("id", itemId);
  if (error) throw new Error(error.message);
  done(itemId);
}

/** Admin only, and recorded like every other move. */
export async function reopenItem(itemId: string) {
  const me = await requireStaff();
  if (me.role !== "Admin") throw new Error("Only an Admin reopens a closed item.");
  const supabase = await createClient();
  const { error } = await supabase
    .from("billing_items")
    .update({ status: "Billing review", closed_reason: null, closed_at: null, closed_by: null })
    .eq("id", itemId);
  if (error) throw new Error(error.message);
  done(itemId);
}
