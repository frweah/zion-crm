"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";
import { sendClientSms } from "@/lib/sms";
import { CAN_EDIT_CLIENTS } from "@/lib/constants";

/**
 * Texting a client from their record (Messaging brief, A).
 *
 * Nothing here decides whether a text may go: the database does, on the way in
 * (0050, 0105) - consent for that number, and between 8am and 9pm. A message
 * written outside those hours is offered the next window instead.
 */
export type TextState = { error: string | null; ok: string | null };

export async function sendText(_prev: TextState, formData: FormData): Promise<TextState> {
  const me = await getCurrentStaff();
  if (!me || !CAN_EDIT_CLIENTS.includes(me.role)) {
    return { error: "Your role does not send texts.", ok: null };
  }

  const clientId = String(formData.get("client_id") ?? "");
  const body = String(formData.get("body") ?? "").trim();
  const later = formData.get("later") === "yes";
  if (!body) return { error: "The message is empty.", ok: null };
  if (body.length > 600) return { error: "That is too long for a text - 600 characters at most.", ok: null };

  const supabase = await createClient();
  const [{ data: client }, { data: consent }, { data: window }] = await Promise.all([
    supabase.from("clients").select("name, phone, ghl_id").eq("id", clientId).maybeSingle(),
    supabase.from("client_sms_consent").select("can_text, consented_phone").eq("client_id", clientId).maybeSingle(),
    supabase.rpc("next_text_window", { p_at: new Date().toISOString() }),
  ]);
  if (!client) return { error: "That client is not on file.", ok: null };
  const phone = consent?.consented_phone ?? client.phone ?? "";
  if (!phone) return { error: "There is no number on this record.", ok: null };

  const outcome = await sendClientSms(supabase, {
    clientId,
    clientName: client.name,
    phone,
    body,
    kind: "Manual",
    staffId: me.id,
    ghlId: client.ghl_id ?? null,
    sendAfter: later ? (window as string | null) : null,
  });

  revalidatePath(`/clients/${clientId}`);
  if (!outcome.ok) return { error: outcome.error, ok: null };
  return {
    error: null,
    ok: later
      ? `Written. It goes out at ${new Date(String(window)).toLocaleString("en-US", { timeZone: "America/Denver", hour: "numeric", minute: "2-digit", month: "short", day: "numeric" })}.`
      : "Sent.",
  };
}

/** A message written for later, thought better of. */
export async function cancelScheduledText(_prev: TextState, formData: FormData): Promise<TextState> {
  const me = await getCurrentStaff();
  if (!me || !CAN_EDIT_CLIENTS.includes(me.role)) {
    return { error: "Your role does not send texts.", ok: null };
  }
  const supabase = await createClient();
  const { error } = await supabase
    .from("sms_messages")
    .delete()
    .eq("id", String(formData.get("text_id") ?? ""))
    .eq("status", "Scheduled");
  if (error) return { error: error.message, ok: null };
  revalidatePath(`/clients/${String(formData.get("client_id") ?? "")}`);
  return { error: null, ok: "It will not be sent." };
}

/** A template staff can reach for, and add to. */
export async function saveTemplate(_prev: TextState, formData: FormData): Promise<TextState> {
  const me = await getCurrentStaff();
  if (!me || !CAN_EDIT_CLIENTS.includes(me.role)) {
    return { error: "Your role does not change the templates.", ok: null };
  }
  const label = String(formData.get("label") ?? "").trim();
  const body = String(formData.get("body") ?? "").trim();
  if (!label || !body) return { error: "A template needs a name and its words.", ok: null };
  if (body.length > 600) return { error: "A template is 600 characters at most.", ok: null };

  const supabase = await createClient();
  const { error } = await supabase.from("sms_templates").insert({ label, body, created_by: me.id });
  if (error) return { error: error.message, ok: null };
  revalidatePath(`/clients/${String(formData.get("client_id") ?? "")}`);
  return { error: null, ok: `Template "${label}" saved.` };
}
