"use server";

import { revalidatePath } from "next/cache";
import { headers } from "next/headers";
import { createClient } from "@/lib/supabase/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { getCurrentStaff } from "@/lib/session";
import { signedPolicyPdf, type PolicyBlock } from "@/lib/policy-pdf";
import { ROLE_LABEL } from "@/lib/roles";

export type OnboardingState = { error: string | null; ok: string | null };

const PATH = "/paperwork/onboarding";

/** 25MB, the bucket's limit, and the kinds of file a phone or scanner makes. */
const MAX_BYTES = 25 * 1024 * 1024;
const ALLOWED = ["application/pdf", "image/jpeg", "image/png", "image/heic", "image/webp"];

/** Which file category the scan behind a credential goes under. */
const CARD_CATEGORY: Record<string, string> = {
  acre: "Certificate",
  cpr: "Certificate",
  background: "Background check",
  licence: "Licence",
  insurance: "Insurance",
};

async function clientIp(): Promise<string> {
  const h = await headers();
  return h.get("x-forwarded-for")?.split(",")[0]?.trim() ?? h.get("x-real-ip") ?? "";
}

// ── 1. personal details ─────────────────────────────────────
export async function savePersonalDetails(_prev: OnboardingState, formData: FormData): Promise<OnboardingState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const str = (k: string) => String(formData.get(k) ?? "").trim();
  const row = {
    staff_id: me.id,
    legal_name: str("legal_name"),
    address_line1: str("address_line1"),
    address_line2: str("address_line2"),
    city: str("city"),
    state: str("state").toUpperCase(),
    postal_code: str("postal_code"),
    phone: str("phone"),
    date_of_birth: str("date_of_birth") || null,
    emergency_name: str("emergency_name"),
    emergency_relationship: str("emergency_relationship"),
    emergency_phone: str("emergency_phone"),
    updated_by: me.id,
  };
  const missing = [
    ["legal_name", "your legal name"],
    ["address_line1", "your street address"],
    ["city", "the city"],
    ["state", "the state"],
    ["postal_code", "the ZIP code"],
    ["phone", "your phone number"],
    ["date_of_birth", "your date of birth"],
    ["emergency_name", "an emergency contact"],
    ["emergency_phone", "their phone number"],
  ].filter(([k]) => !row[k as keyof typeof row]);
  if (missing.length) return { error: `Still needed: ${missing.map(([, l]) => l).join(", ")}.`, ok: null };

  const supabase = await createClient();
  const { error } = await supabase.from("staff_personal").upsert(row);
  if (error) return { error: error.message, ok: null };

  revalidatePath(PATH);
  return { error: null, ok: "Personal details saved." };
}

// ── 2 and 3. uploading a scan to your own file ──────────────
async function uploadOwn(
  staffId: string,
  file: FormDataEntryValue | null,
  category: string,
  note: string,
): Promise<{ id: string } | { error: string }> {
  if (!(file instanceof File) || file.size === 0) return { error: "Choose a file first." };
  if (file.size > MAX_BYTES) return { error: "That file is over 25MB. Scan it at a lower resolution and try again." };
  if (!ALLOWED.includes(file.type)) return { error: "That kind of file is not accepted - a PDF or a photograph." };

  const supabase = await createClient();
  const safe = file.name.replace(/[^A-Za-z0-9._-]/g, "_").slice(-80);
  const path = `${staffId}/${Date.now()}-${safe}`;
  const { error: uploadError } = await supabase.storage
    .from("staff-files")
    .upload(path, file, { contentType: file.type, upsert: false });
  if (uploadError) return { error: `That did not upload. ${uploadError.message}` };

  const { data, error } = await supabase
    .from("staff_files")
    .insert({
      staff_id: staffId,
      storage_path: path,
      filename: file.name,
      mime_type: file.type,
      size_bytes: file.size,
      category,
      note,
      uploaded_by: staffId,
    })
    .select("id")
    .single();
  if (error || !data) {
    await supabase.storage.from("staff-files").remove([path]);
    return { error: error?.message ?? "The document could not be recorded." };
  }
  return { id: data.id };
}

