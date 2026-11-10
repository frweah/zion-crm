"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";
import type { DetailState } from "./actions";

/**
 * A client's numbers, and the people around them (part A, 9 November 2026).
 *
 * Every one of these is a thin pass to a database function. The rules live
 * there because they are rules about records rather than about forms: a
 * number is normalised to the one shape the practice matches on, a contact's
 * number may not be one the client is already reached on, the number texts go
 * to is swapped rather than set, and who may do any of it is the same three
 * roles that may add a client. A screen that enforced those itself would be a
 * second set of rules to keep in step.
 *
 * So the refusals here are the database's own words. It knows which number
 * belongs to whom; this file does not.
 */

const done = (clientId: string) => {
  revalidatePath(`/clients/${clientId}`);
  revalidatePath("/admin/consent");
};

const refusal = (message: string) => ({
  error: message.replace(/^.*?:\s*/, "").trim() || message,
  ok: null,
});

async function signedIn(): Promise<{ error: DetailState } | { supabase: Awaited<ReturnType<typeof createClient>> }> {
  const me = await getCurrentStaff();
  if (!me) return { error: { error: "You are not signed in.", ok: null } };
  return { supabase: await createClient() };
}

export async function addClientPhone(_prev: DetailState, formData: FormData): Promise<DetailState> {
  const gate = await signedIn();
  if ("error" in gate) return gate.error;
  const clientId = String(formData.get("id") ?? "");
  const phone = String(formData.get("phone") ?? "").trim();
  const label = String(formData.get("label") ?? "Mobile");
  const note = String(formData.get("note") ?? "").trim();
  if (!phone) return { error: "What is the number?", ok: null };

  const { error } = await gate.supabase.rpc("add_client_phone", {
    p_client: clientId,
    p_label: label,
    p_phone: phone,
    p_note: note,
  });
  if (error) return refusal(error.message);
  done(clientId);
  return { error: null, ok: "Added. Record consent for it before anything is texted to it." };
}

export async function removeClientPhone(_prev: DetailState, formData: FormData): Promise<DetailState> {
  const gate = await signedIn();
  if ("error" in gate) return gate.error;
  const clientId = String(formData.get("id") ?? "");
  const phoneId = String(formData.get("phone_id") ?? "");
  const { error } = await gate.supabase.rpc("remove_client_phone", { p_phone: phoneId });
  if (error) return refusal(error.message);
  done(clientId);
  return { error: null, ok: "Taken off the record." };
}

export async function setTextingNumber(_prev: DetailState, formData: FormData): Promise<DetailState> {
  const gate = await signedIn();
  if ("error" in gate) return gate.error;
  const clientId = String(formData.get("id") ?? "");
  const phone = String(formData.get("phone") ?? "").trim();
  const { error } = await gate.supabase.rpc("set_texting_number", {
    p_client: clientId,
    p_phone: phone,
  });
  if (error) return refusal(error.message);
  done(clientId);
  return { error: null, ok: "Texts go to that number now. The other one is still on the record." };
}

export async function addClientContact(_prev: DetailState, formData: FormData): Promise<DetailState> {
  const gate = await signedIn();
  if ("error" in gate) return gate.error;
  const clientId = String(formData.get("id") ?? "");
  const { error } = await gate.supabase.rpc("add_client_contact", {
    p_client: clientId,
    p_name: String(formData.get("name") ?? "").trim(),
    p_relationship: String(formData.get("relationship") ?? "").trim(),
    p_phone: String(formData.get("phone") ?? "").trim(),
    p_label: String(formData.get("label") ?? "Mobile"),
    p_email: String(formData.get("email") ?? "").trim(),
    p_receives_updates: formData.get("receives_updates") === "on",
    p_may_speak_for: formData.get("may_speak_for") === "on",
  });
  if (error) return refusal(error.message);
  done(clientId);
  return {
    error: null,
    ok: "Added. A text from their number files on this client, labelled with who sent it.",
  };
}

export async function editClientContact(_prev: DetailState, formData: FormData): Promise<DetailState> {
  const gate = await signedIn();
  if ("error" in gate) return gate.error;
  const clientId = String(formData.get("id") ?? "");
  const { error } = await gate.supabase.rpc("edit_client_contact", {
    p_contact: String(formData.get("contact_id") ?? ""),
    p_name: String(formData.get("name") ?? "").trim(),
    p_relationship: String(formData.get("relationship") ?? "").trim(),
    p_phone: String(formData.get("phone") ?? "").trim(),
    p_label: String(formData.get("label") ?? "Mobile"),
    p_email: String(formData.get("email") ?? "").trim(),
    p_receives_updates: formData.get("receives_updates") === "on",
    p_may_speak_for: formData.get("may_speak_for") === "on",
    p_note: String(formData.get("note") ?? "").trim(),
  });
  if (error) return refusal(error.message);
  done(clientId);
  return { error: null, ok: "Saved." };
}

export async function removeClientContact(_prev: DetailState, formData: FormData): Promise<DetailState> {
  const gate = await signedIn();
  if ("error" in gate) return gate.error;
  const clientId = String(formData.get("id") ?? "");
  const { error } = await gate.supabase.rpc("remove_client_contact", {
    p_contact: String(formData.get("contact_id") ?? ""),
    p_reason: String(formData.get("reason") ?? "").trim(),
  });
  if (error) return refusal(error.message);
  done(clientId);
  return {
    error: null,
    ok: "Off the record. What they sent keeps their name on it.",
  };
}

/**
 * Consent for one number.
 *
 * The same action the Admin screen uses, because it is the same decision:
 * somebody asked a person whether this number may be texted and wrote down
 * what they said. Granting needs a note saying how it was given, which the
 * database insists on - it is the only evidence there is.
 */
export async function recordNumberConsent(_prev: DetailState, formData: FormData): Promise<DetailState> {
  const gate = await signedIn();
  if ("error" in gate) return gate.error;
  const clientId = String(formData.get("id") ?? "");
  const phone = String(formData.get("phone") ?? "").trim();
  const state = String(formData.get("state") ?? "");
  const method = String(formData.get("method") ?? "Verbal");
  const note = String(formData.get("note") ?? "").trim();
  if (!phone) return { error: "Which number?", ok: null };

  const { error } = await gate.supabase.rpc("set_sms_consent", {
    p_client_id: clientId,
    p_phone: phone,
    p_state: state,
    p_method: state === "Granted" ? method : "Staff",
    p_note: note,
  });
  if (error) return refusal(error.message);
  done(clientId);
  return {
    error: null,
    ok:
      state === "Granted"
        ? "Recorded. That number can be texted now."
        : "Recorded. Nothing will be sent to that number.",
  };
}
