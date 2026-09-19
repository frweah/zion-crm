"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";

export type EngagementState = { error: string | null; ok: string | null };

/**
 * Employee or contractor, and the start date. It decides their tax form and
 * whether they complete an I-9; the invite asks it, and this is where it is set
 * for anybody added before the invite did.
 */
export async function setEngagement(_prev: EngagementState, formData: FormData): Promise<EngagementState> {
  const me = await getCurrentStaff();
  if (me?.role !== "Admin") return { error: "Only Admin sets how somebody is engaged.", ok: null };

  const staffId = String(formData.get("staff_id") ?? "");
  const type = String(formData.get("employment_type") ?? "");
  const startedOn = String(formData.get("started_on") ?? "").trim();
  if (type !== "Employee" && type !== "Contractor" && type !== "Owner") return { error: "Choose employee or contractor.", ok: null };

  const supabase = await createClient();
  const { error } = await supabase
    .from("staff_employment")
    .upsert({ staff_id: staffId, employment_type: type, started_on: startedOn || null }, { onConflict: "staff_id" });
  if (error) return { error: error.message, ok: null };

  revalidatePath("/admin/people", "layout");
  revalidatePath("/paperwork", "layout");
  return { error: null, ok: `Recorded as ${type.toLowerCase()}.` };
}
