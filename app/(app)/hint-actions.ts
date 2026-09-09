"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";

export type HintState = { error: string | null; ok: string | null };

/**
 * Puts a hint away, for this person, for good.
 *
 * staff_prefs is the existing per-person key and value store, readable and
 * writable by that person alone — so a dismissal is theirs, and Margaret
 * putting a hint away does not take it from Rei.
 */
export async function dismissHint(_prev: HintState, formData: FormData): Promise<HintState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const key = String(formData.get("key") ?? "").trim();
  if (!key) return { error: "Which hint?", ok: null };

  const supabase = await createClient();
  const { error } = await supabase
    .from("staff_prefs")
    .upsert(
      { staff_id: me.id, key: `hint:${key}`, value: true },
      { onConflict: "staff_id,key" },
    );

  if (error) return { error: error.message, ok: null };

  // The onboarding checklist counts these, so it is stale the moment one goes.
  revalidatePath("/staff");
  revalidatePath("/dashboard");
  return { error: null, ok: "dismissed" };
}
