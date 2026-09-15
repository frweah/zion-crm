"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";
import { CAN_EDIT_BILLING } from "@/lib/constants";

export type WarrantState = { error: string | null; ok: string | null };

/**
 * Record a warrant line a person has checked against the page image.
 *
 * The page could not prove the line on its own - a misread V-number, a total
 * that did not add up, a number not on file. Looking at the stub, the person
 * says which authorization it pays and how much, and
 * public.reconcile_warrant_line records it exactly as a validated line would
 * be, with their name on it.
 */
export async function resolveWarrantLine(_prev: WarrantState, formData: FormData): Promise<WarrantState> {
  const me = await getCurrentStaff();
  if (!me || !CAN_EDIT_BILLING.includes(me.role)) {
    return { error: "Only Admin and Billing record a warrant line.", ok: null };
  }

  const lineId = String(formData.get("line_id") ?? "");
  const authId = String(formData.get("auth_id") ?? "");
  const amount = Number(String(formData.get("amount") ?? "").replace(/[$,\s]/g, ""));
  if (!lineId) return { error: "Which line?", ok: null };
  if (!authId) return { error: "Choose the authorization this line pays.", ok: null };
  if (!Number.isFinite(amount) || amount <= 0) return { error: "Give the amount paid, as on the stub.", ok: null };

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("reconcile_warrant_line", {
    p_line: lineId,
    p_by_hand: true,
    p_auth: authId,
    p_amount: amount,
  });
  if (error) return { error: error.message, ok: null };

  revalidatePath("/billing/warrants");
  revalidatePath("/billing");
  revalidatePath("/billing");
  return {
    error: null,
    ok: data === "Resolved by hand" ? "Recorded: the payment is on the authorization and its invoice is paid." : `The line is now ${data}.`,
  };
}

/** Set a line aside: not a payment to this practice, a duplicate, a misread. */
export async function dismissWarrantLine(_prev: WarrantState, formData: FormData): Promise<WarrantState> {
  const me = await getCurrentStaff();
  if (!me || !CAN_EDIT_BILLING.includes(me.role)) {
    return { error: "Only Admin and Billing set a warrant line aside.", ok: null };
  }

  const lineId = String(formData.get("line_id") ?? "");
  const reason = String(formData.get("reason") ?? "").trim();
  if (!reason) return { error: "Say why, so nobody wonders later whether it was paid.", ok: null };

  const supabase = await createClient();
  const { error } = await supabase.rpc("dismiss_warrant_line", { p_line: lineId, p_reason: reason });
  if (error) return { error: error.message, ok: null };

  revalidatePath("/billing/warrants");
  return { error: null, ok: "Set aside." };
}
