"use server";

import { revalidatePath } from "next/cache";
import { headers } from "next/headers";
import { createClient } from "@/lib/supabase/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { getCurrentStaff } from "@/lib/session";
import { fillW8BEN, toIrsDate, W8BEN_LIMITS, type W8BenData } from "@/lib/irs-forms";
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
  revalidatePath("/staff");
  return {
    error: null,
    ok: "Signed. Your W-8BEN is on file, and the record shows it was received today.",
  };
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
