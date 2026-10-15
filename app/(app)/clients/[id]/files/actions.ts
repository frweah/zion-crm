"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { getCurrentStaff } from "@/lib/session";

export type FileState = { error: string | null; ok: string | null; url?: string };

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
  const documentDate = String(formData.get("document_date") ?? "").trim();
  const sha256 = String(formData.get("sha256") ?? "").trim();

  if (!storagePath || !filename) {
    return { error: "The upload did not complete. Nothing was recorded.", ok: null };
  }
  // The type is not checked here any more: client_file_categories is the
  // list (0203) and attachments.category is a foreign key to it, so an
  // unknown one is refused by the database rather than by a copy of the list
  // kept in this file. That copy is what drifted last time.
  if (documentDate && !/^\d{4}-\d{2}-\d{2}$/.test(documentDate)) {
    return { error: "That date does not look right.", ok: null };
  }

  const supabase = await createClient();
  const { error } = await supabase.from("attachments").insert({
    client_id: clientId,
    storage_path: storagePath,
    filename,
    mime_type: String(formData.get("mime_type") ?? ""),
    size_bytes: Number(formData.get("size_bytes") ?? 0),
    category,
    restricted,
    // The date on the paper, which is not the date it was uploaded -
    // created_at records that by itself (0202).
    document_date: documentDate || undefined,
    sha256: sha256 || null,
    note: String(formData.get("note") ?? "").trim(),
    uploaded_by: me.id,
    uploaded_by_name: me.name,
  });

  if (error) {
    // The file is in storage but unrecorded, so it is invisible everywhere.
    // Remove it rather than leave a document nobody can find or delete.
    await supabase.storage.from("client-files").remove([storagePath]);
    // The fingerprint index (0202): this client already has these exact
    // bytes, which is somebody filing the same scan twice rather than an
    // error they can do anything about.
    const twice = error.code === "23505" && /attachments_one_copy_per_client/.test(error.message);
    return {
      error: twice
        ? "This client already has that exact file on their record. Nothing was added."
        : restricted
          ? "Restricted documents can only be added by Admin, Intake & Client Reports, or this client's assigned staff member. The file was not kept."
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

/**
 * Removes a file and its record.
 *
 * The row delete goes first and through the RLS-bound client, so the database
 * decides whether this person may remove it — Admin, or whoever uploaded it.
 * Only once that has passed does the object go, and it goes through the
 * Storage API with the service role, because the storage delete policy keys
 * off the attachment row that no longer exists.
 *
 * This used to be a database trigger. It could not have worked: Supabase
 * refuses direct DELETEs against storage.objects, so removing a file raised an
 * error instead of removing anything. See migration 0020.
 */
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
    .select("filename, storage_path")
    .maybeSingle();

  if (error) return { error: error.message, ok: null };
  if (!data) {
    return { error: "Only Admin or whoever uploaded a file can remove it.", ok: null };
  }

  const { error: objectError } = await createAdminClient()
    .storage.from("client-files")
    .remove([data.storage_path]);

  revalidatePath(`/clients/${clientId}`);

  if (objectError) {
    // The record is gone, so the file is unreachable through the app, but it
    // is still sitting in the bucket. Say so rather than report a clean
    // removal: somebody has to go and delete it.
    console.error("attachment object not removed", data.storage_path, objectError);
    return {
      error: `${data.filename} was removed from the client's file, but the stored copy could not be deleted (${objectError.message}). Tell the administrator.`,
      ok: null,
    };
  }

  return { error: null, ok: `${data.filename} removed.` };
}

/**
 * Correct a document's name or its date (owner, 15 Oct 2026).
 *
 * The name is what the file is called on the record, which starts as the
 * filename off the person's machine and is very often not what anybody would
 * call it - "scan_0012.pdf" tells nobody anything. The date is the date on the
 * paper; the upload date is created_at and is not editable, because it is a
 * fact about this system rather than about the document.
 *
 * Admin, or whoever uploaded it. The database decides that - the update policy
 * added in 0202 is the same test the delete policy already used - so a person
 * who may not is told by the row coming back empty rather than by this file
 * guessing at the rule.
 *
 * Both changes are logged with who made them, by the trigger on the table.
 */
export async function editAttachment(
  _prev: FileState,
  formData: FormData,
): Promise<FileState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const id = String(formData.get("attachment_id") ?? "");
  const clientId = String(formData.get("client_id") ?? "");
  const filename = String(formData.get("filename") ?? "").trim();
  const documentDate = String(formData.get("document_date") ?? "").trim();

  if (!filename) return { error: "A document needs a name.", ok: null };
  if (!/^\d{4}-\d{2}-\d{2}$/.test(documentDate)) {
    return { error: "That date does not look right.", ok: null };
  }

  const supabase = await createClient();
  const { data, error } = await supabase
    .from("attachments")
    .update({ filename, document_date: documentDate })
    .eq("id", id)
    .select("id")
    .maybeSingle();

  if (error) return { error: error.message, ok: null };
  if (!data) {
    return { error: "Only Admin or whoever uploaded a file can rename or redate it.", ok: null };
  }

  revalidatePath(`/clients/${clientId}`);
  return { error: null, ok: "Saved." };
}
