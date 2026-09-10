"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";
import { today } from "@/lib/constants";
import { createAdminClient } from "@/lib/supabase/admin";
import { ORG } from "@/lib/roles";
import {
  buildCopyB,
  buildGenericCsv,
  buildIrisCsv,
  type Payer1099,
  type FilingRow,
} from "@/lib/form-1099";

export type ContractorState = { error: string | null; ok: string | null };

const TAX_STATUSES = ["US person", "Foreign person"] as const;
const METHODS = ["Check", "ACH", "Cash", "Zelle", "Other"] as const;

/**
 * A contractor's details, as they will appear on a 1099.
 *
 * Every write here goes through the RLS-bound client, so "Admin only" is the
 * database's answer rather than this screen being the only door.
 */
export async function saveContractorProfile(
  _prev: ContractorState,
  formData: FormData,
): Promise<ContractorState> {
  const me = await getCurrentStaff();
  if (me?.role !== "Admin") return { error: "Only Admin can change these.", ok: null };

  const staffId = String(formData.get("staff_id") ?? "");
  if (!staffId) return { error: "No contractor given.", ok: null };

  const str = (k: string) => String(formData.get(k) ?? "").trim();
  const taxStatus = str("tax_status");
  if (!TAX_STATUSES.includes(taxStatus as (typeof TAX_STATUSES)[number])) {
    return { error: "Tax status must be US person or Foreign person.", ok: null };
  }

  const supabase = await createClient();

  // A person is one or the other, and the form they filed follows from that.
  // Changing the status without clearing the other form's date would leave a
  // profile claiming both a W-9 and a W-8BEN are current — which the database
  // refuses, but with a message nobody would understand.
  const clearOther =
    taxStatus === "US person"
      ? { w8ben_received_on: null }
      : { w9_received_on: null };

  const { error } = await supabase
    .from("contractor_profiles")
    .upsert(
      {
        staff_id: staffId,
        legal_name: str("legal_name"),
        business_name: str("business_name"),
        address_line1: str("address_line1"),
        address_line2: str("address_line2"),
        city: str("city"),
        state: str("state"),
        postal_code: str("postal_code"),
        tax_status: taxStatus,
        notes: str("notes"),
        ...clearOther,
      },
      { onConflict: "staff_id" },
    );

  if (error) return { error: error.message, ok: null };

  // The number is optional here: it usually arrives with a signed W-9 rather
  // than by hand. When it is typed in, it goes through the same encrypting
  // function the W-9 uses, so there is one way a TIN can be stored.
  const tin = str("tin").replace(/\D/g, "");
  if (tin) {
    const tinType = str("tin_type");
    if (tinType !== "SSN" && tinType !== "EIN") {
      return { error: "Say whether the number is an SSN or an EIN.", ok: null };
    }
    if (tin.length !== 9) {
      return { error: "A taxpayer identification number is nine digits.", ok: null };
    }
    if (taxStatus === "Foreign person") {
      return {
        error: "A foreign person does not have a US taxpayer number recorded here.",
        ok: null,
      };
    }
    const { error: tinError } = await supabase.rpc("set_contractor_tin", {
      p_staff_id: staffId,
      p_tin: tin,
      p_tin_type: tinType,
    });
    if (tinError) return { error: tinError.message, ok: null };
  }

  revalidatePath("/admin/contractors");
  return { error: null, ok: "Saved." };
}

/** What was actually paid, which is what a 1099 reports. */
export async function recordContractorPayment(
  _prev: ContractorState,
  formData: FormData,
): Promise<ContractorState> {
  const me = await getCurrentStaff();
  if (me?.role !== "Admin") return { error: "Only Admin can record payments.", ok: null };

  const staffId = String(formData.get("staff_id") ?? "");
  const paidOn = String(formData.get("paid_on") ?? "");
  const amount = Number(formData.get("amount") ?? 0);
  const method = String(formData.get("method") ?? "Check");
  const statementId = String(formData.get("statement_id") ?? "");

  if (!staffId) return { error: "Choose who was paid.", ok: null };
  if (!/^\d{4}-\d{2}-\d{2}$/.test(paidOn)) return { error: "Check the payment date.", ok: null };
  if (!(amount > 0)) return { error: "A payment has to be more than zero.", ok: null };
  if (!METHODS.includes(method as (typeof METHODS)[number])) {
    return { error: "Unknown payment method.", ok: null };
  }

  const supabase = await createClient();
  const { error } = await supabase.from("contractor_payments").insert({
    staff_id: staffId,
    statement_id: statementId || null,
    paid_on: paidOn,
    amount,
    method,
    reference: String(formData.get("reference") ?? "").trim(),
    note: String(formData.get("note") ?? "").trim(),
    created_by: me.id,
  });

  if (error) return { error: error.message, ok: null };

  revalidatePath("/admin/contractors");
  return { error: null, ok: `Recorded $${amount.toFixed(2)} paid on ${paidOn}.` };
}

