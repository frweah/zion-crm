"use server";

import { revalidatePath } from "next/cache";
import { can } from "@/lib/roles";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";

export type QueryState = { error: string | null; ok: string | null };

/**
 * Record what came of querying an invoice (0312).
 *
 * The half Phase 3 left out. A short payment was raised with the difference
 * on it and then raised again every night, because nothing could tell the
 * chase that somebody had rung the office and been given an answer.
 *
 * One note is one exchange and nothing here edits one: the next call is the
 * next note. Marked as settling it, the note takes the short-paid item off My
 * day - and it never takes money still owed off any list, which is the
 * database's rule rather than this screen's.
 */
export async function recordInvoiceQuery(
  _prev: QueryState,
  formData: FormData,
): Promise<QueryState> {
  const me = await getCurrentStaff();
  if (!me || !can(me, "billing", "edit")) {
    return { error: "Only Admin and Billing record what came of a query.", ok: null };
  }

  const invoiceId = String(formData.get("invoice_id") ?? "");
  const askedOf = String(formData.get("asked_of") ?? "").trim();
  const said = String(formData.get("said") ?? "").trim();
  const askedOn = String(formData.get("asked_on") ?? "").trim();
  const resolved = formData.get("resolved") === "on";

  if (!invoiceId) return { error: "Which invoice?", ok: null };
  if (!askedOf) return { error: "Say who was asked.", ok: null };
  if (resolved && !said) return { error: "Say what settled it.", ok: null };

  const supabase = await createClient();
  const { error } = await supabase.rpc("record_invoice_query", {
    p_invoice: invoiceId,
    p_asked_of: askedOf,
    p_said: said || undefined,
    p_resolved: resolved,
    p_asked_on: askedOn || undefined,
  });
  if (error) return { error: error.message, ok: null };

  revalidatePath("/billing/invoices");
  revalidatePath("/dashboard");
  return {
    error: null,
    ok: resolved ? "Recorded, and it stops being raised." : "Recorded.",
  };
}
