"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";

export type MailState = { error: string | null; ok: string | null };

/**
 * Stops a thread being logged, and removes what it already logged.
 *
 * Excluding is by conversation rather than by message, because a thread is
 * what somebody means when they say "not this one" — and a reply arriving
 * tomorrow should not bring the thread back.
 */
export async function excludeThread(
  _prev: MailState,
  formData: FormData,
): Promise<MailState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const conversationId = String(formData.get("conversation_id") ?? "");
  if (!conversationId) return { error: "No thread given.", ok: null };

  const supabase = await createClient();
  const { error } = await supabase.rpc("exclude_mail_thread", {
    p_conversation_id: conversationId,
    p_reason: String(formData.get("reason") ?? "").trim(),
  });

  if (error) return { error: error.message, ok: null };

  revalidatePath("/clients");
  return { error: null, ok: "That thread will not be logged again." };
}
