"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";
import { today } from "@/lib/constants";

export type HoursState = { error: string | null; ok: string | null };

/** The database's messages here are written for people; pass them through. */
function friendly(error: { message: string }): string {
  const m = error.message.replace(/^new row for relation .* violates /, "");
  return m.charAt(0).toUpperCase() + m.slice(1);
}

/**
 * Log a work session.
 *
 * A contractor records what they did and when. There is no clock, no shift and
 * no break: this is a record of work performed, which is what a statement and
 * an invoice are built from.
 */
export async function logSession(_prev: HoursState, formData: FormData): Promise<HoursState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const workedOn = String(formData.get("worked_on") ?? "").trim();
  const hours = String(formData.get("hours") ?? "").trim();
  const description = String(formData.get("description") ?? "").trim();

  if (!workedOn) return { error: "Which day?", ok: null };
  if (!hours || Number(hours) <= 0) return { error: "How many hours?", ok: null };
  if (workedOn > today()) {
    return { error: "That day has not happened yet.", ok: null };
  }
  if (!description) {
    return { error: "Say what the time was spent on — it is the billing record.", ok: null };
  }

  const supabase = await createClient();
  const { error } = await supabase.from("work_sessions").insert({
    staff_id: me.id,
    worked_on: workedOn,
    hours: Number(hours),
    description,
    client_id: String(formData.get("client_id") ?? "").trim() || null,
    created_by: me.id,
  });

  if (error) return { error: friendly(error), ok: null };

  revalidatePath("/hours");
  return { error: null, ok: `${hours} hours logged.` };
}

/**
 * Correct a session.
 *
 * Never an edit: this adds a replacement row that references the original and
 * records the reason. The original stays readable, which is the whole point of
 * keeping time records this way.
 */
export async function correctSession(_prev: HoursState, formData: FormData): Promise<HoursState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const correctsId = String(formData.get("corrects_id") ?? "");
  const hours = String(formData.get("hours") ?? "").trim();
  const reason = String(formData.get("correction_reason") ?? "").trim();

  if (!hours || Number(hours) <= 0) return { error: "What should the hours be?", ok: null };
  if (!reason) return { error: "A correction has to say why.", ok: null };

  const supabase = await createClient();

  const { data: original } = await supabase
    .from("work_sessions")
    .select("staff_id, worked_on, description, client_id")
    .eq("id", correctsId)
    .maybeSingle();

  if (!original) return { error: "That entry no longer exists.", ok: null };

  const { error } = await supabase.from("work_sessions").insert({
    staff_id: original.staff_id,
    worked_on: original.worked_on,
    hours: Number(hours),
    description: String(formData.get("description") ?? "").trim() || original.description,
    client_id: original.client_id,
    corrects_id: correctsId,
    correction_reason: reason,
    created_by: me.id,
  });

  if (error) return { error: friendly(error), ok: null };

  revalidatePath("/hours");
  return { error: null, ok: "Corrected. The original entry stays on file with your reason." };
}

/**
 * Submit the period's hours as a statement.
 *
 * Everything logged in the period that is not already on a statement is
 * attached, then the whole thing goes to Admin.
 */
export async function submitStatement(_prev: HoursState, formData: FormData): Promise<HoursState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const periodStart = String(formData.get("period_start") ?? "");
  const periodEnd = String(formData.get("period_end") ?? "");
  if (!periodStart || !periodEnd) return { error: "Which period?", ok: null };

  const supabase = await createClient();

  const { data: existing } = await supabase
    .from("contractor_statements")
    .select("id, status")
    .eq("staff_id", me.id)
    .eq("period_start", periodStart)
    .maybeSingle();

  if (existing?.status === "Approved") {
    return { error: "That period is already approved.", ok: null };
  }
  if (existing?.status === "Submitted") {
    return { error: "That period is already with Admin.", ok: null };
  }

  let statementId = existing?.id;
  if (!statementId) {
    const { data: created, error } = await supabase
      .from("contractor_statements")
      .insert({
        staff_id: me.id,
        period_start: periodStart,
        period_end: periodEnd,
        status: "Draft",
      })
      .select("id")
      .single();
    if (error) return { error: friendly(error), ok: null };
    statementId = created.id;
  }

  const { error: attachError } = await supabase
    .from("work_sessions")
    .update({ statement_id: statementId })
    .eq("staff_id", me.id)
    .eq("voided", false)
    .is("statement_id", null)
    .gte("worked_on", periodStart)
    .lte("worked_on", periodEnd);

  if (attachError) return { error: friendly(attachError), ok: null };

  const { error: submitError } = await supabase
    .from("contractor_statements")
    .update({ status: "Submitted" })
    .eq("id", statementId);

  if (submitError) return { error: friendly(submitError), ok: null };

  revalidatePath("/hours");
  return { error: null, ok: "Submitted to Admin." };
}

/** Admin approves a statement, or returns it with a note saying what to fix. */
export async function decideStatement(_prev: HoursState, formData: FormData): Promise<HoursState> {
  const me = await getCurrentStaff();
  if (me?.role !== "Admin") return { error: "Only Admin approves statements.", ok: null };

  const id = String(formData.get("statement_id") ?? "");
  const decision = String(formData.get("decision") ?? "");
  const note = String(formData.get("return_note") ?? "").trim();

  if (decision === "Returned" && !note) {
    return { error: "Say what needs changing, or they cannot act on it.", ok: null };
  }

  const supabase = await createClient();
  const { error } = await supabase
    .from("contractor_statements")
    .update({
      status: decision === "Approved" ? "Approved" : "Returned",
      return_note: decision === "Returned" ? note : "",
      decided_by: me.id,
    })
    .eq("id", id);

  if (error) return { error: friendly(error), ok: null };

  revalidatePath("/hours");
  return { error: null, ok: decision === "Approved" ? "Approved." : "Returned with your note." };
}

/** Reopening an approved statement, so settled hours can be corrected. */
export async function reopenStatement(_prev: HoursState, formData: FormData): Promise<HoursState> {
  const me = await getCurrentStaff();
  if (me?.role !== "Admin") return { error: "Only Admin can reopen a statement.", ok: null };

  const supabase = await createClient();
  const { error } = await supabase
    .from("contractor_statements")
    .update({ status: "Returned", return_note: "Reopened by Admin for correction." })
    .eq("id", String(formData.get("statement_id") ?? ""));

  if (error) return { error: friendly(error), ok: null };

  revalidatePath("/hours");
  return { error: null, ok: "Reopened. The hours on it can be corrected again." };
}
