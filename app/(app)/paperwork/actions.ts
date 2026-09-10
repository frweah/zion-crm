"use server";

import { revalidatePath } from "next/cache";
import { headers } from "next/headers";
import { createClient } from "@/lib/supabase/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { getCurrentStaff } from "@/lib/session";
import {
  fillW8BEN,
  fillW9,
  fillW4,
  toIrsDate,
  W8BEN_LIMITS,
  W9_CLASSIFICATIONS,
  W4_FILING_STATUSES,
  W4_CREDITS,
  type W8BenData,
  type W9Classification,
  type W9Data,
  type W4FilingStatus,
} from "@/lib/irs-forms";
import { today } from "@/lib/constants";
import type { Json } from "@/lib/database.types";

export type PaperworkState = { error: string | null; ok: string | null };

const digitsOnly = (v: string) => v.replace(/\D/g, "");

/**
 * Complete and sign a W-8BEN.
 *
 * The form is filled, signed and stored in one action so a signature can never
 * exist without the document it attests to. The sensitive numbers are handed to
 * the database separately from the rest, so they are encrypted rather than
 * sitting in a readable column.
 */
export async function signW8BEN(
  _prev: PaperworkState,
  formData: FormData,
): Promise<PaperworkState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const str = (k: string) => String(formData.get(k) ?? "").trim();

  const name = str("name");
  const citizenshipCountry = str("citizenship_country");
  const residenceStreet = str("residence_street");
  const residenceCity = str("residence_city");
  const residenceCountry = str("residence_country");
  const signerName = str("signer_name");

  if (!name) return { error: "Line 1 needs your full legal name.", ok: null };
  if (!citizenshipCountry) return { error: "Line 2 needs your country of citizenship.", ok: null };
  if (!residenceStreet || !residenceCity || !residenceCountry) {
    return { error: "Line 3 needs your full permanent residence address.", ok: null };
  }
  if (!signerName) return { error: "Type your name to sign.", ok: null };
  if (signerName.toLowerCase() !== name.toLowerCase()) {
    return {
      error: "The name you sign with must match the name on line 1.",
      ok: null,
    };
  }
  if (formData.get("certify") !== "on") {
    return { error: "You have to confirm the certification before signing.", ok: null };
  }

  const usTin = digitsOnly(str("us_tin"));
  const foreignTin = str("foreign_tin");
  const ftinNotRequired = formData.get("ftin_not_required") === "on";
  const dateOfBirth = str("date_of_birth");

  if (usTin && usTin.length !== 9) {
    return { error: "A US taxpayer identification number is nine digits, or leave it blank.", ok: null };
  }
  if (!foreignTin && !ftinNotRequired) {
    return {
      error:
        "Give your foreign tax identifying number, or tick the box to say one is not legally required.",
      ok: null,
    };
  }
  if (foreignTin.length > 20) {
    return { error: "That foreign tax identifying number is too long for the form.", ok: null };
  }
  if (dateOfBirth && !/^\d{4}-\d{2}-\d{2}$/.test(dateOfBirth)) {
    return { error: "Check the date of birth.", ok: null };
  }

  const supabase = await createClient();
  const signedOn = today();

  // A draft row first, so the form exists before it is signed and the
  // signature has something to attach to.
  const readable = {
    name,
    citizenshipCountry,
    residenceStreet,
    residenceCity,
    residenceCountry,
    mailingStreet: str("mailing_street"),
    mailingCity: str("mailing_city"),
    mailingCountry: str("mailing_country"),
    reference: str("reference"),
    ftinNotRequired,
    signedOn,
  };

  const { data: draft, error: draftError } = await supabase
    .from("tax_form_submissions")
    .insert({
      staff_id: me.id,
      form_type: "W-8BEN",
      status: "Draft",
      data: readable as unknown as Json,
    })
    .select("id")
    .single();

  if (draftError) return { error: draftError.message, ok: null };

  const payload: W8BenData = {
    ...readable,
    usTin: usTin || undefined,
    foreignTin: foreignTin || undefined,
    dateOfBirth: dateOfBirth ? toIrsDate(dateOfBirth) : undefined,
    treatyCountry: str("treaty_country") || undefined,
    signerName,
    signedOn: toIrsDate(signedOn),
    signingForAnother: formData.get("signing_for_another") === "on",
  };

  if (payload.usTin && payload.usTin.length > W8BEN_LIMITS.usTin) {
    return { error: "That US taxpayer identification number will not fit the form.", ok: null };
  }

  let pdf;
  try {
    pdf = await fillW8BEN(payload);
  } catch (err) {
    await supabase.from("tax_form_submissions").delete().eq("id", draft.id);
    return {
      error: `The form could not be generated: ${err instanceof Error ? err.message : "unknown error"}. Nothing was signed.`,
      ok: null,
    };
  }

  // Storing it needs the service role: the paperwork bucket is Admin-only, and
  // this is the system filing on the person's behalf rather than the person
  // writing to it. Ownership was established above.
  const admin = createAdminClient();
  const storagePath = `staff/${me.id}/w8ben-${draft.id}.pdf`;

  const { error: uploadError } = await admin.storage
    .from("staff-files")
    .upload(storagePath, pdf.bytes, { contentType: "application/pdf", upsert: true });

  if (uploadError) {
    await supabase.from("tax_form_submissions").delete().eq("id", draft.id);
    return { error: `The form could not be stored: ${uploadError.message}. Nothing was signed.`, ok: null };
  }

  const { data: fileRow } = await admin
    .from("staff_files")
    .insert({
      staff_id: me.id,
      storage_path: storagePath,
      filename: `W-8BEN ${name} ${signedOn}.pdf`,
      mime_type: "application/pdf",
      size_bytes: pdf.bytes.length,
      category: "W-8BEN",
      note: `Completed in the CRM and signed by ${signerName}`,
      uploaded_by: me.id,
    })
    .select("id")
    .single();

  // The document details go on before signing, because a signed form is frozen.
  await supabase
    .from("tax_form_submissions")
    .update({
      pdf_path: storagePath,
      pdf_sha256: pdf.sha256,
      staff_file_id: fileRow?.id ?? null,
    })
    .eq("id", draft.id);

  const headerList = await headers();
  const ip =
    headerList.get("x-forwarded-for")?.split(",")[0]?.trim() ??
    headerList.get("x-real-ip") ??
    "";

  const sensitive: Record<string, string> = {};
  if (usTin) sensitive.usTin = usTin;
  if (foreignTin) sensitive.foreignTin = foreignTin;
  if (dateOfBirth) sensitive.dateOfBirth = dateOfBirth;

  const last4 = (foreignTin || usTin).slice(-4);

  const { error: signError } = await supabase.rpc("sign_tax_form", {
    p_form_id: draft.id,
    p_sensitive: sensitive as unknown as Json,
    p_tin_last4: last4,
    p_signer: signerName,
    p_ip: ip,
  });

  if (signError) {
    return { error: `Not signed: ${signError.message}`, ok: null };
  }

  revalidatePath("/paperwork");
  revalidatePath("/admin/staff");
  return {
    error: null,
    ok: "Signed. Your W-8BEN is on file, and the record shows it was received today.",
  };
}

