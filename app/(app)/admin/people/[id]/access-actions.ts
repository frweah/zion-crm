"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";

export type AccessState = { error: string | null; ok: string | null };

/**
 * Giving and ending access beyond a role. The database decides everything -
 * only Admin, only active staff, only an area the role lacks, a reason every
 * time (grant_staff_access / revoke_staff_access, 0092). These pass the form
 * along and say what happened.
 */
export async function giveAccess(_prev: AccessState, formData: FormData): Promise<AccessState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const staffId = String(formData.get("staff_id") ?? "");
  const supabase = await createClient();
  const { error } = await supabase.rpc("grant_staff_access", {
    p_staff: staffId,
    p_area: String(formData.get("area") ?? ""),
    p_level: String(formData.get("level") ?? ""),
    p_reason: String(formData.get("reason") ?? ""),
  });
  if (error) return { error: error.message, ok: null };

  revalidatePath(`/admin/people/${staffId}`);
  return { error: null, ok: "Access given. It applies from their next page." };
}

export async function endAccess(_prev: AccessState, formData: FormData): Promise<AccessState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const staffId = String(formData.get("staff_id") ?? "");
  const supabase = await createClient();
  const { error } = await supabase.rpc("revoke_staff_access", {
    p_grant: String(formData.get("grant_id") ?? ""),
    p_reason: String(formData.get("reason") ?? ""),
  });
  if (error) return { error: error.message, ok: null };

  revalidatePath(`/admin/people/${staffId}`);
  return { error: null, ok: "Access ended." };
}