/**
 * Remove a payment that was recorded wrongly.
 *
 * Payments are not append-only the way time records are. A time record is
 * somebody's account of what they did; a payment is a bookkeeping entry, and an
 * entry made against the wrong person or for the wrong amount should be taken
 * out rather than corrected by a second entry that says the opposite.
 */
export async function deleteContractorPayment(
  _prev: ContractorState,
  formData: FormData,
): Promise<ContractorState> {
  const me = await getCurrentStaff();
  if (me?.role !== "Admin") return { error: "Only Admin can remove payments.", ok: null };

  const id = String(formData.get("payment_id") ?? "");
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("contractor_payments")
    .delete()
    .eq("id", id)
    .select("amount, paid_on")
    .maybeSingle();

  if (error) return { error: error.message, ok: null };
  if (!data) return { error: "That payment is no longer there.", ok: null };

  revalidatePath("/admin/contractors");
  return { error: null, ok: `Removed the $${Number(data.amount).toFixed(2)} payment.` };
}

/**
 * The two figures a 1099 run depends on, which are not ours to invent.
 *
 * The federal threshold is confirmed with the CPA each January, and whether
 * Utah wants its own copy is a standing setting. Until the threshold is
 * confirmed, form_1099_candidates returns nothing at all — no run can be built
 * on a number nobody has stood behind.
 */
export async function saveTaxYear(
  _prev: ContractorState,
  formData: FormData,
): Promise<ContractorState> {
  const me = await getCurrentStaff();
  if (me?.role !== "Admin") return { error: "Only Admin can change these.", ok: null };

  const year = Number(formData.get("year") ?? 0);
  if (!Number.isInteger(year) || year < 2020 || year > 2100) {
    return { error: "Check the year.", ok: null };
  }

  const raw = String(formData.get("federal_threshold") ?? "").trim();
  const threshold = raw === "" ? null : Number(raw);
  if (threshold !== null && !(threshold > 0)) {
    return { error: "A threshold is a positive amount, or leave it blank.", ok: null };
  }

  const confirming = formData.get("confirm") === "on";
  if (confirming && threshold === null) {
    return { error: "There is nothing to confirm until the threshold is entered.", ok: null };
  }

  const supabase = await createClient();

  // A confirmation is somebody standing behind a particular figure, so it
  // belongs to that figure. Re-saving with the same threshold keeps the
  // original name and date — editing a note should not restamp it as though it
  // were checked again today. Changing the threshold restamps it, because what
  // was confirmed is no longer what is stored.
  const { data: existing } = await supabase
    .from("tax_years")
    .select("federal_threshold, confirmed_by, confirmed_on")
    .eq("year", year)
    .maybeSingle();

  const unchanged =
    existing?.confirmed_on != null && Number(existing.federal_threshold) === threshold;

  const { error } = await supabase.from("tax_years").upsert(
    {
      year,
      federal_threshold: threshold,
      utah_state_copy: formData.get("utah_state_copy") === "on",
      notes: String(formData.get("notes") ?? "").trim(),
      confirmed_by: confirming ? (unchanged ? existing.confirmed_by : me.id) : null,
      confirmed_on: confirming ? (unchanged ? existing.confirmed_on : today()) : null,
    },
    { onConflict: "year" },
  );

  if (error) return { error: error.message, ok: null };

  revalidatePath("/admin/contractors");
  revalidatePath("/dashboard");
  return {
    error: null,
    ok: confirming
      ? `${year} confirmed. The 1099 run can be built.`
      : `${year} saved, not yet confirmed.`,
  };
}

