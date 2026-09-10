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
/**
 * The category, if one was chosen.
 *
 * Optional on purpose: the practice is adopting categories on work that is
 * already being logged, and refusing an hour because somebody did not pick
 * from a list would lose the hour, not gain the category. A blank can be
 * filled in later; a wrong one needs a correction.
 */
function categoryOf(formData: FormData): string | null {
  const v = String(formData.get("category") ?? "").trim();
  return v === "" ? null : v;
}

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
    category: categoryOf(formData),
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
    .select("staff_id, worked_on, description, client_id, category")
    .eq("id", correctsId)
    .maybeSingle();

  if (!original) return { error: "That entry no longer exists.", ok: null };

  const { error } = await supabase.from("work_sessions").insert({
    staff_id: original.staff_id,
    worked_on: original.worked_on,
    hours: Number(hours),
    description: String(formData.get("description") ?? "").trim() || original.description,
    category: categoryOf(formData) ?? original.category,
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

  // Expenses go the same way, and in the same submission: a period is one
  // claim for hours and out-of-pocket together, because it becomes one
  // payment.
  const { error: expenseError } = await supabase
    .from("expenses")
    .update({ statement_id: statementId })
    .eq("staff_id", me.id)
    .is("statement_id", null)
    .gte("incurred_on", periodStart)
    .lte("incurred_on", periodEnd);

  if (expenseError) return { error: friendly(expenseError), ok: null };

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

// ─────────────────────────────────────────────────────────────
// The timer
//
// A convenience for logging, not a shift clock. It offers an elapsed figure;
// the person confirms or corrects it and says what they did, and only then is
// an ordinary work session written — by logSession's own rules, through the
// same append-only table.
// ─────────────────────────────────────────────────────────────

/** Starts the clock. One at a time, which the primary key guarantees. */
export async function startWorkTimer(_prev: HoursState): Promise<HoursState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const supabase = await createClient();
  const { error } = await supabase
    .from("work_session_timers")
    .insert({ staff_id: me.id });

  if (error) {
    return {
      error: error.code === "23505" ? "A session is already running." : error.message,
      ok: null,
    };
  }

  revalidatePath("/hours");
  revalidatePath("/dashboard");
  return { error: null, ok: "Started." };
}

/**
 * Stops the clock without logging anything.
 *
 * Offered plainly rather than hidden, because the commonest reason to end a
 * timer is that it was left running by mistake, and somebody who cannot throw
 * one away will log a wrong figure instead.
 */
export async function discardWorkTimer(_prev: HoursState): Promise<HoursState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const supabase = await createClient();
  const { error } = await supabase.from("work_session_timers").delete().eq("staff_id", me.id);
  if (error) return { error: error.message, ok: null };

  revalidatePath("/hours");
  revalidatePath("/dashboard");
  return { error: null, ok: "Timer discarded. Nothing was logged." };
}

/**
 * Saves what the timer measured, as an ordinary work session.
 *
 * The hours arrive from the form rather than being recomputed here: the person
 * has had the chance to change them, and the figure they agreed to is the one
 * that should be recorded.
 */
export async function saveTimerSession(
  _prev: HoursState,
  formData: FormData,
): Promise<HoursState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const hours = Number(String(formData.get("hours") ?? "").trim());
  const description = String(formData.get("description") ?? "").trim();
  const workedOn = String(formData.get("worked_on") ?? "").trim() || today();

  if (!(hours > 0)) return { error: "How many hours?", ok: null };
  if (hours > 24) return { error: "A day is not longer than 24 hours.", ok: null };
  if (!description) {
    return { error: "Say what the time was spent on — it is the billing record.", ok: null };
  }
  if (workedOn > today()) return { error: "That day has not happened yet.", ok: null };

  const supabase = await createClient();
  const { error } = await supabase.from("work_sessions").insert({
    staff_id: me.id,
    worked_on: workedOn,
    hours,
    description,
    category: categoryOf(formData),
    client_id: String(formData.get("client_id") ?? "").trim() || null,
    created_by: me.id,
  });

  if (error) return { error: friendly(error), ok: null };

  // Only once the session exists. A timer cleared before the insert succeeded
  // would lose the afternoon it was measuring.
  await supabase.from("work_session_timers").delete().eq("staff_id", me.id);

  revalidatePath("/hours");
  revalidatePath("/dashboard");
  return { error: null, ok: `${hours} hours logged.` };
}

/**
 * Fill in the category on a session that has none.
 *
 * The one door the append-only trigger leaves open: blank may become a value,
 * a value may never become a different value. Anything else is a correction.
 */
