"use server";

import { can } from "@/lib/roles";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";
import { CAN_LOG_HOURS, today } from "@/lib/constants";

export type BillingState = { error: string | null; ok: string | null };

/**
 * The database raises these rules as check violations. Its messages are
 * written for people, so pass them through rather than replacing them with
 * something vaguer.
 */
function friendly(error: { message: string; code?: string }): string {
  const m = error.message.replace(/^new row for relation .* violates /, "");
  return m.charAt(0).toUpperCase() + m.slice(1);
}

export async function addAuthorization(
  _prev: BillingState,
  formData: FormData,
): Promise<BillingState> {
  const me = await getCurrentStaff();
  if (!me || !can(me, "billing", "edit")) {
    return { error: "Only Admin and Billing can add authorizations.", ok: null };
  }

  const str = (k: string) => String(formData.get(k) ?? "").trim();
  const rateType = str("rate_type") === "Flat Fee" ? "Flat Fee" : "Hourly";
  const totalHours = str("total_hours");

  if (!str("client_id")) return { error: "Choose a client.", ok: null };
  if (rateType === "Hourly" && !totalHours) {
    return { error: "An hourly authorization needs its authorized hours.", ok: null };
  }

  // Through the one door (§10): direct insert is revoked, so this is how a
  // billable record comes into being and there is no second way.
  //
  // No status is passed: the column defaults to Authorized, and the insert
  // trigger fills in received_on, stale_date and bill_by (§2).
  const supabase = await createClient();
  const { error } = await supabase.rpc("add_authorization", {
    p_client: str("client_id"),
    p_number: str("number"),
    p_service_type: str("service_type"),
    p_rate_type: rateType,
    p_rate: Number(str("rate") || 0),
    p_total_hours: rateType === "Hourly" ? Number(totalHours) : null,
    p_start: str("start_date") || null,
    p_end: str("end_date") || null,
    p_requires_forms: str("requires_forms"),
    p_funding_source: str("funding_source") || "Utah VR",
  });

  if (error) return { error: friendly(error), ok: null };

  revalidatePath("/billing");
  return { error: null, ok: `Authorization ${str("number")} saved.` };
}

/**
 * Log service hours.
 *
 * The two rules that matter — no future dates, and never past the authorized
 * hours — are enforced by a trigger, so they hold even if this action is
 * bypassed. What is done here is turning the database's refusal into something
 * the person reading it can act on.
 */
export async function logServiceEntry(
  _prev: BillingState,
  formData: FormData,
): Promise<BillingState> {
  const me = await getCurrentStaff();
  if (!me || !(CAN_LOG_HOURS.includes(me.role) || can(me, "billing", "edit"))) {
    return { error: "Your role cannot log service hours.", ok: null };
  }

  const str = (k: string) => String(formData.get(k) ?? "").trim();
  const authId = str("auth_id");
  const hours = str("hours");

  if (!authId) return { error: "Choose the authorization.", ok: null };
  if (!hours || Number(hours) <= 0) return { error: "How many hours?", ok: null };

  const supabase = await createClient();
  const { error } = await supabase.from("service_entries").insert({
    auth_id: authId,
    date: str("date"),
    hours: Number(hours),
    notes: str("notes"),
    non_billable: formData.get("non_billable") === "on",
    primary_code: str("primary_code"),
    secondary_code: str("secondary_code"),
    staff_id: me.id,
  });

  if (error) return { error: friendly(error), ok: null };

  revalidatePath("/billing");
  return { error: null, ok: `${hours} hours logged.` };
}

export async function updateCompletion(
  _prev: BillingState,
  formData: FormData,
): Promise<BillingState> {
  const me = await getCurrentStaff();
  if (!me || !can(me, "billing", "edit")) {
    return { error: "Only Admin and Billing can change completion dates.", ok: null };
  }

  const id = String(formData.get("completion_id") ?? "");
  const supabase = await createClient();
  const { error } = await supabase
    .from("completions")
    .update({
      start_date: String(formData.get("start_date") ?? "").trim() || null,
      completion: String(formData.get("completion") ?? "").trim() || null,
    })
    .eq("id", id);

  if (error) return { error: friendly(error), ok: null };

  revalidatePath("/billing");
  return { error: null, ok: "Saved." };
}

/**
 * The date a piece of work should be billed under, and the rule that gave it
 * (the CRP billing pathway).
 *
 * createInvoice, setInvoiceStatus and invoiceDateFor were here. §10 removed
 * them: there is one door to a bill and it is entering an authorization, so
 * there is nothing to raise and no status to type. An authorization becomes
 * Submitted when its packet is sent, and Paid when a warrant matches.
 *
 * The dating rule stayed, because it is about when the work happened and the
 * authorization needs it just as much.
 */
export async function serviceDateFor(authId: string): Promise<{ date: string; basis: string } | null> {
  const me = await getCurrentStaff();
  if (!me || !can(me, "billing", "edit") || !authId) return null;
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("service_date_for", { p_auth: authId });
  const row = data?.[0];
  if (error || !row?.on_date) return null;
  return { date: row.on_date, basis: row.basis ?? "" };
}
