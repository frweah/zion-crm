"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";
import { CAN_EDIT_BILLING, SERVICE_TYPES } from "@/lib/constants";
import { extractPdfText } from "@/lib/pdf-text";
import { parseAuthorizationText, type ParsedAuthorization } from "@/lib/authorization-parse";

export type ImportState = {
  error: string | null;
  ok: string | null;
  parsed: ParsedAuthorization | null;
  filename: string | null;
};

export const emptyImport: ImportState = {
  error: null,
  ok: null,
  parsed: null,
  filename: null,
};

/** Ten megabytes. A two-page authorization is a few hundred kilobytes. */
const MAX_BYTES = 10 * 1024 * 1024;

/**
 * Read an authorization, and propose what it says.
 *
 * The file is read into memory, parsed, and dropped. It is not stored, not
 * sent anywhere, and nothing is written to the record — this returns a
 * proposal for somebody to look at. Everything that follows is their doing.
 */
export async function readAuthorization(
  _prev: ImportState,
  formData: FormData,
): Promise<ImportState> {
  const me = await getCurrentStaff();
  if (!me || !CAN_EDIT_BILLING.includes(me.role)) {
    return { ...emptyImport, error: "Only Admin and Billing add authorizations." };
  }

  const file = formData.get("pdf");
  if (!(file instanceof File) || file.size === 0) {
    return { ...emptyImport, error: "Choose the authorization PDF first." };
  }
  if (file.size > MAX_BYTES) {
    return { ...emptyImport, error: "That file is over 10MB — larger than any authorization." };
  }

  const bytes = new Uint8Array(await file.arrayBuffer());

  // A PDF starts with %PDF. Checking rather than trusting the extension keeps
  // a mislabelled Word document from arriving as a stack trace.
  if (!(bytes[0] === 0x25 && bytes[1] === 0x50 && bytes[2] === 0x44 && bytes[3] === 0x46)) {
    return { ...emptyImport, error: "That is not a PDF. Save the authorization as a PDF and try again." };
  }

  try {
    const text = await extractPdfText(bytes);
    const parsed = parseAuthorizationText(text.plain, {
      pages: text.pages,
      scanned: text.scanned,
    });
    return { ...emptyImport, parsed, filename: file.name };
  } catch (err) {
    const message = err instanceof Error ? err.message : "unknown error";
    return {
      ...emptyImport,
      error: `That file could not be read (${message}). If it opens in a PDF reader, type the authorization in by hand and tell somebody this happened.`,
    };
  }
}

/**
 * Create the authorization from what the person confirmed.
 *
 * Reads the form, not the parse: whatever they left on the screen is what
 * gets saved, because they are the one who looked at the PDF. The database
 * still applies its own rules — an hourly authorization needs hours, and only
 * Admin and Billing may write here at all.
 */
export async function createFromImport(
  _prev: ImportState,
  formData: FormData,
): Promise<ImportState> {
  const me = await getCurrentStaff();
  if (!me || !CAN_EDIT_BILLING.includes(me.role)) {
    return { ...emptyImport, error: "Only Admin and Billing add authorizations." };
  }

  const str = (k: string) => String(formData.get(k) ?? "").trim();
  const clientId = str("client_id");
  const serviceType = str("service_type");
  const rateType = str("rate_type") === "Flat Fee" ? "Flat Fee" : "Hourly";
  const rate = str("rate");
  const hours = str("total_hours");

  if (!clientId) {
    return { ...emptyImport, error: "Which client is this for? Pick them from the list." };
  }
  if (!SERVICE_TYPES.includes(serviceType as never)) {
    return { ...emptyImport, error: "Choose the service from the list — it decides which USOR forms are required." };
  }
  if (!rate || Number(rate) <= 0) {
    return { ...emptyImport, error: "What is the rate or the fee?" };
  }
  if (rateType === "Hourly" && (!hours || Number(hours) <= 0)) {
    return { ...emptyImport, error: "An hourly authorization needs the hours USOR authorized." };
  }

  const supabase = await createClient();
  const { data, error } = await supabase
    .from("authorizations")
    .insert({
      client_id: clientId,
      number: str("number"),
      service_type: serviceType,
      rate_type: rateType,
      rate: Number(rate),
      total_hours: rateType === "Hourly" ? Number(hours) : null,
      start_date: str("start_date") || null,
      end_date: str("end_date") || null,
      status: "Open",
      note: str("note"),
    })
    .select("id")
    .single();

  if (error) return { ...emptyImport, error: error.message };

  revalidatePath("/billing");
  revalidatePath("/revenue");
  revalidatePath(`/clients/${clientId}`);
  redirect(`/clients/${clientId}?tab=authorizations&added=${data.id}`);
}
