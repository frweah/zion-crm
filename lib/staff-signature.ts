import "server-only";
import { createAdminClient } from "@/lib/supabase/admin";

/**
 * The signer's own signature image, if they have uploaded one.
 *
 * Read with the service role on purpose, and it is the one read in this
 * codebase that is allowed to reach into another member of staff's files. A
 * form is signed by the person who completed it and may be sent by somebody
 * else, so the sender's client cannot be what fetches the picture - that is
 * how a form signed by one person came to carry the sender's signature over
 * the signer's name.
 *
 * Which staff id is passed is therefore the whole security of this: pass the
 * person the record says signed it, never the person who happens to be
 * signed in. Lifted out of the forms action when the monthly report needed
 * the same picture over the same kind of attestation.
 */
export async function signatureFor(
  staffId: string,
  admin: ReturnType<typeof createAdminClient> = createAdminClient(),
): Promise<{ bytes: Uint8Array; type: "png" | "jpg" } | null> {
  const { data: row } = await admin
    .from("staff_signatures")
    .select("storage_path")
    .eq("staff_id", staffId)
    .maybeSingle();
  if (!row) return null;
  const { data: file } = await admin.storage.from("staff-files").download(row.storage_path);
  if (!file) return null;
  return {
    bytes: new Uint8Array(await file.arrayBuffer()),
    type: /\.jpe?g$/i.test(row.storage_path) ? "jpg" : "png",
  };
}
