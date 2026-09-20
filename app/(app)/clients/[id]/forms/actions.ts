"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";
import { autofillForm } from "@/lib/form-autofill";
import { formToText, type FormContext } from "@/lib/form-text";
import { templateById, validateForm } from "@/lib/form-templates";
import { parseCc, sendEmail, type Attachment } from "@/lib/email";
import { signedFormPdf } from "@/lib/form-pdf";
import { createAdminClient } from "@/lib/supabase/admin";
import { today } from "@/lib/constants";
import type { Json } from "@/lib/database.types";

export type FormState = { error: string | null; ok: string | null };

/** Start a form, pre-filled from the record. */
export async function createForm(_prev: FormState, formData: FormData): Promise<FormState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const clientId = String(formData.get("client_id") ?? "");
  const templateId = String(formData.get("template_id") ?? "");
  const authId = String(formData.get("auth_id") ?? "").trim() || null;
  const month = String(formData.get("month") ?? "").trim() || today().slice(0, 7);

  const tpl = templateById(templateId);
  if (!tpl) return { error: "Unknown form.", ok: null };

  const data = await autofillForm(templateId, clientId, authId, month);

  const supabase = await createClient();
  const { data: row, error } = await supabase
    .from("forms")
    .insert({
      template_id: templateId,
      client_id: clientId,
      auth_id: authId,
      month: tpl.monthly ? month : null,
      status: "Draft",
      data: data as Json,
      created_by: me.id,
      created_by_name: me.name,
    })
    .select("id")
    .single();

  if (error) {
    return {
      error: tpl.sensitive
        ? "This form holds restricted content, so it is limited to Admin, Intake & Client Reports, or this client's assigned staff member."
        : error.message,
      ok: null,
    };
  }

  revalidatePath(`/clients/${clientId}`);
  redirect(`/clients/${clientId}/forms/${row.id}`);
}

/** Save a draft. Completed forms are locked by the database, not by this code. */
export async function saveForm(_prev: FormState, formData: FormData): Promise<FormState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const formId = String(formData.get("form_id") ?? "");
  const clientId = String(formData.get("client_id") ?? "");
  const payload = String(formData.get("payload") ?? "{}");

  let data: Record<string, unknown>;
  try {
    data = JSON.parse(payload) as Record<string, unknown>;
  } catch {
    return { error: "The form could not be read. Nothing was saved.", ok: null };
  }

  const supabase = await createClient();
  const { error } = await supabase.from("forms").update({ data: data as Json }).eq("id", formId);

  if (error) return { error: error.message, ok: null };

  revalidatePath(`/clients/${clientId}/forms/${formId}`);
  return { error: null, ok: "Saved." };
}

/**
 * Sign and lock a form.
 *
 * The database records who signed and when, and refuses every later edit. The
 * USOR 60 CIE rule is checked first: a placement failing any CIE test cannot
 * be certified as competitive integrated employment.
 */
export async function completeForm(_prev: FormState, formData: FormData): Promise<FormState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const formId = String(formData.get("form_id") ?? "");
  const clientId = String(formData.get("client_id") ?? "");
  const payload = String(formData.get("payload") ?? "{}");

  let data: Record<string, unknown>;
  try {
    data = JSON.parse(payload) as Record<string, unknown>;
  } catch {
    return { error: "The form could not be read. Nothing was signed.", ok: null };
  }

  const supabase = await createClient();
  const { data: form } = await supabase
    .from("forms")
    .select("template_id, status")
    .eq("id", formId)
    .maybeSingle();

  if (!form) return { error: "Form not found.", ok: null };
  if (form.status !== "Draft") return { error: "This form is already signed.", ok: null };

  const problem = validateForm(form.template_id, data);
  if (problem) return { error: problem, ok: null };

  // Content and signature in one write, so a form can never be signed with
  // different content than the person signing it saw.
  const { error } = await supabase
    .from("forms")
    .update({
      data: data as Json,
      status: "Completed",
      completed_by: me.id,
      completed_by_name: me.name,
    })
    .eq("id", formId);

  if (error) return { error: error.message, ok: null };

  revalidatePath(`/clients/${clientId}/forms/${formId}`);
  revalidatePath(`/clients/${clientId}`);
  revalidatePath("/billing/forms");
  return { error: null, ok: "Signed and locked." };
}

/**
 * Email a completed form and log the send. By default it goes to the client's
 * billing office, copying the counselor (owner, 18 Sept 2026); the page fills
 * those in and the person sending can change either.
 *
 * The form is marked Sent only if the mail service actually accepted it —
 * "Sent" has to mean the counselor has it, or the billing gate that depends on
 * it is worthless.
 */