export async function setSessionCategory(
  _prev: HoursState,
  formData: FormData,
): Promise<HoursState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const id = String(formData.get("session_id") ?? "");
  const category = String(formData.get("category") ?? "").trim();
  if (!id || !category) return { error: "Choose what the time was.", ok: null };

  const supabase = await createClient();
  const { error } = await supabase
    .from("work_sessions")
    .update({ category })
    .eq("id", id)
    .is("category", null);

  if (error) return { error: friendly(error), ok: null };

  revalidatePath("/hours");
  return { error: null, ok: "Categorised." };
}

/**
 * Claim something out of pocket.
 *
 * Mileage is miles, never an amount: what it comes to is the rate on the day
 * it was driven, and that is the database's arithmetic rather than something
 * anybody types. A claim on a day no rate covers is still recorded — it shows
 * as miles with no amount, which is a question for Admin rather than a
 * reason to lose the claim.
 */
export async function addExpense(_prev: HoursState, formData: FormData): Promise<HoursState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const str = (k: string) => String(formData.get(k) ?? "").trim();
  const category = str("category");
  const incurredOn = str("incurred_on");
  const description = str("description");

  if (!category) return { error: "What kind of expense?", ok: null };
  if (!incurredOn) return { error: "When was it?", ok: null };
  if (incurredOn > today()) return { error: "That day has not happened yet.", ok: null };

  const supabase = await createClient();
  const { data: cat } = await supabase
    .from("expense_categories")
    .select("label, is_mileage, needs_receipt")
    .eq("key", category)
    .maybeSingle();

  if (!cat) return { error: "Unknown kind of expense.", ok: null };

  const miles = cat.is_mileage ? Number(str("miles")) : null;
  const amount = cat.is_mileage ? null : Number(str("amount"));

  if (cat.is_mileage && !(miles && miles > 0)) return { error: "How many miles?", ok: null };
  if (!cat.is_mileage && !(amount && amount > 0)) return { error: "How much was it?", ok: null };
  if (!description && !cat.is_mileage) {
    return { error: "Say what it was for — a figure with no description is not a claim.", ok: null };
  }

  const { error } = await supabase.from("expenses").insert({
    staff_id: me.id,
    incurred_on: incurredOn,
    category,
    description,
    amount,
    miles,
    from_place: str("from_place"),
    to_place: str("to_place"),
    client_id: str("client_id") || null,
    created_by: me.id,
  });

  if (error) return { error: friendly(error), ok: null };

  revalidatePath("/hours");
  return {
    error: null,
    ok: cat.is_mileage
      ? `${miles} miles claimed. What it comes to is worked out from the rate on ${incurredOn}.`
      : `${cat.label} claimed.`,
  };
}

/** Remove a claim that has not been submitted. */
export async function removeExpense(_prev: HoursState, formData: FormData): Promise<HoursState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const supabase = await createClient();
  const { error } = await supabase
    .from("expenses")
    .delete()
    .eq("id", String(formData.get("expense_id") ?? ""))
    .eq("staff_id", me.id)
    .is("statement_id", null);

  if (error) return { error: friendly(error), ok: null };

  revalidatePath("/hours");
  return { error: null, ok: "Claim removed." };
}

/**
 * Set the mileage rate from a given date.
 *
 * Dated, like a pay rate, so a claim keeps the rate that applied when the
 * driving happened. Admin only, and nothing computes a mileage amount until
 * one exists.
 */
export async function setMileageRate(_prev: HoursState, formData: FormData): Promise<HoursState> {
  const me = await getCurrentStaff();
  if (me?.role !== "Admin") return { error: "Only Admin sets the mileage rate.", ok: null };

  const from = String(formData.get("effective_from") ?? "").trim();
  const cents = Number(String(formData.get("cents_per_mile") ?? "").trim());

  if (!from) return { error: "From when?", ok: null };
  if (!(cents > 0)) return { error: "What is the rate, in cents per mile?", ok: null };
  if (cents > 200) {
    return { error: "That is over $2 a mile — it is entered in cents, not dollars.", ok: null };
  }

  const supabase = await createClient();
  const { error } = await supabase
    .from("mileage_rates")
    .upsert(
      {
        effective_from: from,
        cents_per_mile: cents,
        note: String(formData.get("note") ?? "").trim(),
        set_by: me.id,
      },
      { onConflict: "effective_from" },
    );

  if (error) return { error: friendly(error), ok: null };

  revalidatePath("/hours");
  revalidatePath("/admin/settings");
  return { error: null, ok: `${cents}c a mile from ${from}.` };
}