export async function uploadIdentityDocument(_prev: OnboardingState, formData: FormData): Promise<OnboardingState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const supabase = await createClient();
  const { data: emp } = await supabase.from("staff_employment").select("employment_type").eq("staff_id", me.id).maybeSingle();
  const employee = emp?.employment_type === "Employee";
  const what = String(formData.get("what") ?? "").trim();
  if (!what) return { error: "Say which document it is - a passport, a driver's licence, a Social Security card.", ok: null };

  const result = await uploadOwn(
    me.id,
    formData.get("file"),
    employee ? "I-9" : "Identity document",
    employee ? `${what} - in-person inspection still required` : what,
  );
  if ("error" in result) return { error: result.error, ok: null };

  revalidatePath(PATH);
  return {
    error: null,
    ok: employee
      ? `${what} added. Bring the original in on your first day: it has to be inspected in person.`
      : `${what} added.`,
  };
}

export async function submitCredential(_prev: OnboardingState, formData: FormData): Promise<OnboardingState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const str = (k: string) => String(formData.get(k) ?? "").trim();
  const typeKey = str("type_key");
  const issued = str("issued_on");
  const expires = str("expires_on");
  if (!CARD_CATEGORY[typeKey]) return { error: "Unknown credential.", ok: null };
  if (issued && expires && expires < issued) {
    return { error: "That expires before it was issued - one of the two dates is wrong.", ok: null };
  }

  const supabase = await createClient();
  const { data: type } = await supabase.from("credential_types").select("label, expires").eq("key", typeKey).maybeSingle();
  if (!type) return { error: "Unknown credential.", ok: null };
  if (type.expires && !expires) return { error: `A ${type.label} expires - put the date from the card.`, ok: null };

  const uploaded = await uploadOwn(me.id, formData.get("file"), CARD_CATEGORY[typeKey], `${type.label}, put forward during onboarding`);
  if ("error" in uploaded) return { error: uploaded.error, ok: null };

  const { error } = await supabase.rpc("submit_own_credential", {
    p_type_key: typeKey,
    p_reference: str("reference"),
    p_issued_on: issued || null,
    p_expires_on: expires || null,
    p_file_id: uploaded.id,
    p_note: "",
  } as never);
  if (error) return { error: error.message, ok: null };

  revalidatePath(PATH);
  revalidatePath("/paperwork");
  return { error: null, ok: `${type.label} put forward. Admin checks it against the scan.` };
}

export async function confirmCertifications(_prev: OnboardingState): Promise<OnboardingState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };
  const supabase = await createClient();
  const { error } = await supabase.rpc("confirm_onboarding_certifications");
  if (error) return { error: error.message, ok: null };
  revalidatePath(PATH);
  return { error: null, ok: "Noted. Anything you earn later can be added on Paperwork." };
}

