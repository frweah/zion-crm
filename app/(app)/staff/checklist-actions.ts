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
