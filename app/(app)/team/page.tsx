import { TeamScreen } from "../messages/screen";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { chatSettings } from "@/lib/chat-prefs";
import { TeamSettings } from "./settings";

/**
 * Team.
 *
 * The screen is the one that has been at /messages since 0104 - the staff
 * conversations, live, with the one open beside the list. What is new is where
 * it lives: the sidebar, directly below the main tabs, with its own unread
 * count, at /team (owner, 30 Oct 2026).
 *
 * The page is rendered rather than copied. Two files drawing the same screen
 * is two files to change when the screen changes, and the one that gets
 * forgotten is the one somebody is looking at.
 *
 * The three settings and the one button that asks the browser for permission
 * are here rather than in Admin, because this is the screen a person is on
 * when the pop-up has just interrupted them.
 */
export default async function TeamPage({
  searchParams,
}: {
  searchParams: Promise<{ c?: string; error?: string; q?: string; archived?: string }>;
}) {
  const [me, supabase] = await Promise.all([requireStaff(), createClient()]);
  const { data: prefs } = await supabase
    .from("staff_prefs")
    .select("key")
    .eq("staff_id", me.id)
    .like("key", "chat:%");

  return (
    <>
      {await TeamScreen({ searchParams })}
      <TeamSettings settings={chatSettings(prefs ?? [])} />
    </>
  );
}
