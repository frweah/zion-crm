"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";
import { CHAT_PREFS, type ChatPref } from "@/lib/chat-prefs";

export type PrefState = { error: string | null; ok: string | null };

/**
 * Three settings, each this person's own.
 *
 * `staff_prefs` is the per-person key and value store the theme and the hints
 * already use, and its one policy is `staff_prefs_own` — so these are theirs
 * to set and nobody else's to read, without a line of new access control.
 *
 * All three default to off by having no row rather than by storing `false`,
 * which is how the theme does it: the absence is the default, so a default
 * that changes later changes for everybody who never chose, and the people who
 * did choose keep what they chose.
 */
export async function setChatPref(_prev: PrefState, formData: FormData): Promise<PrefState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const pref = String(formData.get("pref") ?? "") as ChatPref;
  if (!CHAT_PREFS.includes(pref)) return { error: "Which setting?", ok: null };

  const on = String(formData.get("on") ?? "") === "1";
  const supabase = await createClient();

  if (!on) {
    const { error } = await supabase
      .from("staff_prefs")
      .delete()
      .eq("staff_id", me.id)
      .eq("key", pref);
    if (error) return { error: error.message, ok: null };
  } else {
    const { error } = await supabase
      .from("staff_prefs")
      .upsert({ staff_id: me.id, key: pref, value: true }, { onConflict: "staff_id,key" });
    if (error) return { error: error.message, ok: null };
  }

  revalidatePath("/team");
  return { error: null, ok: "Saved." };
}
