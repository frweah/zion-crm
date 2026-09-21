"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";

/**
 * The caseload card's "Mine" toggle, remembered per person (owner, 21 Sept
 * 2026). A key in staff_prefs, theirs alone; no key means the whole practice,
 * which is where everybody starts.
 */
export async function setCaseloadMine(formData: FormData): Promise<void> {
  const me = await getCurrentStaff();
  if (!me) return;
  const mine = formData.get("mine") === "true";
  const supabase = await createClient();
  if (mine) {
    await supabase
      .from("staff_prefs")
      .upsert({ staff_id: me.id, key: "caseload:mine", value: true }, { onConflict: "staff_id,key" });
  } else {
    await supabase.from("staff_prefs").delete().eq("staff_id", me.id).eq("key", "caseload:mine");
  }
  revalidatePath("/dashboard");
  revalidatePath("/clients");
}
