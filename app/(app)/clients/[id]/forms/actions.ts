"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";
import { autofillForm } from "@/lib/form-autofill";
import { formToText, type FormContext } from "@/lib/form-text";
import { templateById, validateForm } from "@/lib/form-templates";
import { parseCc, sendEmail } from "@/lib/email";
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

  const result = await sendEmail({ to, cc, subject, text });
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

  revalidatePath(`/clients/${clientId}/forms/${formId}`);
  revalidatePath(`/clients/${clientId}`);
  revalidatePath("/billing/forms");
  revalidatePath("/counselors");
  revalidatePath("/billing");

  return { error: null, ok: `Sent to ${sentTo} and logged in the contact log.` };
}
