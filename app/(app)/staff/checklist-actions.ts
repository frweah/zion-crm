"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";

export type StaffState = { error: string | null; ok: string | null };

/**
 * Ticks or unticks a manual checklist item.
 *
 * Automatic items are refused by the database, not by this action leaving them
 * out of the screen — the rule belongs where it cannot be routed around.
 */
export async function setChecklistItem(
  _prev: StaffState,
  formData: FormData,
): Promise<StaffState> {
  const me = await getCurrentStaff();
  if (me?.role !== "Admin") return { error: "Only Admin can tick these off.", ok: null };

  const supabase = await createClient();
  const { error } = await supabase.rpc("set_checklist_item", {
    p_staff_id: String(formData.get("staff_id") ?? ""),
    p_task_id: String(formData.get("task_id") ?? ""),
    p_done: formData.get("done") === "on",
    p_note: String(formData.get("note") ?? "").trim(),
  });

  if (error) return { error: error.message, ok: null };

  revalidatePath("/staff");
  revalidatePath("/dashboard");
  return { error: null, ok: "Saved." };
}

/**
 * Records a pay rate from a date.
 *
 * The validation that matters is in the database — Admin only, a positive
 * figure, and no two rates from the same day — so this action is a thin way in
 * rather than the place the rules live.
 */
export async function setStaffPay(
  _prev: StaffState,
  formData: FormData,
): Promise<StaffState> {
  const me = await getCurrentStaff();
  if (me?.role !== "Admin") return { error: "Only Admin can set a pay rate.", ok: null };

  const rate = Number(formData.get("pay_rate") ?? 0);
  const from = String(formData.get("effective_from") ?? "");

  if (!(rate > 0)) return { error: "A rate is more than zero.", ok: null };
  if (!/^\d{4}-\d{2}-\d{2}$/.test(from)) {
    return { error: "Check the date the rate takes effect.", ok: null };
  }

  const supabase = await createClient();
  const { error } = await supabase.rpc("set_staff_pay", {
    p_staff_id: String(formData.get("staff_id") ?? ""),
    p_rate: rate,
    p_unit: String(formData.get("rate_unit") ?? "Hourly"),
    p_effective_from: from,
    p_note: String(formData.get("note") ?? "").trim(),
  });

  if (error) return { error: error.message, ok: null };

  revalidatePath("/staff");
  revalidatePath("/dashboard");
  return { error: null, ok: `Rate recorded from ${from}.` };
}

/** Removes the most recent rate. The database refuses any earlier one. */
export async function deleteStaffPay(
  _prev: StaffState,
  formData: FormData,
): Promise<StaffState> {
  const me = await getCurrentStaff();
  if (me?.role !== "Admin") return { error: "Only Admin can remove a pay rate.", ok: null };

  const supabase = await createClient();
  const { error } = await supabase.rpc("delete_staff_pay", {
    p_id: String(formData.get("pay_id") ?? ""),
  });

  if (error) return { error: error.message, ok: null };

  revalidatePath("/staff");
  revalidatePath("/dashboard");
  return { error: null, ok: "Removed." };
}
