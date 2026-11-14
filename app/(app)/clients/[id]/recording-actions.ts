"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";
import type { DetailState } from "./actions";

/**
 * What a person does with a recording (item F).
 *
 * Three actions, and the first of them is the only way anything a machine
 * made of a conversation reaches a client's record. Confirming writes a
 * contact log entry and a note; until somebody does, the transcript and the
 * draft are a proposal sitting beside the audio.
 *
 * Every rule is the database's: who may read a restricted document, what
 * state a recording has to be in, that a note is required and a reason is
 * required. This file carries the form and the words that come back.
 */

const done = (clientId: string) => {
  revalidatePath(`/clients/${clientId}`);
  revalidatePath("/insights/money");
};

const refusal = (message: string) => ({
  error: message.replace(/^.*?:\s*/, "").trim() || message,
  ok: null,
});

export async function confirmRecording(_prev: DetailState, formData: FormData): Promise<DetailState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };
  const clientId = String(formData.get("client_id") ?? "");

  const supabase = await createClient();
  const { error } = await supabase.rpc("confirm_recording", {
    p_id: String(formData.get("id") ?? ""),
    p_about: String(formData.get("about") ?? "").trim(),
    p_agreed: String(formData.get("agreed") ?? "").trim(),
    p_next: String(formData.get("next") ?? "").trim(),
    p_note: String(formData.get("note") ?? "").trim(),
    p_category: String(formData.get("category") ?? "").trim(),
  });
  if (error) return refusal(error.message);
  done(clientId);
  return {
    error: null,
    ok: "On the record: a contact log entry and a note, both under your name.",
  };
}

export async function setRecordingAside(_prev: DetailState, formData: FormData): Promise<DetailState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };
  const clientId = String(formData.get("client_id") ?? "");

  const supabase = await createClient();
  const { error } = await supabase.rpc("set_recording_aside", {
    p_id: String(formData.get("id") ?? ""),
    p_reason: String(formData.get("reason") ?? "").trim(),
  });
  if (error) return refusal(error.message);
  done(clientId);
  return { error: null, ok: "Set aside, with the reason. The recording itself stays on the documents." };
}

/** A held recording, paid for anyway. Admin's, because it is spending. */
export async function readHeldRecording(_prev: DetailState, formData: FormData): Promise<DetailState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };
  const clientId = String(formData.get("client_id") ?? "");

  const supabase = await createClient();
  const { error } = await supabase.rpc("read_held_recording", {
    p_id: String(formData.get("id") ?? ""),
  });
  if (error) return refusal(error.message);
  done(clientId);
  return { error: null, ok: "It goes in the next run. The month's hours are still over the limit." };
}
