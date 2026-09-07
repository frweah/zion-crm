"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";
import { today } from "@/lib/constants";

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

  revalidatePath("/contractors");
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

  revalidatePath("/contractors");
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

  revalidatePath("/contractors");
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

  revalidatePath("/contractors");
  revalidatePath("/dashboard");
  return {
    error: null,
    ok: confirming
      ? `${year} confirmed. The 1099 run can be built.`
      : `${year} saved, not yet confirmed.`,
  };
}
