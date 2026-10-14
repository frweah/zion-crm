"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";

export type DocumentState = { error: string | null; ok: string | null; url?: string };

/** 25MB, matching the bucket. A scanned certificate is a few hundred KB. */
const MAX_BYTES = 25 * 1024 * 1024;

const ALLOWED = [
  "application/pdf",
  "image/jpeg",
  "image/png",
  "image/heic",
  "image/webp",
  "application/msword",
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
];

/**
 * Put a document on somebody's file.
 *
 * Your own, or anybody's if you are Admin — the database says the same, in
 * two places, because the row and the file are stored separately and either
 * one landing without the other is a mess to clean up.
 *
 * The file goes up first. A row pointing at a file that is not there reads as
 * a document on somebody's record and opens as an error; a file with no row
 * is invisible and harmless, and the next upload of the same name replaces it.
 */
export async function uploadStaffDocument(
  _prev: DocumentState,
  formData: FormData,
): Promise<DocumentState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const staffId = String(formData.get("staff_id") ?? "").trim() || me.id;
  const category = String(formData.get("category") ?? "").trim();
  const note = String(formData.get("note") ?? "").trim();
  const file = formData.get("file");

  if (staffId !== me.id && me.role !== "Admin") {
    return { error: "You can add to your own file; Admin can add to anybody's.", ok: null };
  }
  if (!(file instanceof File) || file.size === 0) {
    return { error: "Choose a file first.", ok: null };
  }
  if (file.size > MAX_BYTES) {
    return { error: "That file is over 25MB. Scan it at a lower resolution and try again.", ok: null };
  }
  if (!ALLOWED.includes(file.type)) {
    return {
      error: "That kind of file is not accepted — a PDF, a photograph or a Word document.",
      ok: null,
    };
  }
  if (!category) return { error: "What kind of document is it?", ok: null };

  const supabase = await createClient();

  // Checked before the file goes up: an inactive person's file is closed
  // (public.staff_record_frozen), and the row would be refused anyway.
  const { data: owner } = await supabase.from("staff").select("name, active").eq("id", staffId).maybeSingle();
  if (owner && !owner.active) {
    return { error: `${owner.name} is inactive; their file is kept as it was and nothing can be added.`, ok: null };
  }

  const { data: cat } = await supabase
    .from("staff_file_categories")
    .select("label, system_only")
    .eq("key", category)
    .maybeSingle();

  if (!cat) return { error: "Unknown kind of document.", ok: null };
  if (cat.system_only) {
    return {
      error: `A ${cat.label} is signed in the app rather than uploaded — go to Paperwork and complete one.`,
      ok: null,
    };
  }

  // Namespaced by person and stamped, so two people uploading "scan.pdf" on
  // the same day do not collide and nothing is overwritten by accident.
  const safe = file.name.replace(/[^A-Za-z0-9._-]/g, "_").slice(-80);
  const path = `${staffId}/${Date.now()}-${safe}`;

  const { error: uploadError } = await supabase.storage
    .from("staff-files")
    .upload(path, file, { contentType: file.type, upsert: false });

  if (uploadError) return { error: `That did not upload. ${uploadError.message}`, ok: null };

  const { error } = await supabase.from("staff_files").insert({
    staff_id: staffId,
    storage_path: path,
    filename: file.name,
    mime_type: file.type,
    size_bytes: file.size,
    category,
    note,
    uploaded_by: me.id,
  });

  if (error) {
    // The row was refused, so the file has no business being there either.
    await supabase.storage.from("staff-files").remove([path]);
    return { error: error.message, ok: null };
  }

  revalidatePath("/paperwork");
  revalidatePath("/admin/people", "layout"); // the People page and each person's record under it
  return { error: null, ok: `${cat.label} added.` };
}

/**
 * Open one.
 *
 * The database decides whether the link may be minted, and writes down that
 * it said so — except for somebody opening their own file, which is not an
 * event worth recording and would bury the ones that are.
 */
export async function openStaffDocument(
  _prev: DocumentState,
  formData: FormData,
): Promise<DocumentState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const id = String(formData.get("file_id") ?? "");
  const supabase = await createClient();

  const { data: allowed, error: noteError } = await supabase.rpc("note_staff_file_access", {
    p_file_id: id,
  });
  if (noteError || allowed !== true) {
    return { error: "That document is not available to you.", ok: null };
  }

  const { data: file } = await supabase
    .from("staff_files")
    .select("storage_path")
    .eq("id", id)
    .maybeSingle();

  if (!file) return { error: "That document is not on file.", ok: null };

  const { data, error } = await supabase.storage
    .from("staff-files")
    .createSignedUrl(file.storage_path, 120);

  if (error || !data?.signedUrl) return { error: "That document could not be opened.", ok: null };
  return { error: null, ok: null, url: data.signedUrl };
}

/**
 * Remove one.
 *
 * Admin only, and the file goes before the row: the trigger that used to
 * delete the object was removed in 0020 because Supabase blocks a direct
 * delete on storage.objects, so this has to do both halves itself. Row first
 * would leave the file orphaned with nothing pointing at it.
 */
