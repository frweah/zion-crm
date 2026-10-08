"use server";

import { can } from "@/lib/roles";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { getCurrentStaff } from "@/lib/session";
import { SERVICE_TYPES } from "@/lib/constants";
import { extractPdfText } from "@/lib/pdf-text";
import { parseAuthorizationText, type ParsedAuthorization } from "@/lib/authorization-parse";

export type ImportState = {
  error: string | null;
  ok: string | null;
  parsed: ParsedAuthorization | null;
  filename: string | null;
  /**
   * Where the PDF is waiting while somebody checks what was read off it.
   *
   * §12.1 says the authorization is saved "with the PDF referenced", and §11
   * says the PDF exists once. So the file is kept at the moment it is read,
   * under a staging path, and moved into the client's own folder when the
   * client is known - which is at the confirm step, not this one. One object,
   * moved; never two.
   */
  stagedPath: string | null;
  bytes: number | null;
};

export const emptyImport: ImportState = {
  error: null,
  ok: null,
  parsed: null,
  filename: null,
  stagedPath: null,
  bytes: null,
};

/** Ten megabytes. A two-page authorization is a few hundred kilobytes. */
const MAX_BYTES = 10 * 1024 * 1024;

/**
 * Read an authorization, and propose what it says.
 *
 * The file is parsed and kept - nothing is written to the record, and nothing
 * is sent anywhere. This returns a proposal for somebody to look at;
 * everything that follows is their doing.
 *
 * The PDF itself is put somewhere safe while they look, because an
 * authorization entered from its own PDF should have that PDF on it (§12.1) and
 * asking for the file twice is how it ends up attached to nothing. If they walk
 * away, the file sits in the staging folder and no record points at it.
 */
export async function readAuthorization(
  _prev: ImportState,
  formData: FormData,
): Promise<ImportState> {
  const me = await getCurrentStaff();
  if (!me || !can(me, "billing", "edit")) {
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

    // Kept for the confirm step, which is where the client is known. Written
    // with the service role: this is nobody's client folder yet.
    const staged = `imports/${crypto.randomUUID()}.pdf`;
    const { error: upload } = await createAdminClient()
      .storage.from("client-files")
      .upload(staged, bytes, { contentType: "application/pdf" });

    return {
      ...emptyImport,
      parsed,
      filename: file.name,
      // A file that could not be kept does not stop the reading: the figures
      // are the point, and the PDF can be attached from the client's files
      // afterwards. It says so rather than failing silently.
      stagedPath: upload ? null : staged,
      bytes: file.size,
      ok: upload ? "Read, but the PDF itself could not be kept — attach it from the client's files once this is saved." : null,
    };
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
  if (!me || !can(me, "billing", "edit")) {
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

  // Through the one door (§10). This used to insert into the table directly,
  // which stopped working the moment 0168 revoked that - so the PDF route, the
  // one this brief makes primary, was refused with a permission error. The
  // verify script asked which *functions* write a bill and never thought to ask
  // about the app.
  const supabase = await createClient();
  const { data: authId, error } = await supabase.rpc("add_authorization", {
    p_client: clientId,
    p_number: str("number"),
    p_service_type: serviceType,
    p_rate_type: rateType,
    p_rate: Number(rate),
    p_total_hours: rateType === "Hourly" ? Number(hours) : null,
    p_start: str("start_date") || null,
    p_end: str("end_date") || null,
    p_note: str("note"),
  });

  if (error || !authId) return { ...emptyImport, error: error?.message ?? "That could not be saved." };

  /**
   * The PDF goes onto the authorization it was read from (§§11, 12.1).
   *
   * Moved out of staging into the client's own folder rather than copied: one
   * object, referenced by one attachment row. This is also what makes the
   * checklist's "Signed authorization attached" line true for anything entered
   * from its own PDF, which it could not be before.
   */
  const staged = str("staged_path");
  let attached = "";
  if (staged) {
    const admin = createAdminClient();
    const resting = `clients/${clientId}/${staged.replace(/^imports\//, "")}`;
    const { error: moved } = await admin.storage.from("client-files").move(staged, resting);
    if (moved) {
      attached = " The PDF could not be filed — attach it from the client's files.";
      console.error("[billing] the authorization was created but its PDF stayed in staging", moved.message);
    } else {
      const { error: row } = await admin.from("attachments").insert({
        client_id: clientId,
        auth_id: authId as string,
        storage_path: resting,
        filename: str("filename") || "authorization.pdf",
        mime_type: "application/pdf",
        size_bytes: Number(str("bytes")) || 0,
        category: "Authorization",
        uploaded_by: me.id,
        uploaded_by_name: me.name,
      });
      if (row) {
        attached = " The PDF was filed but not attached — attach it from the client's files.";
        console.error("[billing] the PDF was filed but not attached", row.message);
      }
    }
  }

  revalidatePath("/billing");
  revalidatePath("/insights/money");
  revalidatePath(`/clients/${clientId}`);
  redirect(`/billing/authorizations/${authId}${attached ? "?note=filing" : ""}`);
}
