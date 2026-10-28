"use server";

import { revalidatePath } from "next/cache";
import { getCurrentStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { buildPeriodContent, addDays } from "@/lib/report-period";
import { draftWeek } from "@/lib/report-drafts";

export type ReportState = { error: string | null; ok: string | null };

/**
 * A week's report, as the person who owns it changes it.
 *
 * Every write here goes through the signed-in person's client, so the
 * database decides what they may touch: the owner or Admin (0260), and
 * nothing at all once the month has been signed. Where it refuses, the
 * sentence it refuses with is passed straight through — it is written to be
 * read by the person who hit it.
 *
 * Redrafting is the exception and uses the service role on purpose. The
 * scheduler builds these at six in the morning seeing everything, and a
 * redraft that saw less would quietly produce a shorter week for the same
 * seven days. Same builder, same result, whoever asks.
 */

async function week(formData: FormData) {
  const me = await getCurrentStaff();
  if (!me) return { me: null, id: "", clientId: "" };
  return {
    me,
    id: String(formData.get("week_id") ?? ""),
    clientId: String(formData.get("client_id") ?? ""),
  };
}

/** The staff member's own words for the week. The part nobody else can write. */
export async function saveWeekNote(
  _prev: ReportState,
  formData: FormData,
): Promise<ReportState> {
  const { me, id, clientId } = await week(formData);
  if (!me) return { error: "You are not signed in.", ok: null };

  const supabase = await createClient();
  const { error } = await supabase
    .from("client_weekly_reports")
    .update({ note: String(formData.get("note") ?? "").trim() })
    .eq("id", id);
  if (error) return { error: error.message, ok: null };

  revalidatePath(`/clients/${clientId}/reports`);
  return { error: null, ok: "Saved" };
}

/** Say the week is right. The month is made of the weeks somebody has said this about. */
export async function confirmWeek(
  _prev: ReportState,
  formData: FormData,
): Promise<ReportState> {
  const { me, id, clientId } = await week(formData);
  if (!me) return { error: "You are not signed in.", ok: null };

  const supabase = await createClient();
  // The note goes in with the confirmation rather than needing saving first:
  // somebody typing a line and pressing Confirm has said both things.
  const note = String(formData.get("note") ?? "").trim();
  const { error } = await supabase
    .from("client_weekly_reports")
    .update({
      note,
      status: "Confirmed",
      confirmed_at: new Date().toISOString(),
      confirmed_by: me.id,
    })
    .eq("id", id);
  if (error) return { error: error.message, ok: null };

  revalidatePath(`/clients/${clientId}/reports`);
  revalidatePath("/my-day");
  return { error: null, ok: "Confirmed" };
}

export async function reopenWeek(
  _prev: ReportState,
  formData: FormData,
): Promise<ReportState> {
  const { me, id, clientId } = await week(formData);
  if (!me) return { error: "You are not signed in.", ok: null };

  const supabase = await createClient();
  const { error } = await supabase
    .from("client_weekly_reports")
    .update({ status: "Draft", confirmed_at: null, confirmed_by: null })
    .eq("id", id);
  if (error) return { error: error.message, ok: null };

  revalidatePath(`/clients/${clientId}/reports`);
  revalidatePath("/my-day");
  return { error: null, ok: "Reopened" };
}

/** Read the seven days again, leaving whatever somebody wrote where it is. */
export async function redraftWeek(
  _prev: ReportState,
  formData: FormData,
): Promise<ReportState> {
  const { me, id, clientId } = await week(formData);
  if (!me) return { error: "You are not signed in.", ok: null };

  const supabase = await createClient();
  const { data: row } = await supabase
    .from("client_weekly_reports")
    .select("id, week_start, status")
    .eq("id", id)
    .maybeSingle();
  if (!row) return { error: "That week is not yours to change.", ok: null };
  if (row.status !== "Draft") {
    return { error: "Reopen the week before reading the record again.", ok: null };
  }

  const admin = createAdminClient();
  const content = await buildPeriodContent(
    admin,
    clientId,
    row.week_start,
    addDays(row.week_start, 6),
  );
  const { error } = await supabase
    .from("client_weekly_reports")
    .update({ content: content as never, generated_at: new Date().toISOString() })
    .eq("id", id);
  if (error) return { error: error.message, ok: null };

  revalidatePath(`/clients/${clientId}/reports`);
  return { error: null, ok: "Redrafted" };
}

/**
 * A week the scheduler never drafted, drafted now.
 *
 * A client taken on in the middle of the week, or reopened after the Monday,
 * has no row for it. The scheduler will not go back, so the screen offers it,
 * and because drafting is what the scheduler does it is done the way the
 * scheduler does it.
 */
export async function makeWeek(_prev: ReportState, formData: FormData): Promise<ReportState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const clientId = String(formData.get("client_id") ?? "");
  const weekStart = String(formData.get("week_start") ?? "");
  if (!/^\d{4}-\d{2}-\d{2}$/.test(weekStart)) {
    return { error: "That is not a week this practice runs.", ok: null };
  }

  const admin = createAdminClient();
  try {
    const done = await draftWeek(admin, weekStart, [clientId]);
    if (!done.length) {
      return { error: "That client is not Active or On hold, so no report is owed.", ok: null };
    }
  } catch (e) {
    return { error: e instanceof Error ? e.message : "The week could not be drafted.", ok: null };
  }

  revalidatePath(`/clients/${clientId}/reports`);
  return { error: null, ok: "Drafted" };
}