// ─────────────────────────────────────────────────────────────
// 1099 runs
// ─────────────────────────────────────────────────────────────

/** Builds the run for a year. The database refuses if anything is not ready. */
export async function generate1099Run(
  _prev: ContractorState,
  formData: FormData,
): Promise<ContractorState> {
  const me = await getCurrentStaff();
  if (me?.role !== "Admin") return { error: "Only Admin can generate a run.", ok: null };

  const year = Number(formData.get("year") ?? 0);
  if (!Number.isInteger(year)) return { error: "Check the year.", ok: null };

  const supabase = await createClient();
  const { error } = await supabase.rpc("generate_1099_run", { p_year: year });

  if (error) return { error: error.message, ok: null };

  revalidatePath("/admin/contractors");
  return { error: null, ok: `The ${year} run is built. Check it before anything is filed.` };
}

/** Marks one copy as delivered. Electronic delivery without consent is refused. */
export async function record1099Delivery(
  _prev: ContractorState,
  formData: FormData,
): Promise<ContractorState> {
  const me = await getCurrentStaff();
  if (me?.role !== "Admin") return { error: "Only Admin can record delivery.", ok: null };

  const supabase = await createClient();
  const { error } = await supabase.rpc("record_1099_delivery", {
    p_recipient_id: String(formData.get("recipient_id") ?? ""),
    p_method: String(formData.get("method") ?? ""),
    p_delivered_on: String(formData.get("delivered_on") ?? "") || today(),
  });

  if (error) return { error: error.message, ok: null };

  revalidatePath("/admin/contractors");
  return { error: null, ok: "Delivery recorded." };
}

/** What was filed, and when. Recorded once the return has actually gone in. */
export async function recordRunFiled(
  _prev: ContractorState,
  formData: FormData,
): Promise<ContractorState> {
  const me = await getCurrentStaff();
  if (me?.role !== "Admin") return { error: "Only Admin can record a filing.", ok: null };

  const filedOn = String(formData.get("filed_on") ?? "").trim();
  if (filedOn && !/^\d{4}-\d{2}-\d{2}$/.test(filedOn)) {
    return { error: "Check the filing date.", ok: null };
  }
  if (filedOn && filedOn > today()) {
    return { error: "A return cannot be filed in the future.", ok: null };
  }

  const supabase = await createClient();
  const { error } = await supabase
    .from("form_1099_runs")
    .update({
      filed_on: filedOn || null,
      iris_receipt: String(formData.get("iris_receipt") ?? "").trim(),
      notes: String(formData.get("notes") ?? "").trim(),
    })
    .eq("id", String(formData.get("run_id") ?? ""));

  if (error) return { error: error.message, ok: null };

  revalidatePath("/admin/contractors");
  return { error: null, ok: "Saved." };
}

/** The payer block, read with the service role because the EIN is Admin-only. */
async function payerDetails(): Promise<Payer1099 | null> {
  const admin = createAdminClient();
  const { data } = await admin
    .from("org_settings")
    .select("employer_legal_name, employer_address, employer_ein")
    .eq("id", true)
    .maybeSingle();

  // Both, or nothing. The payer on a 1099 is the legal entity that files it —
  // Zion Healing Academy LLC — and ORG.name is the dba it trades under. A
  // fallback here would quietly put the trading name on a tax return.
  if (!data?.employer_ein || !data?.employer_legal_name) return null;

  return {
    name: data.employer_legal_name,
    address: data.employer_address || ORG.address,
    phone: ORG.phone,
    ein: data.employer_ein,
  };
}

/**
 * One recipient's Copy B, handed straight back rather than stored.
 *
 * It is regenerated from the run's own snapshot every time, so there is no
 * second copy of anybody's tax document sitting in a bucket waiting to drift
 * out of step with the record.
 */
