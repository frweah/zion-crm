"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";

/**
 * Staff conversations (Messaging brief, foundation). Every write is one of the
 * database's own functions (0104), which decide who may.
 */
export type ChatState = { error: string | null; ok: string | null };

export async function startDirect(formData: FormData): Promise<void> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("start_direct_conversation", {
    p_other: String(formData.get("staff_id") ?? ""),
  });
  if (error || !data) redirect(`/messages?error=${encodeURIComponent(error?.message ?? "It could not be started.")}`);
  redirect(`/messages?c=${data}`);
}

export async function sendChatMessage(_prev: ChatState, formData: FormData): Promise<ChatState> {
  const supabase = await createClient();
  const conversation = String(formData.get("conversation_id") ?? "");
  const { error } = await supabase.rpc("post_message", {
    p_conversation: conversation,
    p_body: String(formData.get("body") ?? ""),
    // Attachments come with staff chat (B).
    p_attachments: [] as never,
  });
  if (error) return { error: error.message, ok: null };
  revalidatePath("/messages");
  return { error: null, ok: "sent" };
}

export async function markRead(conversationId: string, seq: number): Promise<void> {
  const supabase = await createClient();
  await supabase.rpc("mark_read", { p_conversation: conversationId, p_seq: seq });
}

/** The unread-message email: counts and names after thirty minutes away, never the text. */
export async function setDigest(formData: FormData): Promise<void> {
  const me = await getCurrentStaff();
  if (!me) return;
  const supabase = await createClient();
  if (formData.get("on") === "yes") {
    await supabase
      .from("staff_prefs")
      .upsert({ staff_id: me.id, key: "messages:email_digest", value: true }, { onConflict: "staff_id,key" });
  } else {
    await supabase.from("staff_prefs").delete().eq("staff_id", me.id).eq("key", "messages:email_digest");
  }
  revalidatePath("/messages");
}
