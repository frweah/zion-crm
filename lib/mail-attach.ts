import "server-only";

import { createClient } from "@/lib/supabase/server";

/**
 * A document on the record, turned into something a message can carry.
 *
 * Attaching by reference is the point: the person picks a document that is
 * already on the client's file, and the bytes come out of storage here rather
 * than off their desktop. Nothing is uploaded, nothing is copied, and what
 * the counselor receives is the document the practice holds - not a second
 * version of it that only exists in an email.
 *
 * The storage read goes through the signed-in person's own client, so the
 * bucket policy decides whether they may have the file at all. Somebody who
 * cannot open a restricted document cannot attach it either, and that is one
 * rule in one place rather than two that have to agree.
 */

/** Graph's shape for a file on a message. */
export type FileAttachment = {
  "@odata.type": "#microsoft.graph.fileAttachment";
  name: string;
  contentType: string;
  contentBytes: string;
};

/**
 * Microsoft's limit for attachments sent with the message itself is 3 MB of
 * encoded content, and anything larger needs an upload session. The practice
 * already refuses an upload over 3 MB, so one document always fits - but four
 * of them do not, and the honest place to say so is before sending rather
 * than in Microsoft's words afterwards.
 */
export const ATTACHMENT_BUDGET = 3 * 1024 * 1024;

export async function attachmentsFromStorage(
  files: { filename: string; storage_path: string; mime_type: string }[],
): Promise<{ error: string | null; attachments: FileAttachment[] }> {
  if (files.length === 0) return { error: null, attachments: [] };

  const supabase = await createClient();
  const attachments: FileAttachment[] = [];
  let total = 0;

  for (const file of files) {
    const { data, error } = await supabase.storage.from("client-files").download(file.storage_path);
    if (error || !data) {
      return { error: `${file.filename} could not be read from the record, so nothing was sent.`, attachments: [] };
    }
    const bytes = Buffer.from(await data.arrayBuffer());
    total += Math.ceil((bytes.length * 4) / 3);
    if (total > ATTACHMENT_BUDGET) {
      return {
        error: "Those documents come to more than 3MB together — send them over two messages.",
        attachments: [],
      };
    }
    attachments.push({
      "@odata.type": "#microsoft.graph.fileAttachment",
      name: file.filename,
      contentType: file.mime_type || "application/octet-stream",
      contentBytes: bytes.toString("base64"),
    });
  }

  return { error: null, attachments };
}
