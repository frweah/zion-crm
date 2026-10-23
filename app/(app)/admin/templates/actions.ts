"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

/**
 * Editing the three letters the practice keeps writing (0238).
 *
 * The words are Admin's; the merge fields are not. A field the templates do
 * not know about would be sent to a counselor as "{client_number}" in curly
 * brackets, so an unknown one is refused by name before anything is saved.
 */
export type TemplateState = { error: string | null; ok: string | null };

/** What `mail_template_for` knows how to fill in. */
const FIELDS = [
  "{client}",
  "{client_no}",
  "{counselor}",
  "{authorization}",
  "{service}",
  "{issued}",
  "{ends}",
  "{me}",
  "{signature}",
];

export async function saveMailTemplate(
  _prev: TemplateState,
  formData: FormData,
): Promise<TemplateState> {
  const key = String(formData.get("key") ?? "");
  const label = String(formData.get("label") ?? "").trim();
  const subject = String(formData.get("subject") ?? "").trim();
  const body = String(formData.get("body") ?? "");
  const active = formData.get("active") === "on";

  if (!key) return { error: "Which template?", ok: null };
  if (!label) return { error: "Give it a name.", ok: null };
  if (!subject) return { error: "Give it a subject.", ok: null };
  if (!body.trim()) return { error: "The template has no words in it.", ok: null };

  const unknown = [...`${subject}\n${body}`.matchAll(/\{[a-z_]+\}/g)]
    .map((m) => m[0])
    .filter((f) => !FIELDS.includes(f));
  if (unknown.length > 0) {
    return {
      error: `${unknown[0]} is not a field the CRM can fill. Use ${FIELDS.join(", ")}.`,
      ok: null,
    };
  }

  const supabase = await createClient();
  const { error } = await supabase
    .from("mail_templates")
    .update({ label, subject, body, active, updated_at: new Date().toISOString() })
    .eq("key", key);
  if (error) return { error: error.message, ok: null };

  revalidatePath("/admin/templates");
  return { error: null, ok: `${label} saved.` };
}

/** The lines under every message the CRM sends. */
export async function saveMailSignature(
  _prev: TemplateState,
  formData: FormData,
): Promise<TemplateState> {
  const signature = String(formData.get("signature") ?? "").trim();
  const supabase = await createClient();
  const { error } = await supabase
    .from("org_settings")
    .update({ mail_signature: signature })
    .eq("id", true);
  if (error) return { error: error.message, ok: null };
  revalidatePath("/admin/templates");
  return { error: null, ok: "Signature saved." };
}

/** Who is told about every reply that files itself, besides the assigned staff. */
export async function saveMailNoticeRecipient(
  _prev: TemplateState,
  formData: FormData,
): Promise<TemplateState> {
  const staffId = String(formData.get("staff_id") ?? "");
  const supabase = await createClient();
  const { error } = await supabase
    .from("org_settings")
    .update({ mail_notice_staff_id: staffId || null })
    .eq("id", true);
  if (error) return { error: error.message, ok: null };
  revalidatePath("/admin/templates");
  return { error: null, ok: staffId ? "Saved." : "Nobody standing. Only assigned staff will be told." };
}
