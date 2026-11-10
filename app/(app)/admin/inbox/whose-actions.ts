"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";
import { can } from "@/lib/roles";
import type { InboxState } from "./actions";

/**
 * Whose a waiting document is (C3, 9 November 2026).
 *
 * A hundred and eight documents were waiting with no client against them and
 * nothing in the practice could give them one: the inbox offered one answer,
 * mapping a whole folder to a client, which is right for a folder named after
 * somebody and useless for the ninety-odd that arrived by email.
 *
 * Neither of these files anything. They say whose the document is, and the
 * doors that file and confirm are the ones that were already there.
 */

const done = (clientId?: string) => {
  revalidatePath("/admin/documents");
  revalidatePath("/billing");
  if (clientId) revalidatePath(`/clients/${clientId}`);
};

const refusal = (message: string) => ({
  error: message.replace(/^.*?:\s*/, "").trim() || message,
  ok: null,
});

async function hands(): Promise<{ error: InboxState } | { supabase: Awaited<ReturnType<typeof createClient>> }> {
  const me = await getCurrentStaff();
  if (!me) return { error: { error: "You are not signed in.", ok: null } };
  if (me.role !== "Admin" && !can(me, "billing", "edit")) {
    return { error: { error: "Only Admin and Billing say whose a document is.", ok: null } };
  }
  return { supabase: await createClient() };
}

export async function assignDocument(_prev: InboxState, formData: FormData): Promise<InboxState> {
  const gate = await hands();
  if ("error" in gate) return gate.error;
  const clientId = String(formData.get("client_id") ?? "");
  if (!clientId) return { error: "Choose the client it belongs to.", ok: null };

  const { error } = await gate.supabase.rpc("assign_document_to_client", {
    p_doc: String(formData.get("document_id") ?? ""),
    p_client: clientId,
  });
  if (error) return refusal(error.message);
  done(clientId);
  return { error: null, ok: "On their record now — file it, or confirm the authorization." };
}

export async function clientFromDocument(_prev: InboxState, formData: FormData): Promise<InboxState> {
  const gate = await hands();
  if ("error" in gate) return gate.error;

  const name = String(formData.get("name") ?? "").trim();
  if (!name) return { error: "What is their name, as the document has it?", ok: null };

  const { data, error } = await gate.supabase.rpc("client_from_document", {
    p_doc: String(formData.get("document_id") ?? ""),
    p_name: name,
    p_counselor: String(formData.get("counselor_id") ?? "") || null,
    p_office: String(formData.get("office") ?? "").trim(),
    p_agency_id: String(formData.get("agency_id") ?? "").trim(),
    p_no_phone_reason: String(formData.get("no_phone_reason") ?? "").trim(),
  });
  if (error) return refusal(error.message);
  done(typeof data === "string" ? data : undefined);
  return {
    error: null,
    ok: `${name} is on the caseload, and the document is on their record. Add a number when you have one.`,
  };
}
