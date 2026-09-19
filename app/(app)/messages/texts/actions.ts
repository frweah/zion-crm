"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

/**
 * The texts inbox (Messaging brief, A). Who has a conversation, whose number
 * an unknown one turns out to be, and what to do with the rest. Each is a
 * database function that checks the role itself (0105).
 */
export type InboxState = { error: string | null; ok: string | null };

export async function assignConversation(_prev: InboxState, formData: FormData): Promise<InboxState> {
  const supabase = await createClient();
  const staff = String(formData.get("staff_id") ?? "");
  const { error } = await supabase.rpc("assign_text_conversation", {
    p_conversation: String(formData.get("conversation_id") ?? ""),
    p_staff: staff || null,
  });
  if (error) return { error: error.message, ok: null };
  revalidatePath("/messages/texts");
  return { error: null, ok: staff ? "Assigned." : "Unassigned." };
}

export async function matchConversation(_prev: InboxState, formData: FormData): Promise<InboxState> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("match_text_conversation", {
    p_conversation: String(formData.get("conversation_id") ?? ""),
    p_client: String(formData.get("client_id") ?? ""),
  });
  if (error) return { error: error.message, ok: null };
  revalidatePath("/messages/texts");
  revalidatePath("/clients", "layout");
  return { error: null, ok: "Matched. The texts are on their record." };
}

export async function referralFromText(_prev: InboxState, formData: FormData): Promise<InboxState> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("referral_from_text", {
    p_conversation: String(formData.get("conversation_id") ?? ""),
    p_name: String(formData.get("name") ?? ""),
  });
  if (error) return { error: error.message, ok: null };
  revalidatePath("/messages/texts");
  revalidatePath("/clients", "layout");
  return { error: null, ok: `Referral started${data ? "" : ""}. An intake call is on your tasks for tomorrow.` };
}

export async function markSpam(_prev: InboxState, formData: FormData): Promise<InboxState> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("mark_text_spam", {
    p_conversation: String(formData.get("conversation_id") ?? ""),
    p_spam: formData.get("spam") !== "no",
  });
  if (error) return { error: error.message, ok: null };
  revalidatePath("/messages/texts");
  return { error: null, ok: formData.get("spam") !== "no" ? "Marked spam. It is kept, not deleted." : "Back in the inbox." };
}
