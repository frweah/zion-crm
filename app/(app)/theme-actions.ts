"use server";

import { cookies } from "next/headers";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";

/**
 * Which theme this person chose (owner, 14 Oct 2026).
 *
 * Two places, for two different jobs, and it is worth saying which is which.
 *
 *   staff_prefs is the record: theirs, per person, like the sidebar width and
 *   the hints they have put away. It is what the menu reads to show which of
 *   the three is chosen, and what follows them to a new machine.
 *
 *   The cookie is how the page is painted. The root layout reads it and
 *   stamps data-theme on <html> before anything renders, so a person who
 *   chose dark never sees a white page flash first. Reading staff_prefs there
 *   instead would mean a database call on every request including the sign-in
 *   screen, which is the sort of thing that took production down on 14 Oct.
 *
 * System is the absence of both: no row, no cookie, and the stylesheet falls
 * through to prefers-color-scheme. That is the default and it is the default
 * by having nothing stored, not by storing the word "system".
 */
export type Theme = "light" | "dark" | "system";

const COOKIE = "zion-theme";
const KEY = "theme";

export async function setTheme(theme: Theme): Promise<void> {
  if (theme !== "light" && theme !== "dark" && theme !== "system") return;

  const jar = await cookies();
  if (theme === "system") {
    jar.delete(COOKIE);
  } else {
    jar.set(COOKIE, theme, {
      httpOnly: false,
      sameSite: "lax",
      secure: true,
      path: "/",
      // A year: a person who picked a theme means it until they say otherwise.
      maxAge: 365 * 24 * 60 * 60,
    });
  }

  const me = await getCurrentStaff();
  if (!me) return;
  const supabase = await createClient();

  if (theme === "system") {
    await supabase.from("staff_prefs").delete().eq("staff_id", me.id).eq("key", KEY);
    return;
  }
  await supabase
    .from("staff_prefs")
    .upsert({ staff_id: me.id, key: KEY, value: theme }, { onConflict: "staff_id,key" });
}
