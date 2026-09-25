"use server";

import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";

/**
 * How many conversations are waiting for this person to answer: texts and
 * website chats with something unread that are theirs or nobody's, and staff
 * chats with something unread.
 *
 * Counted as conversations, not messages, and counted once: the Inbox badge
 * and the dashboard's "Waiting for your reply" are the same number, because
 * they are the same question (audit, 25 Sept 2026 - the badge said 83 where
 * the list said 19). Mail is added by the caller (inbox-mail.ts, kept apart
 * because a file that reads mail may not touch the database).
 */
export async function waitingConversations(): Promise<number> {
  const me = await getCurrentStaff();
  if (!me) return 0;
  const supabase = await createClient();
  const [{ data: outside }, { data: chat }] = await Promise.all([
    supabase.rpc("message_inbox", { p_show: "open" }),
    supabase.rpc("my_unread"),
  ]);
  const mine = (outside ?? []).filter(
    (r) => (r.unread ?? 0) > 0 && (me.role === "Admin" || !r.assigned_staff_id || r.assigned_staff_id === me.id),
  ).length;
  return mine + (chat ?? []).filter((r) => (r.unread ?? 0) > 0).length;
}
