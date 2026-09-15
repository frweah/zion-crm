"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";
import { CAN_EDIT_BILLING, CAN_EDIT_CLIENTS, SERVICE_TYPES } from "@/lib/constants";
import { describeConfirmation } from "@/lib/authorization-confirmation";

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

  revalidatePath("/admin/documents");
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
    .select("id, client_id, filename, storage_path, size_bytes, state, kind")
    .eq("id", id)
    .maybeSingle();

  if (!doc) return { error: "That document is not in the inbox.", ok: null };
  if (doc.state !== "Pending") return { error: "That one has already been dealt with.", ok: null };
  // Checked before anything is written, so a stub never lands on a client's
  // record as a filed copy while the database refuses to close it here.
  if (doc.kind === "Warrant") {
    return { error: "A warrant stub is read on Billing → Invoices, where every line is checked; it is not filed from the inbox.", ok: null };
  }
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

  revalidatePath("/admin/documents");
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

  revalidatePath("/admin/documents");
  return { error: null, ok: "Set aside. The file stays where it is on the machine." };
}

// A warrant stub is not settled here. There used to be a way to mark an
// invoice paid from one by amount; that skipped the checks every stub now goes
// through in the warrant pipeline, and the database refuses a person filing,
// setting aside or reclassifying one (public.inbox_warrant_guard).

/**
 * Put a document on the authorization a person chose for it.
 *
 * For the invoices and authorizations whose names could not settle which
 * authorization they belong to. The rules are the database's
 * (public.link_document_to_authorization): the same client's authorization
 * only, one authorization per file, and an invoice touches no dates.
 */
export async function linkNamedDocument(_prev: InboxState, formData: FormData): Promise<InboxState> {
  const me = await getCurrentStaff();
  if (!me || !CAN_EDIT_BILLING.includes(me.role)) {
    return { error: "Only Admin and Billing put a document on an authorization.", ok: null };
  }

  const docId = String(formData.get("document_id") ?? "");
  const authId = String(formData.get("auth_id") ?? "");
  const category = String(formData.get("category") ?? "") === "Authorization" ? "Authorization" : "Invoice";
  if (!docId) return { error: "Which document?", ok: null };
  if (!authId) return { error: "Which authorization?", ok: null };

  const supabase = await createClient();
  const { error } = await supabase.rpc("link_document_to_authorization", {
    p_doc: docId,
    p_auth: authId,
    p_category: category,
    p_start: null,
    p_end: null,
    p_outcome: null,
    p_ocr: false,
  });

  if (error) return { error: error.message, ok: null };

  revalidatePath("/admin/documents");
  revalidatePath("/clients", "layout");
  return {
    error: null,
    ok:
      category === "Invoice"
        ? "On the authorization as billed — paid if a payment for it is on file."
        : "Attached to the authorization.",
  };
}

/**
 * The real authorization for an imported placeholder.
 *
 * Confirming it as new would leave the placeholder's carried hours behind on a
 * second authorization for the same service. This gives the placeholder the
 * real number instead; public.replace_placeholder_authorization refuses a real
 * authorization, another client's, and a number already on file, and logs it.
 */
export async function replacePlaceholder(_prev: InboxState, formData: FormData): Promise<InboxState> {
  const me = await getCurrentStaff();
  if (!me || !CAN_EDIT_BILLING.includes(me.role)) {
    return { error: "Only Admin and Billing replace a placeholder.", ok: null };
  }

  const str = (k: string) => String(formData.get(k) ?? "").trim();
  if (!str("document_id") || !str("placeholder_id")) return { error: "Which document and placeholder?", ok: null };
  if (!str("number")) return { error: "Give the authorization's real number.", ok: null };

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("replace_placeholder_authorization", {
    p_doc: str("document_id"),
    p_placeholder: str("placeholder_id"),
    p_number: str("number"),
    p_start: str("start_date") || null,
    p_end: str("end_date") || null,
  });
  if (error) return { error: error.message, ok: null };

  const row = Array.isArray(data) ? data[0] : null;
  revalidatePath("/admin/documents");
  revalidatePath("/billing");
  revalidatePath("/clients", "layout");
  return {
    error: null,
    ok: `The placeholder is now ${row?.auth_number ?? str("number")}, with its hours, and the PDF is on it.${
      row?.conflicts ? ` Dates kept as they were: ${row.conflicts}.` : ""
    }`,
  };
}

/**
 * Confirm an authorization that arrived in the inbox.
 *
 * What matters happens in public.confirm_authorization_document: the PDF goes
 * on the authorization on file for that number — never a second one — blank
 * dates are filled and dates on file are kept, and nothing crosses clients.
 * This reads the form, sends it, and says what happened.
 */
export async function confirmAuthorization(
  _prev: InboxState,
  formData: FormData,
): Promise<InboxState> {
  const me = await getCurrentStaff();
  if (!me || !CAN_EDIT_BILLING.includes(me.role)) {
    return { error: "Only Admin and Billing confirm an authorization.", ok: null };
  }

  const str = (k: string) => String(formData.get(k) ?? "").trim();
  const docId = str("document_id");
  const authId = str("auth_id");
  const serviceType = str("service_type");
  const rate = str("rate");
  const hours = str("total_hours");

  if (!docId) return { error: "Which document?", ok: null };
  if (!authId && !str("number")) {
    return { error: "Which authorization is it? Choose one on file, or give its number.", ok: null };
  }
  if (!authId && serviceType && !(SERVICE_TYPES as readonly string[]).includes(serviceType)) {
    return {
      error: "Choose the service from the list — it decides which USOR forms are required.",
      ok: null,
    };
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("confirm_authorization_document", {
    p_attachment: null,
    p_doc: docId,
    p_auth: authId || null,
    p_number: authId ? null : str("number"),
    p_service_type: serviceType || null,
    p_rate_type: str("rate_type") || null,
    p_rate: rate ? Number(rate) : null,
    p_total_hours: hours ? Number(hours) : null,
    p_start: str("start_date") || null,
    p_end: str("end_date") || null,
  });

  if (error) return { error: error.message, ok: null };

  revalidatePath("/admin/documents");
  revalidatePath("/billing");
  revalidatePath("/clients", "layout");
  return { error: null, ok: describeConfirmation(Array.isArray(data) ? data[0] : null) };
}
