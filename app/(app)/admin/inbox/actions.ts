"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";
import { CAN_EDIT_BILLING, CAN_EDIT_CLIENTS } from "@/lib/constants";

export type InboxState = { error: string | null; ok: string | null };

const CAN_REVIEW = ["Admin", "Billing", "Job Search", "Reports"];

/**
 * Say which client a folder belongs to.
 *
 * Remembered, so it is answered once. The alternative — matching "Brienne"
 * to a client called Brienne Taylor by looking at first names — is how one
 * client's authorization lands on another's record, and the eleven folders
 * that need this are eleven clicks, once.
 */
export async function mapFolder(_prev: InboxState, formData: FormData): Promise<InboxState> {
  const me = await getCurrentStaff();
  if (!me || !CAN_EDIT_CLIENTS.includes(me.role)) {
    return { error: "Your role does not change client records.", ok: null };
  }

  const folder = String(formData.get("folder") ?? "").trim();
  const clientId = String(formData.get("client_id") ?? "").trim();
  const notAClient = formData.get("not_a_client") === "yes";

  if (!folder) return { error: "Which folder?", ok: null };
  if (!clientId && !notAClient) return { error: "Whose folder is it?", ok: null };

  const supabase = await createClient();

  const { error } = await supabase.from("inbox_folder_map").upsert(
    {
      folder_name: folder,
      client_id: notAClient ? null : clientId,
      not_a_client: notAClient,
      mapped_by: me.id,
    },
    { onConflict: "folder_name" },
  );

  if (error) return { error: error.message, ok: null };

  // Everything already waiting from that folder catches up.
  if (!notAClient) {
    await supabase
      .from("inbox_documents")
      .update({ client_id: clientId })
      .eq("folder_name", folder)
      .is("client_id", null);
  }

  revalidatePath("/admin/inbox");
  return {
    error: null,
    ok: notAClient
      ? `"${folder}" is not a client. Nothing from it will be filed.`
      : `"${folder}" belongs to that client, and everything waiting from it now knows.`,
  };
}

/**
 * File a document against the client.
 *
 * The PDF is already stored; this puts it on the client's Files tab where
 * somebody would look for it, and marks the inbox entry done. Nothing about
 * the client's record changes — a USOR form arriving does not tell us the
 * form was completed, only that a copy exists.
 */
export async function fileDocument(_prev: InboxState, formData: FormData): Promise<InboxState> {
  const me = await getCurrentStaff();
  if (!me || !CAN_REVIEW.includes(me.role)) {
    return { error: "Your role does not file documents.", ok: null };
  }

  const id = String(formData.get("document_id") ?? "");
  const category = String(formData.get("category") ?? "Other");

  const supabase = await createClient();
  const { data: doc } = await supabase
    .from("inbox_documents")
    .select("id, client_id, filename, storage_path, size_bytes, state")
    .eq("id", id)
    .maybeSingle();

  if (!doc) return { error: "That document is not in the inbox.", ok: null };
  if (doc.state !== "Pending") return { error: "That one has already been dealt with.", ok: null };
  if (!doc.client_id) return { error: "Say whose folder it is first.", ok: null };

  if (!doc.storage_path) return { error: "That document has no stored file.", ok: null };

  const { error } = await supabase.from("attachments").insert({
    client_id: doc.client_id,
    storage_path: doc.storage_path,
    filename: doc.filename,
    mime_type: "application/pdf",
    size_bytes: doc.size_bytes,
    category,
    note: "From the documents folder",
    uploaded_by: me.id,
    uploaded_by_name: me.name,
  });

  if (error) return { error: error.message, ok: null };

  await supabase
    .from("inbox_documents")
    .update({
      state: "Filed",
      decided_by: me.id,
      decided_at: new Date().toISOString(),
      outcome: `Filed as ${category}`,
    })
    .eq("id", id);

  revalidatePath("/admin/inbox");
  revalidatePath(`/clients/${doc.client_id}`);
  return { error: null, ok: `Filed against the client as ${category}.` };
}

/** Set it aside, with a reason — a template, a duplicate, something personal. */
export async function ignoreDocument(_prev: InboxState, formData: FormData): Promise<InboxState> {
  const me = await getCurrentStaff();
  if (!me || !CAN_REVIEW.includes(me.role)) {
    return { error: "Your role does not review the inbox.", ok: null };
  }

  const id = String(formData.get("document_id") ?? "");
  const reason = String(formData.get("reason") ?? "").trim();
  if (!reason) return { error: "Say why, or nobody will know whether to look again.", ok: null };

  const supabase = await createClient();
  const { error } = await supabase
    .from("inbox_documents")
    .update({
      state: "Ignored",
      decided_by: me.id,
      decided_at: new Date().toISOString(),
      outcome: reason,
    })
    .eq("id", id)
    .eq("state", "Pending");

  if (error) return { error: error.message, ok: null };

  revalidatePath("/admin/inbox");
  return { error: null, ok: "Set aside. The file stays where it is on the machine." };
}

/**
 * Mark an invoice paid by a warrant.
 *
 * One invoice, chosen by a person from the candidates the amounts suggested.
 * Never applied automatically: a warrant paying three invoices and a fourth
 * that happens to share a total is exactly the coincidence that would mark
 * the wrong one paid, and the error would surface as a chase for money
 * already received.
 */
export async function matchWarrant(_prev: InboxState, formData: FormData): Promise<InboxState> {
  const me = await getCurrentStaff();
  if (!me || !CAN_EDIT_BILLING.includes(me.role)) {
    return { error: "Only Admin and Billing settle invoices.", ok: null };
  }

  const id = String(formData.get("document_id") ?? "");
  const invoiceId = String(formData.get("invoice_id") ?? "");
  const paidOn = String(formData.get("paid_on") ?? "").trim();
  const warrant = String(formData.get("warrant") ?? "").trim();

  if (!invoiceId) return { error: "Which invoice does it pay?", ok: null };
  if (!paidOn) return { error: "What date was it paid?", ok: null };

  const supabase = await createClient();

  const { error } = await supabase
    .from("invoices")
    .update({ status: "Paid", paid_date: paidOn, warrant })
    .eq("id", invoiceId)
    .eq("status", "Sent");

  if (error) return { error: error.message, ok: null };

  const { data: doc } = await supabase
    .from("inbox_documents")
    .select("client_id, storage_path, filename, size_bytes")
    .eq("id", id)
    .maybeSingle();

  // The warrant itself goes on the client's file, where somebody chasing the
  // payment later would look for it.
  if (doc?.client_id && doc.storage_path) {
    await supabase.from("attachments").insert({
      client_id: doc.client_id,
      storage_path: doc.storage_path,
      filename: doc.filename,
      mime_type: "application/pdf",
      size_bytes: doc.size_bytes,
      category: "Invoice",
      note: warrant ? `Warrant ${warrant}` : "Warrant",
      uploaded_by: me.id,
      uploaded_by_name: me.name,
    });
  }

  await supabase
    .from("inbox_documents")
    .update({
      state: "Filed",
      decided_by: me.id,
      decided_at: new Date().toISOString(),
      outcome: `Matched to an invoice, paid ${paidOn}`,
    })
    .eq("id", id);

  revalidatePath("/admin/inbox");
  revalidatePath("/billing");
  revalidatePath("/billing/revenue");
  return { error: null, ok: `Invoice marked paid ${paidOn}.` };
}
