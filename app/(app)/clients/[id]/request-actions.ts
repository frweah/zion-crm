"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { notifyPortal } from "@/lib/portal/notify";

/**
 * Asking a client for a document through the portal (portal brief, section 3).
 *
 * Every rule is the database's (0228): who may ask, that the client has
 * portal access, that a returned upload says why. What this file adds is the
 * notice afterwards - the request is posted into the client's portal thread,
 * and the client is told, without content, that something is waiting.
 */
export type RequestState = { error: string | null; ok: string | null };

async function tell(conversationIds: string[] | null | undefined) {
  const supabase = await createClient();
  for (const id of conversationIds ?? []) await notifyPortal(supabase, id);
}

export async function askForDocument(_prev: RequestState, formData: FormData): Promise<RequestState> {
  const supabase = await createClient();
  const clientId = String(formData.get("client_id") ?? "");
  const due = String(formData.get("due") ?? "").trim();
  const { data, error } = await supabase.rpc("portal_request_document", {
    p_client: clientId,
    p_item: String(formData.get("item") ?? ""),
    p_label: String(formData.get("label") ?? ""),
    p_note: String(formData.get("note") ?? ""),
    p_due: due || null,
  });
  if (error) return { error: error.message, ok: null };
  await tell(data?.[0]?.conversation_ids);
  revalidatePath(`/clients/${clientId}`);
  return { error: null, ok: "Asked. The client has been told something is waiting." };
}

export async function withdrawRequest(_prev: RequestState, formData: FormData): Promise<RequestState> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("portal_cancel_request", {
    p_request: String(formData.get("request_id") ?? ""),
  });
  if (error) return { error: error.message, ok: null };
  revalidatePath(`/clients/${String(formData.get("client_id") ?? "")}`);
  return { error: null, ok: "Withdrawn." };
}

export async function reviewUpload(_prev: RequestState, formData: FormData): Promise<RequestState> {
  const supabase = await createClient();
  const accept = formData.get("decision") === "accept";
  const { data, error } = await supabase.rpc("portal_review_request", {
    p_request: String(formData.get("request_id") ?? ""),
    p_accept: accept,
    p_reason: String(formData.get("reason") ?? ""),
  });
  if (error) return { error: error.message, ok: null };
  if (!accept) await tell(data);
  revalidatePath(`/clients/${String(formData.get("client_id") ?? "")}`);
  return { error: null, ok: accept ? "Accepted." : "Sent back, with your reason." };
}

/** Approving the client's resume, or sending it back with what to change. */
export async function reviewResume(_prev: RequestState, formData: FormData): Promise<RequestState> {
  const supabase = await createClient();
  const approve = formData.get("decision") === "approve";
  const { data, error } = await supabase.rpc("portal_review_resume", {
    p_resume: String(formData.get("resume_id") ?? ""),
    p_approve: approve,
    p_note: String(formData.get("note") ?? ""),
  });
  if (error) return { error: error.message, ok: null };
  if (!approve) await tell(data);
  revalidatePath(`/clients/${String(formData.get("client_id") ?? "")}`);
  return { error: null, ok: approve ? "Resume approved." : "Sent back, with your note." };
}
