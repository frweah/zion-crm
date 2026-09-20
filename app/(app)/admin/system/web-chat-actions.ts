"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

/**
 * What the practice has decided about the bubble on zionrehabcenter.com
 * (Messaging brief, C). Admin's to set; the row rule on org_settings says so,
 * not this file.
 */
export type WebChatState = { error: string | null; ok: string | null };

export async function saveWebChat(_prev: WebChatState, formData: FormData): Promise<WebChatState> {
  const supabase = await createClient();

  const open = String(formData.get("open") ?? "09:00");
  const close = String(formData.get("close") ?? "17:00");
  if (close <= open) {
    return { error: "The bubble has to close after it opens.", ok: null };
  }
  const days = formData.getAll("day").map(Number).filter((d) => d >= 1 && d <= 7);
  if (days.length === 0) {
    return { error: "Choose at least one day, or switch the bubble off instead.", ok: null };
  }
  const greeting = String(formData.get("greeting") ?? "").trim();
  const promise = String(formData.get("promise") ?? "").trim();
  if (!promise) {
    return { error: "Say when somebody will hear back, so a visitor is not left wondering.", ok: null };
  }

  const { error } = await supabase
    .from("org_settings")
    .update({
      web_chat_enabled: formData.get("enabled") === "on",
      web_chat_takers: formData.getAll("taker").map(String),
      web_chat_open: open,
      web_chat_close: close,
      web_chat_days: days,
      web_chat_greeting: greeting,
      web_chat_promise: promise,
    })
    .eq("id", true);

  if (error) return { error: error.message, ok: null };
  revalidatePath("/admin/system");
  return { error: null, ok: "Saved." };
}
