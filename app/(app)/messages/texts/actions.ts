"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { markRead } from "../actions";

/**
 * The inbox (Messaging brief, A and C): texts and website chats.
 *
 * Every write is one of the database's own functions (0105, 0107), which
 * decide who may. The five behind this screen lost "text" from their names
 * when the website chat joined it - the rules did not change, only what can
 * be in the list.
 */
export type InboxState = { error: string | null; ok: string | null };

export async function assignConversation(_prev: InboxState, formData: FormData): Promise<InboxState> {
  const supabase = await createClient();
  const staff = String(formData.get("staff_id") ?? "");
  const { error } = await supabase.rpc("assign_conversation", {
    p_conversation: String(formData.get("conversation_id") ?? ""),
    p_staff: staff === "" ? null : staff,
  });
  if (error) return { error: error.message, ok: null };
  revalidatePath("/messages/texts");
  return { error: null, ok: "Assigned." };
}

export async function matchConversation(_prev: InboxState, formData: FormData): Promise<InboxState> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("match_conversation", {
    p_conversation: String(formData.get("conversation_id") ?? ""),
    p_client: String(formData.get("client_id") ?? ""),
  });
  if (error) return { error: error.message, ok: null };
  revalidatePath("/messages/texts");
  return { error: null, ok: "Matched." };
}

export async function referralFromConversation(_prev: InboxState, formData: FormData): Promise<InboxState> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("referral_from_conversation", {
    p_conversation: String(formData.get("conversation_id") ?? ""),
    p_name: String(formData.get("name") ?? ""),
  });
  if (error) return { error: error.message, ok: null };
  revalidatePath("/messages/texts");
  revalidatePath("/clients");
  return { error: null, ok: "Referral started, with an intake call on the list." };
}

export async function markSpam(_prev: InboxState, formData: FormData): Promise<InboxState> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("mark_conversation_spam", {
    p_conversation: String(formData.get("conversation_id") ?? ""),
    p_spam: formData.get("spam") !== "no",
  });
  if (error) return { error: error.message, ok: null };
  revalidatePath("/messages/texts");
  return { error: null, ok: null };
}

/**
 * Answering a visitor.
 *
 * A website chat has no client record to answer from - the person may not be
 * anybody the practice knows yet - so it is answered here, where it arrived.
 */
export async function replyToWebChat(_prev: InboxState, formData: FormData): Promise<InboxState> {
  const supabase = await createClient();
  const conversation = String(formData.get("conversation_id") ?? "");
  const { error } = await supabase.rpc("post_web_reply", {
    p_conversation: conversation,
    p_body: String(formData.get("body") ?? ""),
  });
  if (error) return { error: error.message, ok: null };
  revalidatePath("/messages/texts");
  return { error: null, ok: "sent" };
}

export async function markInboxRead(conversationId: string, seq: number): Promise<void> {
  await markRead(conversationId, seq);
}
