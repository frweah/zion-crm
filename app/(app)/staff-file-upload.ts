"use client";

import { createClient } from "@/lib/supabase/client";

/**
 * A staff document goes from the browser straight to storage.
 *
 * It used to go through a server action, and that could never have worked for
 * the sizes the screens promise. Vercel caps a request body at 4.5 MB in its
 * own infrastructure, and `serverActions.bodySizeLimit` cannot raise it — so
 * the 25 MB the upload screen offered was refused before any of our code ran,
 * and what the person saw was a 413 rather than the sentence we wrote for
 * them. That is Melanie's failure from 30 September, still live on this path
 * after the one it was found on was fixed (stress test finding 7, owner
 * 16 Oct 2026).
 *
 * The client record already works this way — see add-file.tsx, whose comment
 * says a 25 MB scan has no business passing through a server action. This is
 * the same thing for the other side of the house.
 *
 * The storage policy added in 0198 already allows exactly this: an active
 * member of staff may write into their own folder, and an Admin into
 * anybody's. Nothing about who may upload changes here; only which machine
 * sends the bytes.
 */

/** The bucket's own limit (0015). Now reachable, because nothing stands between. */
export const STAFF_FILE_MAX_BYTES = 25 * 1024 * 1024;

export const ALLOWED_STAFF_FILE_TYPES = [
  "application/pdf",
  "image/jpeg",
  "image/png",
  "image/heic",
  "image/webp",
  "application/msword",
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
];

export function fileSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

export type PutResult = { path: string } | { error: string };

/**
 * Puts the file in the bucket and gives back where it went.
 *
 * Namespaced by person and stamped, exactly as the server action did, so two
 * people uploading "scan.pdf" on the same day do not collide — and so
 * staff_file_owner() still reads the owner out of the path.
 */
export async function putStaffFile(
  file: File,
  staffId: string,
  opts: { allowed?: string[] } = {},
): Promise<PutResult> {
  if (!file || file.size === 0) return { error: "Choose a file first." };
  if (file.size > STAFF_FILE_MAX_BYTES) {
    return {
      error: `${file.name} is ${fileSize(file.size)}. The limit is 25 MB — scan it at a lower resolution and try again.`,
    };
  }
  const allowed = opts.allowed ?? ALLOWED_STAFF_FILE_TYPES;
  if (!allowed.includes(file.type)) {
    return { error: "That kind of file is not accepted — a PDF, a photograph or a Word document." };
  }

  const safe = file.name.replace(/[^A-Za-z0-9._-]/g, "_").slice(-80);
  const path = `${staffId}/${Date.now()}-${safe}`;

  const { error } = await createClient()
    .storage.from("staff-files")
    .upload(path, file, { contentType: file.type || "application/octet-stream", upsert: false });

  if (error) {
    const message = error.message.toLowerCase();
    return {
      error:
        message.includes("mime") || message.includes("type")
          ? "That kind of file is not accepted — a PDF, a photograph or a Word document."
          : `That did not upload. ${error.message}`,
    };
  }

  return { path };
}

/** The fields a recording action needs once the bytes are already in storage. */
export function describe(file: File, path: string): Record<string, string> {
  return {
    storage_path: path,
    filename: file.name,
    mime_type: file.type,
    size_bytes: String(file.size),
  };
}
