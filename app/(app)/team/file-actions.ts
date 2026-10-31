"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { getCurrentStaff } from "@/lib/session";
import { NOTE_CATEGORIES } from "@/lib/report-shape";

export type FileState = { error: string | null; ok: string | null };

/**
 * "File to client": a message becomes a note on that client's record.
 *
 * A copy, not a move. The message stays in the thread because the thread is
 * what happened; the note is what the practice decided was worth keeping about
 * a person. Who said it is in the note, because whoever reads it in six months
 * is not whoever filed it.
 *
 * The category is chosen rather than guessed. 0266 would fill it in from the
 * client's stage, and the stage is a guess - somebody filing a message has the
 * answer in front of them, and 'Personal' narrows the note to Admin and Case
 * Manager, which is not a decision to make by omission.
 */
export async function fileMessageToClient(
  _prev: FileState,
  formData: FormData,
): Promise<FileState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const message = String(formData.get("message_id") ?? "");
  const client = String(formData.get("client_id") ?? "");
  const category = String(formData.get("category") ?? "");

  if (!message) return { error: "Which message?", ok: null };
  if (!client) return { error: "Choose the client it belongs to.", ok: null };
  if (!NOTE_CATEGORIES.includes(category as never)) {
    return { error: "Say which service this is about.", ok: null };
  }

  const supabase = await createClient();
  const { error } = await supabase.rpc("file_message_to_client", {
    p_message: message,
    p_client: client,
    p_category: category,
  });
  if (error) return { error: error.message, ok: null };

  revalidatePath(`/clients/${client}`);
  revalidatePath("/team");
  return { error: null, ok: "On the record." };
}

/**
 * The same for a file somebody dropped in the thread.
 *
 * A file attached by reference from a client's record is already on that
 * record and there is nothing to do; this is the other case, where the file
 * arrived in the thread and belongs on somebody's file.
 *
 * Storage cannot copy an object from SQL, so the bytes are copied here, with
 * the service key, and then `file_chat_file_to_client` checks the rules and
 * writes the attachment row. Copied rather than moved for the same reason as a
 * message: what was sent in the thread stays in the thread.
 */
export async function fileChatFileToClient(
  _prev: FileState,
  formData: FormData,
): Promise<FileState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const file = String(formData.get("file_id") ?? "");
  const client = String(formData.get("client_id") ?? "");
  const category = String(formData.get("category") ?? "Other").trim() || "Other";

  if (!file) return { error: "Which file?", ok: null };
  if (!client) return { error: "Choose the client it belongs to.", ok: null };

  const supabase = await createClient();

  // Read as this person, so somebody outside the thread gets nothing to copy.
  const { data: row, error: readError } = await supabase
    .from("chat_files")
    .select("storage_path, filename")
    .eq("id", file)
    .maybeSingle();
  if (readError) return { error: readError.message, ok: null };
  if (!row) return { error: "That file is not in a thread you are in.", ok: null };

  // The bytes move with the service key, because one bucket cannot be copied
  // to another as the person: they can read the thread's file and they are not
  // granted a write into the client's bucket at a path that has no attachment
  // row yet.
  const admin = createAdminClient();
  const target = `clients/${client}/${Date.now()}-${row.filename.replace(/[^\w.-]+/g, "-")}`;
  const { data: blob, error: downloadError } = await admin.storage
    .from("chat-files")
    .download(row.storage_path);
  if (downloadError) return { error: downloadError.message, ok: null };

  const { error: uploadError } = await admin.storage
    .from("client-files")
    .upload(target, blob, { contentType: blob.type || undefined, upsert: false });
  if (uploadError) return { error: uploadError.message, ok: null };

  const { error } = await supabase.rpc("file_chat_file_to_client", {
    p_file: file,
    p_client: client,
    p_path: target,
    p_category: category,
  });
  if (error) {
    // The row was refused, so the copy should not be left behind pretending to
    // be a document on somebody's record.
    await admin.storage.from("client-files").remove([target]);
    return { error: error.message, ok: null };
  }

  revalidatePath(`/clients/${client}`);
  revalidatePath("/team");
  return { error: null, ok: "On the record." };
}

/**
 * Admin taking a message off everybody else's screen, or putting it back.
 *
 * The words are kept either way and Admin can still read them: a thing taken
 * down is still something that was said.
 */
export async function hideMessage(_prev: FileState, formData: FormData): Promise<FileState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const reason = String(formData.get("reason") ?? "").trim();
  if (!reason) return { error: "Say why it is coming down.", ok: null };

  const supabase = await createClient();
  const { error } = await supabase.rpc("hide_message", {
    p_message: String(formData.get("message_id") ?? ""),
    p_hidden: String(formData.get("hidden") ?? "") === "1",
    p_reason: reason,
  });
  if (error) return { error: error.message, ok: null };

  revalidatePath("/team");
  return { error: null, ok: "Done." };
}