export async function deleteStaffDocument(
  _prev: DocumentState,
  formData: FormData,
): Promise<DocumentState> {
  const me = await getCurrentStaff();
  if (me?.role !== "Admin") {
    return { error: "Only Admin removes a document from somebody's file.", ok: null };
  }

  const id = String(formData.get("file_id") ?? "");
  const supabase = await createClient();

  const { data: file } = await supabase
    .from("staff_files")
    .select("storage_path, filename, staff_id")
    .eq("id", id)
    .maybeSingle();

  if (!file) return { error: "That document is not on file.", ok: null };

  // Before the file is touched. The database refuses the row for somebody
  // inactive, but the file goes first here, so without this the stored copy
  // would be gone while the row that describes it stayed.
  const { data: owner } = await supabase.from("staff").select("name, active").eq("id", file.staff_id).maybeSingle();
  if (owner && !owner.active) {
    return { error: `${owner.name} is inactive; their file is kept as it was, for retention and audits.`, ok: null };
  }

  const { error: storageError } = await supabase.storage
    .from("staff-files")
    .remove([file.storage_path]);

  if (storageError) {
    return { error: `The file could not be removed. ${storageError.message}`, ok: null };
  }

  const { error } = await supabase.from("staff_files").delete().eq("id", id);
  if (error) return { error: error.message, ok: null };

  revalidatePath("/paperwork");
  revalidatePath("/admin/people", "layout"); // the People page and each person's record under it
  return { error: null, ok: `${file.filename} removed.` };
}

/**
 * Record that the originals behind an I-9 document were examined in person
 * (0100). Admin only, in the database; until then the document reads
 * "in-person inspection still required" everywhere it is shown.
 */
export async function recordInspection(_prev: DocumentState, formData: FormData): Promise<DocumentState> {
  const me = await getCurrentStaff();
  if (me?.role !== "Admin") return { error: "Only Admin records an in-person inspection.", ok: null };

  const supabase = await createClient();
  const { error } = await supabase.rpc("record_identity_inspection", {
    p_file_id: String(formData.get("file_id") ?? ""),
  });
  if (error) return { error: error.message, ok: null };

  revalidatePath("/admin/people", "layout");
  revalidatePath("/paperwork", "layout");
  return { error: null, ok: "Inspection recorded." };
}

/**
 * Replace the file behind a document, keeping the row (owner, 14 Oct 2026).
 *
 * "Admin can ... upload or replace any document on their behalf (ID,
 * certifications, signed forms), logged with who did it."
 *
 * The row stays, so whatever points at it still does - a certification, an
 * authorization's packet, an I-9 inspection. What changes is the bytes, the
 * filename and the type. The old object is removed afterwards rather than
 * before: if the new one fails to go up, the person still has the old one.
 *
 * Not for a document the app generates. A signed policy or a tax form is a
 * PDF the CRM made from what somebody signed, and swapping the bytes under
 * one would leave a signature over a document nobody signed - so those are
 * refused here, as they are on upload.
 */
export async function replaceStaffDocument(
  _prev: DocumentState,
  formData: FormData,
): Promise<DocumentState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const fileId = String(formData.get("file_id") ?? "").trim();
  const file = formData.get("file");

  if (!(file instanceof File) || file.size === 0) return { error: "Choose a file first.", ok: null };
  if (file.size > MAX_BYTES) {
    return { error: "That file is over 25MB. Scan it at a lower resolution and try again.", ok: null };
  }
  if (!ALLOWED.includes(file.type)) {
    return {
      error: "That kind of file is not accepted — a PDF, a photograph or a Word document.",
      ok: null,
    };
  }

  const supabase = await createClient();
  const { data: row } = await supabase
    .from("staff_files")
    .select("id, staff_id, storage_path, filename, category")
    .eq("id", fileId)
    .maybeSingle();
  if (!row) return { error: "That document is not there any more.", ok: null };

  if (row.staff_id !== me.id && me.role !== "Admin") {
    return { error: "You can replace one on your own file; Admin can on anybody's.", ok: null };
  }

  const { data: owner } = await supabase
    .from("staff")
    .select("name, active")
    .eq("id", row.staff_id)
    .maybeSingle();
  if (owner && !owner.active) {
    return { error: `${owner.name} is inactive; their file is kept as it was.`, ok: null };
  }

  const { data: cat } = await supabase
    .from("staff_file_categories")
    .select("label, system_only")
    .eq("key", row.category)
    .maybeSingle();
  if (cat?.system_only) {
    return {
      error: `A ${cat.label} is produced from what somebody signed. Replacing the file under it would leave a signature over a document nobody signed — complete a new one in Paperwork instead.`,
      ok: null,
    };
  }

  const safe = file.name.replace(/[^A-Za-z0-9._-]/g, "_").slice(-80);
  const path = `${row.staff_id}/${Date.now()}-${safe}`;
  const { error: uploadError } = await supabase.storage
    .from("staff-files")
    .upload(path, file, { contentType: file.type, upsert: false });
  if (uploadError) return { error: `That did not upload. ${uploadError.message}`, ok: null };

  const was = row.filename;
  const { error } = await supabase
    .from("staff_files")
    .update({
      storage_path: path,
      filename: file.name,
      mime_type: file.type,
      size_bytes: file.size,
    })
    .eq("id", fileId);

  if (error) {
    // The row did not move, so the old file is still the document. Take the
    // new one back out rather than leaving it orphaned in the bucket.
    await supabase.storage.from("staff-files").remove([path]);
    return { error: error.message, ok: null };
  }

  // Only now: the row points at the new bytes, so losing the old ones is safe.
  await supabase.storage.from("staff-files").remove([row.storage_path]);

  await supabase.rpc("log_staff_document", {
    p_staff: row.staff_id,
    p_action: "Edited",
    p_changes: { filename: { from: was, to: file.name } },
    p_note: String(formData.get("note") ?? "").trim(),
  });

  revalidatePath(`/admin/people/${row.staff_id}`);
  revalidatePath("/paperwork");
  return { error: null, ok: `Replaced. The record still points at it, and the change is logged.` };
}