/**
 * Complete and sign a W-9.
 *
 * Same shape as the W-8BEN: filled, signed and stored in one action, with the
 * taxpayer number handed to the database separately so it is encrypted rather
 * than sitting in a readable column. Signing also puts the number on the
 * contractor's profile, so the 1099 run has it without anyone keying it twice.
 */
export async function signW9(
  _prev: PaperworkState,
  formData: FormData,
): Promise<PaperworkState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const str = (k: string) => String(formData.get(k) ?? "").trim();

  const name = str("name");
  const classification = str("classification") as W9Classification;
  const street = str("street");
  const cityStateZip = str("city_state_zip");
  const signerName = str("signer_name");

  if (!name) return { error: "Line 1 needs your full legal name.", ok: null };
  if (!W9_CLASSIFICATIONS.includes(classification)) {
    return { error: "Choose your federal tax classification on line 3a.", ok: null };
  }
  if (!street || !cityStateZip) {
    return { error: "Lines 5 and 6 need your full address.", ok: null };
  }
  if (!signerName) return { error: "Type your name to sign.", ok: null };
  if (signerName.toLowerCase() !== name.toLowerCase()) {
    return { error: "The name you sign with must match the name on line 1.", ok: null };
  }
  if (formData.get("certify") !== "on") {
    return { error: "You have to confirm the certification before signing.", ok: null };
  }

  const llcTaxClassification = str("llc_tax_classification").toUpperCase();
  const otherClassification = str("other_classification");

  if (classification === "LLC" && !["C", "S", "P"].includes(llcTaxClassification)) {
    return { error: "An LLC needs its tax classification: C, S or P.", ok: null };
  }
  if (classification === "Other" && !otherClassification) {
    return { error: "Say what the classification is, beside \u201cOther\u201d.", ok: null };
  }

  const tinType = str("tin_type");
  const tin = digitsOnly(str("tin"));

  if (tinType !== "SSN" && tinType !== "EIN") {
    return { error: "Say whether the number is an SSN or an EIN.", ok: null };
  }
  if (tin.length !== 9) {
    return { error: "A taxpayer identification number is nine digits.", ok: null };
  }

  const supabase = await createClient();
  const signedOn = today();

  // Everything except the number itself. This is the readable half, and it is
  // readable by design: the profile screens show what was declared.
  const readable = {
    name,
    businessName: str("business_name"),
    classification,
    llcTaxClassification: classification === "LLC" ? llcTaxClassification : "",
    otherClassification: classification === "Other" ? otherClassification : "",
    foreignPartners: formData.get("foreign_partners") === "on",
    street,
    cityStateZip,
    accountNumbers: str("account_numbers"),
    tinType,
    signedOn,
  };

  const { data: draft, error: draftError } = await supabase
    .from("tax_form_submissions")
    .insert({
      staff_id: me.id,
      form_type: "W-9",
      status: "Draft",
      data: readable as unknown as Json,
    })
    .select("id")
    .single();

  if (draftError) return { error: draftError.message, ok: null };

  const payload: W9Data = {
    name,
    businessName: readable.businessName || undefined,
    classification,
    llcTaxClassification: classification === "LLC" ? llcTaxClassification : undefined,
    otherClassification: classification === "Other" ? otherClassification : undefined,
    foreignPartners: readable.foreignPartners,
    street,
    cityStateZip,
    accountNumbers: readable.accountNumbers || undefined,
    ssn: tinType === "SSN" ? tin : undefined,
    ein: tinType === "EIN" ? tin : undefined,
    signerName,
    signedOn: toIrsDate(signedOn),
    // The requester is Zion, because Zion is the payer asking for the form.
    requester: "Zion Vocational Rehabilitation Center",
  };

  let pdf;
  try {
    pdf = await fillW9(payload);
  } catch (err) {
    await supabase.from("tax_form_submissions").delete().eq("id", draft.id);
    return {
      error: `The form could not be generated: ${err instanceof Error ? err.message : "unknown error"}. Nothing was signed.`,
      ok: null,
    };
  }

  const admin = createAdminClient();
  const storagePath = `staff/${me.id}/w9-${draft.id}.pdf`;

  const { error: uploadError } = await admin.storage
    .from("staff-files")
    .upload(storagePath, pdf.bytes, { contentType: "application/pdf", upsert: true });

  if (uploadError) {
    await supabase.from("tax_form_submissions").delete().eq("id", draft.id);
    return { error: `The form could not be stored: ${uploadError.message}. Nothing was signed.`, ok: null };
  }

  const { data: fileRow } = await admin
    .from("staff_files")
    .insert({
      staff_id: me.id,
      storage_path: storagePath,
      filename: `W-9 ${name} ${signedOn}.pdf`,
      mime_type: "application/pdf",
      size_bytes: pdf.bytes.length,
      category: "W-9",
      note: `Completed in the CRM and signed by ${signerName}`,
      uploaded_by: me.id,
    })
    .select("id")
    .single();

  // The document details go on before signing, because a signed form is frozen.
  await supabase
    .from("tax_form_submissions")
    .update({
      pdf_path: storagePath,
      pdf_sha256: pdf.sha256,
      staff_file_id: fileRow?.id ?? null,
    })
    .eq("id", draft.id);

  const headerList = await headers();
  const ip =
    headerList.get("x-forwarded-for")?.split(",")[0]?.trim() ??
    headerList.get("x-real-ip") ??
    "";

  // The key name decides what the profile trigger records as the TIN type.
  const sensitive: Record<string, string> = tinType === "SSN" ? { ssn: tin } : { ein: tin };

  const { error: signError } = await supabase.rpc("sign_tax_form", {
    p_form_id: draft.id,
    p_sensitive: sensitive as unknown as Json,
    p_tin_last4: tin.slice(-4),
    p_signer: signerName,
    p_ip: ip,
  });

  if (signError) {
    return { error: `Not signed: ${signError.message}`, ok: null };
  }

  revalidatePath("/paperwork");
  revalidatePath("/admin/staff");
  return {
    error: null,
    ok: "Signed. Your W-9 is on file, and the record shows it was received today.",
  };
}