// ── 5. the data-handling policy ─────────────────────────────
export async function signPolicy(_prev: OnboardingState, formData: FormData): Promise<OnboardingState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const signer = String(formData.get("signer_name") ?? "").trim();
  const version = Number(formData.get("version"));
  if (formData.get("read") !== "on") return { error: "Confirm you have read the policy before signing.", ok: null };
  if (!signer) return { error: "Type your name to sign.", ok: null };

  const supabase = await createClient();
  const { data: policy } = await supabase
    .from("staff_policies")
    .select("key, version, title, body, text_sha256")
    .eq("key", "data-handling")
    .eq("is_current", true)
    .maybeSingle();
  if (!policy) return { error: "The policy is not on file. Tell the administrator.", ok: null };
  if (policy.version !== version) {
    return { error: "The policy has changed since this page opened. Read the new version below and sign that.", ok: null };
  }
  const { data: personal } = await supabase.from("staff_personal").select("legal_name").eq("staff_id", me.id).maybeSingle();
  if (personal?.legal_name && personal.legal_name.trim().toLowerCase() !== signer.toLowerCase()) {
    return { error: `Sign with your legal name as it is on file: ${personal.legal_name}.`, ok: null };
  }

  const ip = await clientIp();
  const signedAt = new Date();
  let pdf;
  try {
    pdf = await signedPolicyPdf({
      title: policy.title,
      version: policy.version,
      blocks: policy.body as unknown as PolicyBlock[],
      textSha256: policy.text_sha256,
      signerName: signer,
      signedAt,
      ip,
      staffName: me.name,
      role: ROLE_LABEL[me.role],
    });
  } catch (err) {
    return { error: `The signed copy could not be made: ${err instanceof Error ? err.message : "unknown error"}. Nothing was signed.`, ok: null };
  }

  // Stored as the tax forms are: the service role writes the generated file,
  // and the row says it is theirs and uploaded by them.
  const admin = createAdminClient();
  const storagePath = `staff/${me.id}/policy-${policy.key}-v${policy.version}-${signedAt.getTime()}.pdf`;
  const { error: uploadError } = await admin.storage
    .from("staff-files")
    .upload(storagePath, pdf.bytes, { contentType: "application/pdf", upsert: false });
  if (uploadError) return { error: `The signed copy could not be stored: ${uploadError.message}. Nothing was signed.`, ok: null };

  const { data: fileRow, error: fileError } = await admin
    .from("staff_files")
    .insert({
      staff_id: me.id,
      storage_path: storagePath,
      filename: `${policy.title} v${policy.version} - ${signer}.pdf`,
      mime_type: "application/pdf",
      size_bytes: pdf.bytes.length,
      category: "Signed policy",
      note: `Signed in the CRM by ${signer}`,
      uploaded_by: me.id,
    })
    .select("id")
    .single();
  if (fileError || !fileRow) {
    await admin.storage.from("staff-files").remove([storagePath]);
    return { error: `The signed copy could not be filed: ${fileError?.message ?? "unknown error"}. Nothing was signed.`, ok: null };
  }

  const { error } = await supabase.rpc("sign_staff_policy", {
    p_key: policy.key,
    p_version: policy.version,
    p_signer: signer,
    p_ip: ip,
    p_file_id: fileRow.id,
    p_pdf_sha256: pdf.sha256,
  });
  if (error) {
    await admin.from("staff_files").delete().eq("id", fileRow.id);
    await admin.storage.from("staff-files").remove([storagePath]);
    return { error: `Not signed: ${error.message}`, ok: null };
  }

  revalidatePath(PATH);
  return { error: null, ok: "Signed. The signed copy is on your file." };
}

// ── 6. payment ──────────────────────────────────────────────
export async function savePayment(_prev: OnboardingState, formData: FormData): Promise<OnboardingState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const method = String(formData.get("method") ?? "");
  const bank = formData.get("bank_details_with_payroll") === "on";
  if (method !== "Direct deposit through the payroll service" && method !== "Paper check") {
    return { error: "Choose how you would like to be paid.", ok: null };
  }

  const supabase = await createClient();
  const { data: org } = await supabase.from("org_settings").select("employer_legal_name, payroll_service").maybeSingle();
  const payer = org?.employer_legal_name?.trim() ?? "";
  const payroll = org?.payroll_service?.trim() ?? "";
  if (!payer) return { error: "The administrator has not set who pays staff yet. Tell them, and come back to this step.", ok: null };
  if (method.startsWith("Direct deposit") && !bank) {
    return { error: `Confirm you have given your bank details to ${payroll || "the payroll service"} yourself.`, ok: null };
  }

  const { error } = await supabase.from("staff_payment_setup").upsert({
    staff_id: me.id,
    method,
    payer_of_record: payer,
    payroll_service: payroll,
    bank_details_with_payroll: bank,
    confirmed_at: new Date().toISOString(),
  });
  if (error) return { error: error.message, ok: null };

  revalidatePath(PATH);
  return { error: null, ok: "Payment confirmed." };
}
