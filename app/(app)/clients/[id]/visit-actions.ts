"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";
import { autofillForm } from "@/lib/form-autofill";
import { templateById } from "@/lib/form-templates";
import { can } from "@/lib/roles";
import { today, CAN_LOG_HOURS } from "@/lib/constants";
import type { Json } from "@/lib/database.types";

/**
 * The two things staff do to a client record most often, done on the record.
 *
 * Logging a visit and billing for it were both journeys: out to Billing, find
 * the client again, find the authorization, come back. The rules are
 * unchanged - the hours trigger still refuses a future date or an overrun,
 * and the forms gate still decides what may be invoiced. Only the walk is
 * gone.
 */
export type VisitState = { error: string | null; ok: string | null };

function friendly(message: string): string {
  if (/authorized hours|additional hours/i.test(message)) {
    return "That would take the authorization past its authorized hours. Ask the counselor for more before logging it.";
  }
  if (/future/i.test(message)) return "That date has not happened yet.";
  return message;
}

/** A visit, against the authorization it is billable to. */
export async function logVisit(_prev: VisitState, formData: FormData): Promise<VisitState> {
  const me = await getCurrentStaff();
  if (!me || !(CAN_LOG_HOURS.includes(me.role) || can(me, "billing", "edit"))) {
    return { error: "Your role cannot log service hours.", ok: null };
  }

  const str = (k: string) => String(formData.get(k) ?? "").trim();
  const clientId = str("client_id");
  const authId = str("auth_id");
  const hours = Number(str("hours"));

  if (!authId) return { error: "Choose the authorization this visit is against.", ok: null };
  if (!hours || hours <= 0) return { error: "How many hours was the visit?", ok: null };

  const supabase = await createClient();
  const { error } = await supabase.from("service_entries").insert({
    auth_id: authId,
    date: str("date") || today(),
    hours,
    notes: str("notes"),
    non_billable: formData.get("non_billable") === "on",
    primary_code: str("primary_code"),
    secondary_code: str("secondary_code"),
    staff_id: me.id,
  });
  if (error) return { error: friendly(error.message), ok: null };

  revalidatePath(`/clients/${clientId}`);
  revalidatePath("/billing");
  return { error: null, ok: `${hours} hours logged against the authorization.` };
}

/**
 * Report & bill: open the USOR form this authorization needs, pre-filled.
 *
 * The form itself, the pre-fill and the signing are the forms engine's, all
 * of it already built. What this adds is arriving at the right one without
 * choosing a template from a list of eight.
 */
export async function startBilling(_prev: VisitState, formData: FormData): Promise<VisitState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const clientId = String(formData.get("client_id") ?? "");
  const authId = String(formData.get("auth_id") ?? "").trim();
  const templateId = String(formData.get("template_id") ?? "").trim();
  const month = String(formData.get("month") ?? "").trim() || today().slice(0, 7);
  if (!authId || !templateId) return { error: "Choose the authorization and the form.", ok: null };

  const tpl = templateById(templateId);
  if (!tpl) return { error: "Unknown form.", ok: null };

  const supabase = await createClient();

  // A form already open for this authorization and month is the one to carry
  // on with - starting a second would split the month's hours across two.
  let draft = supabase
    .from("forms")
    .select("id")
    .eq("client_id", clientId)
    .eq("auth_id", authId)
    .eq("template_id", templateId)
    .eq("status", "Draft");
  // A monthly form is one per month; anything else is one per authorization.
  draft = tpl.monthly ? draft.eq("month", month) : draft.is("month", null);
  const { data: open } = await draft.limit(1).maybeSingle();

  if (open) redirect(`/clients/${clientId}/forms/${open.id}`);

  const data = await autofillForm(templateId, clientId, authId, month);
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
