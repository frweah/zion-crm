"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";
import { CAN_EDIT_BILLING, CAN_LOG_HOURS } from "@/lib/constants";

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
  if (!me || !CAN_EDIT_BILLING.includes(me.role)) {
    return { error: "Only Admin and Billing can add authorizations.", ok: null };
  }

  const str = (k: string) => String(formData.get(k) ?? "").trim();
  const rateType = str("rate_type") === "Flat Fee" ? "Flat Fee" : "Hourly";
  const totalHours = str("total_hours");

  if (!str("client_id")) return { error: "Choose a client.", ok: null };
  if (rateType === "Hourly" && !totalHours) {
    return { error: "An hourly authorization needs its authorized hours.", ok: null };
  }

  const supabase = await createClient();
  const { error } = await supabase.from("authorizations").insert({
    client_id: str("client_id"),
    number: str("number"),
    service_type: str("service_type"),
    funding_source: str("funding_source") || "Utah VR",
    rate_type: rateType,
    rate: Number(str("rate") || 0),
    total_hours: rateType === "Hourly" ? Number(totalHours) : null,
    start_date: str("start_date") || null,
    end_date: str("end_date") || null,
    requires_forms: str("requires_forms"),
    status: "Open",
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
  if (!me || !CAN_LOG_HOURS.includes(me.role)) {
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
  if (!me || !CAN_EDIT_BILLING.includes(me.role)) {
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

export async function createInvoice(
  _prev: BillingState,
  formData: FormData,
): Promise<BillingState> {
  const me = await getCurrentStaff();
  if (!me || !CAN_EDIT_BILLING.includes(me.role)) {
    return { error: "Only Admin and Billing can raise invoices.", ok: null };
  }

  const str = (k: string) => String(formData.get(k) ?? "").trim();
  if (!str("auth_id")) return { error: "Choose the authorization.", ok: null };
  if (!str("number")) return { error: "An invoice number is required.", ok: null };
  if (!str("amount")) return { error: "An amount is required.", ok: null };

  const supabase = await createClient();
  const { error } = await supabase.from("invoices").insert({
    auth_id: str("auth_id"),
    number: str("number"),
    date: str("date") || undefined,
    amount: Number(str("amount")),
    status: "Draft",
  });

  if (error) return { error: friendly(error), ok: null };

  revalidatePath("/billing");
  return { error: null, ok: `Invoice ${str("number")} saved as a draft.` };
}

/**
 * Move an invoice to Sent or Paid.
 *
 * Marking Sent is refused by the database until every USOR form required for
 * that service type is out of Draft. That refusal is the point of the rule, so
 * it is shown as written rather than swallowed.
 */
export async function setInvoiceStatus(
  _prev: BillingState,
  formData: FormData,
): Promise<BillingState> {
  const me = await getCurrentStaff();
  if (!me || !CAN_EDIT_BILLING.includes(me.role)) {
    return { error: "Only Admin and Billing can change an invoice.", ok: null };
  }

  const id = String(formData.get("invoice_id") ?? "");
  const status = String(formData.get("status") ?? "");
  const todayStr = new Date().toISOString().slice(0, 10);

  const supabase = await createClient();
  const { error } = await supabase
    .from("invoices")
    .update({
      status,
      ...(status === "Sent" ? { sent_date: todayStr } : {}),
      ...(status === "Paid" ? { paid_date: todayStr } : {}),
    })
    .eq("id", id);

  if (error) return { error: friendly(error), ok: null };

  revalidatePath("/billing");
  return { error: null, ok: `Invoice marked ${status}.` };
}
