"use server";

import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";

/**
 * Remembers whether this person keeps the sidebar down to its icons. A key in
 * staff_prefs, theirs alone like the hints they have put away; no key means
 * the full sidebar.
 */
export async function setSidebarNarrow(narrow: boolean): Promise<void> {
  const me = await getCurrentStaff();
  if (!me) return;
  const supabase = await createClient();
  if (narrow) {
    await supabase
      .from("staff_prefs")
      .upsert({ staff_id: me.id, key: "sidebar:narrow", value: true }, { onConflict: "staff_id,key" });
  } else {
    await supabase.from("staff_prefs").delete().eq("staff_id", me.id).eq("key", "sidebar:narrow");
  }
}
