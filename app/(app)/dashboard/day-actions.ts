"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";
import { today } from "@/lib/constants";

/**
 * Mark a conversation read up to its latest message - staff chat, a text or
 * a website chat - from the dashboard, without opening it. The same receipt
 * opening it would write (mark_read), so the badge and every list agree.
 */
export async function markConversationRead(formData: FormData): Promise<void> {
  const me = await getCurrentStaff();
  if (!me) return;
  const conversationId = String(formData.get("conversation_id") ?? "");
  const seq = Number(formData.get("seq") ?? 0);
  if (!conversationId || !Number.isFinite(seq) || seq <= 0) return;
  const supabase = await createClient();
  await supabase.rpc("mark_read", { p_conversation: conversationId, p_seq: seq });
  revalidatePath("/dashboard");
}

/**
 * Put an alert out of this person's way until tomorrow (0119). The alert is
 * the practice's and stays for everybody else; it comes back tomorrow if what
 * raised it is still true.
 */
export async function snoozeAlert(formData: FormData): Promise<void> {
  const me = await getCurrentStaff();
  if (!me) return;
  const id = String(formData.get("notification_id") ?? "");
  if (!/^[0-9a-f-]{36}$/.test(id)) return;
  const tomorrow = new Date(Date.parse(`${today()}T12:00:00Z`) + 86400000).toISOString().slice(0, 10);
  const supabase = await createClient();
  await supabase
    .from("staff_alert_snoozes")
    .upsert({ staff_id: me.id, notification_id: id, until: tomorrow }, { onConflict: "staff_id,notification_id" });
  revalidatePath("/dashboard");
}