/**
 * Complete and sign a W-4.
 *
 * Unlike the other two, this form is only half the employee's. The bottom
 * block belongs to the employer, and it is filled here from the practice's own
 * settings and the start date already on the employment record, so what gets
 * stored is a complete form rather than one waiting for somebody to finish it
 * by hand.
 */
export async function signW4(
  _prev: PaperworkState,
  formData: FormData,
): Promise<PaperworkState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const str = (k: string) => String(formData.get(k) ?? "").trim();
  const count = (k: string) => Math.max(0, Math.floor(Number(formData.get(k) ?? 0) || 0));
  const dollars = (k: string) => Math.max(0, Math.round(Number(formData.get(k) ?? 0) || 0));

  const firstName = str("first_name");
  const lastName = str("last_name");
  const address = str("address");
  const cityStateZip = str("city_state_zip");
  const filingStatus = str("filing_status") as W4FilingStatus;
  const signerName = str("signer_name");
  const ssn = digitsOnly(str("ssn"));

  if (!firstName || !lastName) return { error: "Step 1 needs your first and last name.", ok: null };
  if (!address || !cityStateZip) return { error: "Step 1 needs your full address.", ok: null };
  if (ssn.length !== 9) return { error: "A social security number is nine digits.", ok: null };
  if (!W4_FILING_STATUSES.includes(filingStatus)) {
    return { error: "Choose your filing status in Step 1(c).", ok: null };
  }
  if (!signerName) return { error: "Type your name to sign.", ok: null };

  const fullName = `${firstName} ${lastName}`;
  if (signerName.toLowerCase() !== fullName.toLowerCase()) {
    return { error: "The name you sign with must match the name in Step 1.", ok: null };
  }
  if (formData.get("certify") !== "on") {
    return { error: "You have to confirm the declaration before signing.", ok: null };
  }

  // Claiming exemption is a claim about the whole year, and the form says to
  // leave Steps 2 to 4 blank when you make it. Zeroing them here rather than
  // only in the filler means the record and the PDF say the same thing.
  const exempt = formData.get("exempt") === "on";
  const qualifyingChildren = exempt ? 0 : count("qualifying_children");
  const otherDependents = exempt ? 0 : count("other_dependents");

  const qualifyingChildrenAmount = qualifyingChildren * W4_CREDITS.perQualifyingChild;
  const otherDependentsAmount = otherDependents * W4_CREDITS.perOtherDependent;
  const otherCreditsAmount = exempt ? 0 : dollars("other_credits");
  const otherIncome = exempt ? 0 : dollars("other_income");
  const deductions = exempt ? 0 : dollars("deductions");
  const extraWithholding = exempt ? 0 : dollars("extra_withholding");
  const multipleJobs = !exempt && formData.get("multiple_jobs") === "on";

  const supabase = await createClient();
  const signedOn = today();

  // The employer half. Read with the service role because the EIN is Admin
  // only and the person filling this in is not Admin — they are not shown it
  // either, it goes straight onto the form.
  const admin = createAdminClient();
  const [{ data: settings }, { data: employment }] = await Promise.all([
    admin
      .from("org_settings")
      .select("employer_legal_name, employer_address, employer_ein")
      .eq("id", true)
      .maybeSingle(),
    admin.from("staff_employment").select("started_on").eq("staff_id", me.id).maybeSingle(),
  ]);

  const employerName = [settings?.employer_legal_name, settings?.employer_address]
    .filter(Boolean)
    .join("\n");

  const readable = {
    firstName,
    lastName,
    address,
    cityStateZip,
    filingStatus,
    multipleJobs,
    qualifyingChildren,
    otherDependents,
    qualifyingChildrenAmount,
    otherDependentsAmount,
    otherCreditsAmount,
    otherIncome,
    deductions,
    extraWithholding,
    exempt,
    formYear: W4_CREDITS.formYear,
    signedOn,
  };

  const { data: draft, error: draftError } = await supabase
    .from("tax_form_submissions")
    .insert({
      staff_id: me.id,
      form_type: "W-4",
      status: "Draft",
      data: readable as unknown as Json,
    })
    .select("id")
    .single();

  if (draftError) return { error: draftError.message, ok: null };

  let pdf;
  try {
    pdf = await fillW4({
      firstName,
      lastName,
      address,
      cityStateZip,
      ssn,
      filingStatus,
      multipleJobs,
      qualifyingChildrenAmount,
      otherDependentsAmount,
      otherCreditsAmount,
      otherIncome,
      deductions,
      extraWithholding,
      exempt,
      employerName: employerName || undefined,
      employerEin: settings?.employer_ein || undefined,
      firstDateOfEmployment: employment?.started_on ? toIrsDate(employment.started_on) : undefined,
      signerName,
      signedOn: toIrsDate(signedOn),
    });
  } catch (err) {
    await supabase.from("tax_form_submissions").delete().eq("id", draft.id);
    return {
      error: `The form could not be generated: ${err instanceof Error ? err.message : "unknown error"}. Nothing was signed.`,
      ok: null,
    };
  }

  const storagePath = `staff/${me.id}/w4-${draft.id}.pdf`;

  const { error: uploadError } = await admin.storage
    .from("staff-files")
    .upload(storagePath, pdf.bytes, { contentType: "application/pdf", upsert: true });

  if (uploadError) {
    await supabase.from("tax_form_submissions").delete().eq("id", draft.id);
    return {
      error: `The form could not be stored: ${uploadError.message}. Nothing was signed.`,
      ok: null,
    };
  }

  const { data: fileRow } = await admin
    .from("staff_files")
    .insert({
      staff_id: me.id,
      storage_path: storagePath,
      filename: `W-4 ${fullName} ${signedOn}.pdf`,
      mime_type: "application/pdf",
      size_bytes: pdf.bytes.length,
      category: "W-4",
      note: `Completed in the CRM and signed by ${signerName}`,
      uploaded_by: me.id,
    })
    .select("id")
    .single();

  // The document details go on before signing, because a signed form is frozen.
  await supabase
    .from("tax_form_submissions")
    .update({
      pdf_path: storagePath,
      pdf_sha256: pdf.sha256,
      staff_file_id: fileRow?.id ?? null,
    })
    .eq("id", draft.id);

  const headerList = await headers();
  const ip =
    headerList.get("x-forwarded-for")?.split(",")[0]?.trim() ??
    headerList.get("x-real-ip") ??
    "";

  const { error: signError } = await supabase.rpc("sign_tax_form", {
    p_form_id: draft.id,
    p_sensitive: { ssn } as unknown as Json,
    p_tin_last4: ssn.slice(-4),
    p_signer: signerName,
    p_ip: ip,
  });

  if (signError) {
    return { error: `Not signed: ${signError.message}`, ok: null };
  }

  revalidatePath("/paperwork");
  revalidatePath("/admin/staff");
  return {
    error: null,
    ok: "Signed. Your W-4 is on file and will be used for the next payroll run.",
  };
}

