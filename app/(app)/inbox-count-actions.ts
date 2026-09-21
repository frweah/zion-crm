"use server";

import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";

/**
 * Texts and website chats not yet read by this person - the part of the Inbox
 * badge that is not staff chat (live already) or mail (inbox-mail.ts, kept
 * apart because a file that reads mail may not touch the database).
 */
export async function outsideUnread(): Promise<number> {
  const me = await getCurrentStaff();
  if (!me) return 0;
  const supabase = await createClient();
  const { data } = await supabase.rpc("message_inbox", { p_show: "open" });
  return (data ?? []).reduce((s, r) => s + (r.unread ?? 0), 0);
}