export async function downloadCopyB(
  _prev: ContractorState,
  formData: FormData,
): Promise<ContractorState & { filename?: string; contentBase64?: string }> {
  const me = await getCurrentStaff();
  if (me?.role !== "Admin") return { error: "Only Admin can open these.", ok: null };

  const supabase = await createClient();
  const { data: r } = await supabase
    .from("form_1099_recipients")
    .select("*, form_1099_runs(year)")
    .eq("id", String(formData.get("recipient_id") ?? ""))
    .maybeSingle();

  if (!r) return { error: "No such recipient.", ok: null };

  const payer = await payerDetails();
  if (!payer) {
    return {
      error: "Set the employer name, address and EIN on the Paperwork screen first.",
      ok: null,
    };
  }

  const year = (r.form_1099_runs as unknown as { year: number } | null)?.year ?? 0;

  const pdf = await buildCopyB(year, payer, {
    id: r.id,
    legalName: r.legal_name,
    businessName: r.business_name,
    addressSnapshot: r.address_snapshot,
    tinType: r.tin_type,
    tinLast4: r.tin_last4,
    nonemployeeComp: Number(r.nonemployee_comp),
    corrected: r.corrected,
  });

  return {
    error: null,
    ok: null,
    filename: `1099-NEC ${year} ${r.legal_name}.pdf`,
    contentBase64: Buffer.from(pdf.bytes).toString("base64"),
  };
}

/**
 * A filing file for the whole run.
 *
 * This is the only place the taxpayer numbers come back out in the clear, and
 * they come out one at a time through the Admin-only function that logs the
 * intent. The file is handed straight to the browser and never written to
 * storage: a spreadsheet of social security numbers should exist for as long
 * as it takes to upload it and no longer.
 */
export async function downloadFilingCsv(
  _prev: ContractorState,
  formData: FormData,
): Promise<ContractorState & { filename?: string; contentBase64?: string }> {
  const me = await getCurrentStaff();
  if (me?.role !== "Admin") return { error: "Only Admin can open these.", ok: null };

  const runId = String(formData.get("run_id") ?? "");
  const kind = String(formData.get("kind") ?? "generic");

  const supabase = await createClient();
  const { data: run } = await supabase
    .from("form_1099_runs")
    .select("id, year")
    .eq("id", runId)
    .maybeSingle();

  if (!run) return { error: "No such run.", ok: null };

  const { data: recipients } = await supabase
    .from("form_1099_recipients")
    .select("*")
    .eq("run_id", runId)
    .order("legal_name");

  const payer = await payerDetails();
  if (!payer) {
    return {
      error: "Set the employer name, address and EIN on the Paperwork screen first.",
      ok: null,
    };
  }

  const rows: FilingRow[] = [];
  for (const r of recipients ?? []) {
    const { data: tin, error } = await supabase.rpc("get_contractor_tin", {
      p_staff_id: r.staff_id,
    });
    if (error || !tin) {
      return {
        error: `${r.legal_name} has no taxpayer number on file, so the filing cannot be built.`,
        ok: null,
      };
    }
    rows.push({
      id: r.id,
      legalName: r.legal_name,
      businessName: r.business_name,
      addressSnapshot: r.address_snapshot,
      tinType: r.tin_type,
      tinLast4: r.tin_last4,
      nonemployeeComp: Number(r.nonemployee_comp),
      corrected: r.corrected,
      tin: String(tin),
    });
  }

  const content =
    kind === "iris"
      ? buildIrisCsv(run.year, payer, rows)
      : buildGenericCsv(run.year, payer, rows);

  return {
    error: null,
    ok: null,
    filename: `1099-NEC ${run.year} ${kind === "iris" ? "IRIS" : "filing"}.csv`,
    contentBase64: Buffer.from(content, "utf8").toString("base64"),
  };
}

/** A contractor's own agreement to receive their 1099 electronically. */
export async function setEDeliveryConsent(
  _prev: ContractorState,
  formData: FormData,
): Promise<ContractorState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const supabase = await createClient();
  const consent = formData.get("consent") === "on";
  const { error } = await supabase.rpc("set_e_delivery_consent", { p_consent: consent });

  if (error) return { error: error.message, ok: null };

  revalidatePath("/paperwork");
  revalidatePath("/admin/contractors");
  return {
    error: null,
    ok: consent
      ? "Thank you — your 1099 will be sent electronically."
      : "Noted. Your 1099 will be posted to you.",
  };
}