export async function sendForm(_prev: FormState, formData: FormData): Promise<FormState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const formId = String(formData.get("form_id") ?? "");
  const clientId = String(formData.get("client_id") ?? "");
  const to = String(formData.get("to") ?? "").trim();
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(to)) {
    return { error: "Enter the address to send the form to.", ok: null };
  }
  const { cc, bad } = parseCc(String(formData.get("cc") ?? ""), to);
  if (bad.length) {
    return { error: `These do not look like email addresses: ${bad.join(", ")}.`, ok: null };
  }

  const supabase = await createClient();

  const { data: form } = await supabase
    .from("forms")
    .select("id, template_id, data, status, auth_id, completed_by_name, completed_at")
    .eq("id", formId)
    .maybeSingle();

  if (!form) return { error: "Form not found.", ok: null };
  if (form.status === "Draft") {
    return { error: "Sign the form before sending it.", ok: null };
  }

  const { data: client } = await supabase
    .from("clients")
    .select("name, client_no, agency_id, counselor_id")
    .eq("id", clientId)
    .maybeSingle();

  const [{ data: counselor }, { data: auth }] = await Promise.all([
    client?.counselor_id
      ? supabase.from("counselors").select("id, name").eq("id", client.counselor_id).maybeSingle()
      : Promise.resolve({ data: null }),
    form.auth_id
      ? supabase
          .from("authorizations")
          .select("number, service_type")
          .eq("id", form.auth_id)
          .maybeSingle()
      : Promise.resolve({ data: null }),
  ]);

  const tpl = templateById(form.template_id);
  const ctx: FormContext = {
    clientName: client?.name ?? "",
    clientNo: client?.client_no ?? null,
    agencyId: client?.agency_id ?? "",
    counselorName: counselor?.name ?? "",
    authNumber: auth?.number ?? "",
    authServiceType: auth?.service_type ?? "",
    completedBy: form.completed_by_name,
    completedAt: form.completed_at,
  };

  const text = formToText(form.template_id, form.data as Record<string, unknown>, ctx);
  const subject = `${tpl?.usor ?? "USOR form"} — ${client?.name ?? "client"}${
    auth?.number ? ` — ${auth.number}` : ""
  }`;

  // ── what goes with it ──────────────────────────────────────
  // The form as a PDF, signed, and the authorization's own PDF where the
  // record holds one: a billing office asked for a claim should not have to
  // go and find the authorization it is against.
  const admin = createAdminClient();
  const attachments: Attachment[] = [];
  let pdfSha = "";

  const signature = await signatureFor(me.id, admin);
  const pdf = await signedFormPdf({
    templateId: form.template_id,
    data: form.data as Record<string, unknown>,
    ctx,
    signature: {
      name: form.completed_by_name || me.name,
      at: form.completed_at ? new Date(form.completed_at) : null,
      image: signature,
    },
  });
  pdfSha = pdf.sha256;
  const pdfName = `${tpl?.usor ?? "USOR form"} ${client?.name ?? "client"}${auth?.number ? ` ${auth.number}` : ""}.pdf`
    .replace(/[\/:*?"<>|]/g, "-");
  attachments.push({ filename: pdfName, bytes: pdf.bytes });

  if (form.auth_id) {
    const { data: authFile } = await supabase
      .from("attachments")
      .select("storage_path, filename")
      .eq("auth_id", form.auth_id)
      .eq("restricted", false)
      .order("created_at", { ascending: false })
      .limit(1)
      .maybeSingle();
    if (authFile) {
      const { data: file } = await admin.storage.from("client-files").download(authFile.storage_path);
      if (file) {
        attachments.push({ filename: authFile.filename, bytes: new Uint8Array(await file.arrayBuffer()) });
      }
    }
  }

  const result = await sendEmail({ to, cc, subject, text, attachments });
  if (!result.ok) {
    return { error: `Not sent. ${result.error}`, ok: null };
  }

  const sentTo = cc.length ? `${to} (copy to ${cc.join(", ")})` : to;
  await supabase.from("forms").update({ status: "Sent", sent_to: sentTo }).eq("id", formId);

  const { data: billingRow } = await supabase
    .from("client_billing_office")
    .select("billing_office_id")
    .eq("client_id", clientId)
    .maybeSingle();

  // Every report sent to a counselor belongs in the contact log — the SOP says
  // so, and this is one send that should never depend on someone remembering.
  await supabase.from("contact_log").insert({
    counselor_id: counselor?.id ?? null,
    client_id: clientId,
    date: today(),
    method: "Report sent",
    topic: tpl?.name ?? "USOR form",
    outcome: `Emailed to ${sentTo}`,
    billing_office_id: billingRow?.billing_office_id ?? null,
    staff_id: me.id,
  });

  // The copy that went out, kept on the record. Written with the service role
  // because the person sending may not be allowed to attach a restricted
  // document by hand - this one is not restricted, and it is theirs anyway.
  const storagePath = `clients/${clientId}/forms/${formId}-${pdfSha.slice(0, 12)}.pdf`;
  const stored = await admin.storage
    .from("client-files")
    .upload(storagePath, attachments[0].bytes, { contentType: "application/pdf", upsert: true });
  if (!stored.error) {
    await admin.from("attachments").upsert(
      {
        client_id: clientId,
        storage_path: storagePath,
        filename: attachments[0].filename,
        mime_type: "application/pdf",
        size_bytes: attachments[0].bytes.byteLength,
        category: "Signed USOR form",
        restricted: false,
        note: `Sent to ${sentTo}`,
        form_id: formId,
        auth_id: form.auth_id,
        uploaded_by: me.id,
        uploaded_by_name: me.name,
      },
      { onConflict: "storage_path" },
    );
  }

  // If that was the last form the authorization was waiting on, the invoice
  // it has earned is raised as a Draft. The database decides whether there is
  // one to raise; this only asks.
  let billed = "";
  if (form.auth_id) {
    const { data: invoiceId } = await supabase.rpc("draft_invoice_for_authorization", { p_auth: form.auth_id });
    if (invoiceId) billed = " A draft invoice is waiting in Billing.";
  }

  revalidatePath(`/clients/${clientId}/forms/${formId}`);
  revalidatePath(`/clients/${clientId}`);
  revalidatePath("/billing/forms");
  revalidatePath("/counselors");
  revalidatePath("/billing");

  return {
    error: null,
    ok: `Sent to ${sentTo} with the signed PDF attached, and logged in the contact log.${billed}`,
  };
}

/**
 * The sender's signature image, if they have uploaded one.
 *
 * Read with the service role: the image lives in the staff tier, and reading
 * one's own signature to stamp it on one's own signature block is the only
 * thing this is for.
 */
async function signatureFor(
  staffId: string,
  admin: ReturnType<typeof createAdminClient>,
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
