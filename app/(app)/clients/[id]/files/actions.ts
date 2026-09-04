"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";

export type FileState = { error: string | null; ok: string | null; url?: string };

const CATEGORIES = [
  "Signed USOR form",
  "Work schedule",
  "Authorization",
  "Signed intake",
  "Employer verification",
  "Invoice",
  "Other",
];

/**
 * Records a file that the browser has already put in storage.
 *
 * The upload goes straight from the browser to Supabase Storage rather than
 * through this server: a 25 MB scan has no business passing through a server
 * action, and the storage policies check the uploader just as well.
 */
export async function recordAttachment(
  _prev: FileState,
  formData: FormData,
): Promise<FileState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const clientId = String(formData.get("client_id") ?? "");
  const storagePath = String(formData.get("storage_path") ?? "");
  const filename = String(formData.get("filename") ?? "").trim();
  const category = String(formData.get("category") ?? "Other");
  const restricted = formData.get("restricted") === "on";

  if (!storagePath || !filename) {
    return { error: "The upload did not complete. Nothing was recorded.", ok: null };
  }
  if (!CATEGORIES.includes(category)) return { error: "Unknown category.", ok: null };

  const supabase = await createClient();
  const { error } = await supabase.from("attachments").insert({
    client_id: clientId,
    storage_path: storagePath,
    filename,
    mime_type: String(formData.get("mime_type") ?? ""),
    size_bytes: Number(formData.get("size_bytes") ?? 0),
    category,
    restricted,
    note: String(formData.get("note") ?? "").trim(),
    uploaded_by: me.id,
    uploaded_by_name: me.name,
  });

  if (error) {
    // The file is in storage but unrecorded, so it is invisible everywhere.
    // Remove it rather than leave a document nobody can find or delete.
    await supabase.storage.from("client-files").remove([storagePath]);
    return {
      error: restricted
        ? "Restricted documents can only be added by Admin, Intake & Reports, or this client's assigned staff member. The file was not kept."
        : error.message,
      ok: null,
    };
  }

  revalidatePath(`/clients/${clientId}`);
  return { error: null, ok: `${filename} attached.` };
}

/**
 * A short-lived link to one file.
 *
 * The bucket is private, so this is the only way to read a document, and the
 * storage policy decides whether the link can be minted at all — a staff
 * member who may not see a restricted file cannot get a URL for it.
 */
export async function getDownloadUrl(
  _prev: FileState,
  formData: FormData,
): Promise<FileState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const path = String(formData.get("storage_path") ?? "");
  const supabase = await createClient();

  const { data, error } = await supabase.storage
    .from("client-files")
    .createSignedUrl(path, 120);

  if (error || !data?.signedUrl) {
    return { error: "That file is not available to you.", ok: null };
  }

  return { error: null, ok: null, url: data.signedUrl };
}

/** Removing the record removes the file — a database trigger does the second half. */
export async function deleteAttachment(
  _prev: FileState,
  formData: FormData,
): Promise<FileState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const id = String(formData.get("attachment_id") ?? "");
  const clientId = String(formData.get("client_id") ?? "");

  const supabase = await createClient();
  const { data, error } = await supabase
    .from("attachments")
    .delete()
    .eq("id", id)
    .select("filename")
    .maybeSingle();

  if (error) return { error: error.message, ok: null };
  if (!data) {
    return { error: "Only Admin or whoever uploaded a file can remove it.", ok: null };
  }

  revalidatePath(`/clients/${clientId}`);
  return { error: null, ok: `${data.filename} removed.` };
}
