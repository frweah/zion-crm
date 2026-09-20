"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { getCurrentStaff } from "@/lib/session";

/**
 * A person's signature, uploaded once and stamped on what they sign.
 *
 * Through the server rather than straight to storage, unlike a client's
 * documents: a signature is small, and the alternative is a storage policy
 * that lets a browser write into the staff tier, which is a much larger door
 * to open for a 40 KB image.
 *
 * It is not the signature. The signature is the completion recorded against
 * their name, with the time the database stamped on it; this is what that
 * looks like on the page USOR receives.
 */
export type SignatureState = { error: string | null; ok: string | null };

const MAX_BYTES = 500 * 1024;
const TYPES: Record<string, string> = { "image/png": "png", "image/jpeg": "jpg" };

export async function uploadSignature(_prev: SignatureState, formData: FormData): Promise<SignatureState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const file = formData.get("file");
  if (!(file instanceof File) || file.size === 0) {
    return { error: "Choose an image of your signature first.", ok: null };
  }
  const ext = TYPES[file.type];
  if (!ext) {
    return { error: "A signature has to be a PNG or a JPEG. Sign on paper, photograph it, and upload that.", ok: null };
  }
  if (file.size > MAX_BYTES) {
    return {
      error: `That image is ${Math.round(file.size / 1024)} KB and the limit is 500 KB. A photograph of a signature does not need to be large.`,
      ok: null,
    };
  }

  const bytes = new Uint8Array(await file.arrayBuffer());
  // What the browser calls a file and what the file is are two things. The
  // first bytes of a PNG and a JPEG are fixed, and checking them here is the
  // difference between "that is not a signature image" now and a form that
  // quietly goes out without one later.
  const png = bytes.length > 8 && bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47;
  const jpg = bytes.length > 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
  if (!(ext === "png" ? png : jpg)) {
    return { error: "That file is not the image it claims to be. Save it again as a PNG or a JPEG and try once more.", ok: null };
  }

  const admin = createAdminClient();
  const path = `signatures/${me.id}.${ext}`;

  const { error: uploadError } = await admin.storage
    .from("staff-files")
    .upload(path, bytes, { contentType: file.type, upsert: true });
  if (uploadError) {
    return { error: `It could not be saved: ${uploadError.message}`, ok: null };
  }

  const supabase = await createClient();
  const { error } = await supabase.rpc("set_my_signature", { p_path: path });
  if (error) return { error: error.message, ok: null };

  revalidatePath("/paperwork");
  revalidatePath("/dashboard");
  return { error: null, ok: "Saved. It will be stamped on the forms you sign from now on." };
}

export async function removeSignature(): Promise<void> {
  const me = await getCurrentStaff();
  if (!me) return;
  const supabase = await createClient();
  const { data: row } = await supabase.from("staff_signatures").select("storage_path").maybeSingle();
  await supabase.rpc("clear_my_signature");
  if (row?.storage_path) {
    await createAdminClient().storage.from("staff-files").remove([row.storage_path]);
  }
  revalidatePath("/paperwork");
  revalidatePath("/dashboard");
}

/** A short-lived link to their own signature, to show them what is on file. */
export async function signaturePreview(): Promise<string | null> {
  const me = await getCurrentStaff();
  if (!me) return null;
  const supabase = await createClient();
  const { data: row } = await supabase.from("staff_signatures").select("storage_path").maybeSingle();
  if (!row) return null;
  const { data } = await createAdminClient().storage.from("staff-files").createSignedUrl(row.storage_path, 120);
  return data?.signedUrl ?? null;
}
