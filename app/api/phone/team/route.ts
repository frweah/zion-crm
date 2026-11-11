import { type NextRequest } from "next/server";
import { phoneStaff, fresh } from "@/lib/phone/server";

/**
 * Team, on the phone: the conversations, and one of them.
 *
 * The same reads the Team pane makes, through the person's own session, so
 * a conversation they are not in is not here. The phone keeps the last
 * answer so a thread can be read, and replied to, with no signal; a reply
 * waits on the phone until it can be sent.
 */
export const dynamic = "force-dynamic";

export async function GET(request: NextRequest) {
  const who = await phoneStaff();
  if ("response" in who) return who.response;
  const { supabase } = who;
  const id = request.nextUrl.searchParams.get("c");

  if (id) {
    if (!/^[0-9a-f-]{36}$/i.test(id)) return fresh({ error: "Which conversation?" }, 400);
    const { data, error } = await supabase
      .from("messages")
      .select("id, seq, sender_label, body, created_at, removed_at")
      .eq("conversation_id", id)
      .order("seq", { ascending: false })
      .limit(30);
    if (error) return fresh({ error: error.message }, 503);
    return fresh({
      lines: (data ?? [])
        .reverse()
        .map((m) => ({ id: m.id, who: m.sender_label, body: m.removed_at ? "Taken back" : m.body, at: m.created_at })),
    });
  }

  const [{ data: convs, error }, { data: unread }] = await Promise.all([
    supabase
      .from("conversations")
      .select("id, title, last_message_at")
      .eq("kind", "internal")
      .is("archived_at", null)
      .order("last_message_at", { ascending: false, nullsFirst: false })
      .limit(20),
    supabase.rpc("my_unread"),
  ]);
  if (error) return fresh({ error: error.message }, 503);
  const counts = new Map(
    ((unread ?? []) as { conversation_id: string; unread: number }[]).map((r) => [r.conversation_id, r.unread ?? 0]),
  );
  return fresh({
    threads: (convs ?? []).map((c) => ({
      id: c.id,
      title: c.title?.trim() || "A conversation",
      at: c.last_message_at,
      unread: counts.get(c.id) ?? 0,
    })),
  });
}
