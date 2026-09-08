"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";

export type MicrosoftState = { error: string | null; ok: string | null };

/**
 * Removes the stored connection.
 *
 * The delete goes through the RLS-bound client, so the database decides who
 * may: the person themselves, or Admin when offboarding somebody. Deleting the
 * row takes the encrypted tokens with it.
 */
export async function disconnectMicrosoft(
  _prev: MicrosoftState,
  formData: FormData,
): Promise<MicrosoftState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const staffId = String(formData.get("staff_id") ?? "") || me.id;

  const supabase = await createClient();
  const { data, error } = await supabase
    .from("microsoft_connections")
    .delete()
    .eq("staff_id", staffId)
    .select("microsoft_email")
    .maybeSingle();

  if (error) return { error: error.message, ok: null };
  if (!data) return { error: "There was nothing to disconnect.", ok: null };

  revalidatePath("/dashboard");
  revalidatePath("/staff");
  return { error: null, ok: "Disconnected." };
}
