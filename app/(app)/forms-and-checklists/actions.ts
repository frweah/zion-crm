"use server";

import { revalidatePath } from "next/cache";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { createAdminClient } from "@/lib/supabase/admin";

export type FillState = { error: string | null; ok: string | null };

export type FormField = {
  key: string;
  label: string;
  type: "text" | "long" | "yes_no" | "number" | "date" | "photo" | "signature";
  required?: boolean;
};

/**
 * Filling in one of the practice's own forms (Design language, §3).
 *
 * The answers are kept as they were given, against the client, with who
 * filled it in and when. Nothing here can be edited afterwards: it is a
 * record of what somebody saw, and one that can be rewritten later is not a
 * record.
 *
 * A photograph is shrunk in the browser before it is sent (paperwork's own
 * helper), so what arrives here is the size of a page rather than the size of
 * a camera.
 */
export async function fillForm(_prev: FillState, formData: FormData): Promise<FillState> {
  const me = await requireStaff();
  const key = String(formData.get("form_key") ?? "");
  const clientId = String(formData.get("client_id") ?? "").trim();

  const supabase = await createClient();
  const { data: form } = await supabase
    .from("practice_forms")
    .select("key, name, fields, about_a_client")
    .eq("key", key)
    .maybeSingle();
  if (!form) return { error: "That form is not one of ours.", ok: null };
  if (form.about_a_client && !clientId) return { error: "Choose the client this is about.", ok: null };

  const fields = (form.fields ?? []) as FormField[];
  const answers: Record<string, string> = {};
  for (const f of fields) {
    if (f.type === "photo" || f.type === "signature") continue;
    const value = String(formData.get(f.key) ?? "").trim();
    if (f.required && !value) return { error: `${f.label} is needed.`, ok: null };
    if (value) answers[f.key] = value;
  }

  // The photograph, where the form asks for one.
  let attachmentPath: string | null = null;
  const photo = formData.get("photo");
  if (photo instanceof File && photo.size > 0) {
    if (photo.size > 8 * 1024 * 1024) {
      return { error: "That photograph is over 8 MB even after shrinking. Take it again at a lower resolution.", ok: null };
    }
    const admin = createAdminClient();
    const stamp = new Date().toISOString().replace(/[^0-9]/g, "").slice(0, 14);
    const path = `clients/${clientId || "practice"}/forms/${key}-${stamp}.jpg`;
    const { error } = await admin.storage
      .from("client-files")
      .upload(path, new Uint8Array(await photo.arrayBuffer()), { contentType: photo.type || "image/jpeg", upsert: false });
    if (error) return { error: `The photograph did not save: ${error.message}`, ok: null };
    attachmentPath = path;
  }

  const { error } = await supabase.from("practice_form_entries").insert({
    form_key: key,
    client_id: clientId || null,
    staff_id: me.id,
    staff_name: me.name,
    answers,
    attachment_path: attachmentPath,
  });
  if (error) return { error: error.message, ok: null };

  if (clientId) revalidatePath(`/clients/${clientId}`);
  revalidatePath("/forms-and-checklists");
  return { error: null, ok: `${form.name} saved${clientId ? " to the client's record" : ""}.` };
}
