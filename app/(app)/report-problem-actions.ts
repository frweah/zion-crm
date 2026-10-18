"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";

export type ProblemState = { error: string | null; ok: string | null };

/** Long enough to say what happened, short enough to stay a report. */
const MOST = 2000;

/**
 * Somebody says the CRM is wrong.
 *
 * The screen comes from the form rather than from the person, because they
 * should not have to describe where they were. Admin is told by the trigger
 * on the table, so the bell and the list of open reports cannot disagree.
 */
export async function reportProblem(
  _prev: ProblemState,
  formData: FormData,
): Promise<ProblemState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const what = String(formData.get("what") ?? "").trim();
  if (!what) return { error: "Say what is wrong.", ok: null };
  if (what.length > MOST) {
    return { error: `That is ${what.length} characters; ${MOST} is the most.`, ok: null };
  }

  const screen = String(formData.get("screen") ?? "").trim().slice(0, 200);

  const supabase = await createClient();
  const { error } = await supabase.from("problem_reports").insert({
    staff_id: me.id,
    screen,
    what,
  });
  if (error) return { error: error.message, ok: null };

  revalidatePath("/admin/system");
  return { error: null, ok: "Sent. The administrator has it, with the screen you were on." };
}

/** Admin closes one, with a note about what was done. */
export async function closeProblem(
  _prev: ProblemState,
  formData: FormData,
): Promise<ProblemState> {
  const me = await getCurrentStaff();
  if (me?.role !== "Admin") return { error: "Only the administrator can do that.", ok: null };

  const id = String(formData.get("report_id") ?? "");
  if (!id) return { error: "Which report?", ok: null };

  const supabase = await createClient();
  const { data, error } = await supabase
    .from("problem_reports")
    .update({
      resolved_at: new Date().toISOString(),
      resolved_by: me.id,
      note: String(formData.get("note") ?? "").trim(),
    })
    .eq("id", id)
    .select("id")
    .maybeSingle();

  if (error) return { error: error.message, ok: null };
  if (!data) return { error: "That report is not there any more.", ok: null };

  revalidatePath("/admin/system");
  return { error: null, ok: "Closed." };
}