/**
 * The employer block that goes on every W-4.
 *
 * Admin only, enforced in the database rather than by this screen being the
 * only way in.
 */
export async function saveEmployerDetails(
  _prev: PaperworkState,
  formData: FormData,
): Promise<PaperworkState> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("set_employer_details", {
    p_legal_name: String(formData.get("employer_legal_name") ?? "").trim(),
    p_address: String(formData.get("employer_address") ?? "").trim(),
    p_ein: String(formData.get("employer_ein") ?? "").trim(),
  });

  if (error) return { error: error.message, ok: null };

  revalidatePath("/paperwork");
  return { error: null, ok: "Employer details saved." };
}

/** A short-lived link to a stored form. Admin only — the bucket is Admin-only. */
export async function downloadTaxForm(
  _prev: PaperworkState,
  formData: FormData,
): Promise<PaperworkState & { url?: string }> {
  const me = await getCurrentStaff();
  if (me?.role !== "Admin") {
    return { error: "Filed forms are held for Admin only.", ok: null };
  }

  const path = String(formData.get("pdf_path") ?? "");
  const supabase = await createClient();
  const { data, error } = await supabase.storage.from("staff-files").createSignedUrl(path, 120);

  if (error || !data?.signedUrl) {
    return { error: "That form is not available.", ok: null };
  }
  return { error: null, ok: null, url: data.signedUrl };
}
