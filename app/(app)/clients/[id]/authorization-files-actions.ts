"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";
import { CAN_EDIT_BILLING } from "@/lib/constants";
import { describeConfirmation } from "@/lib/authorization-confirmation";

export type LinkState = { error: string | null; ok: string | null };

/**
 * Attach a file already on the client's record to one of their authorizations.
 *
 * For the PDFs filed before there was anywhere to put them — including the
 * scans, which nothing can read a number off, so a person picks. The rules
 * live in public.confirm_authorization_document: the file and the
 * authorization must be the same client's, a file goes on one authorization
 * only, and blank dates are filled while dates on file are kept.
 */
export async function linkAuthorizationFile(
  _prev: LinkState,
  formData: FormData,
): Promise<LinkState> {
  const me = await getCurrentStaff();
  if (!me || !CAN_EDIT_BILLING.includes(me.role)) {
    return { error: "Only Admin and Billing attach an authorization's PDF.", ok: null };
  }

  const str = (k: string) => String(formData.get(k) ?? "").trim();
  const clientId = str("client_id");
  const authId = str("auth_id");
  const attachmentId = str("attachment_id");

  if (!authId) return { error: "Which authorization?", ok: null };
  if (!attachmentId) return { error: "Choose the file.", ok: null };

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("confirm_authorization_document", {
    p_attachment: attachmentId,
    p_doc: null,
    p_auth: authId,
    p_number: null,
    p_service_type: null,
    p_rate_type: null,
    p_rate: null,
    p_total_hours: null,
    p_start: str("start_date") || null,
    p_end: str("end_date") || null,
  });

  if (error) return { error: error.message, ok: null };

  revalidatePath(`/clients/${clientId}`);
  revalidatePath("/billing");
  return { error: null, ok: describeConfirmation(Array.isArray(data) ? data[0] : null) };
}
