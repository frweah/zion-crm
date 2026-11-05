"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

/**
 * Deciding a correction to somebody's hours.
 *
 * Who may decide is the database's question, not this file's: the manager it
 * was sent to, or Admin (0293). Nothing here checks a role, because two places
 * checking the same rule is one place to get it wrong.
 */
export type HoursDecision = { error: string | null; ok: string | null };

export async function decideCorrection(
  _prev: HoursDecision,
  formData: FormData,
): Promise<HoursDecision> {
  const approve = String(formData.get("decision") ?? "") === "approve";
  const supabase = await createClient();

  const { data, error } = await supabase.rpc("decide_hours_correction", {
    p_correction: String(formData.get("correction_id") ?? ""),
    p_approve: approve,
    p_reason: String(formData.get("reason") ?? ""),
  });

  if (error) return { error: error.message, ok: null };

  revalidatePath("/admin/hours");
  revalidatePath("/time-clock");
  return { error: null, ok: typeof data === "string" ? data : approve ? "Approved" : "Declined" };
}
