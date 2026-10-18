"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";
import { sendEmail, emailConfigured } from "@/lib/email";
import { ORG } from "@/lib/roles";
import { STATUSES, splitPastedReport, type DayStatus } from "./day";

export type DayState = { error: string | null; ok: string | null };

/** Where the finished days have always gone, and still go. */
const DAYS_TO = "service@zionvocrehab.com";

/** The day being worked on: today's, opened if it is not there yet. */
async function myDay(day?: string) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("open_staff_day", day ? { p_day: day } : {});
  if (error || !data) return { id: null as string | null, error: error?.message ?? "That day could not be opened." };
  return { id: data as string, error: null as string | null };
}

/** Adds one task line to the day. */
export async function addLine(_prev: DayState, formData: FormData): Promise<DayState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const description = String(formData.get("description") ?? "").trim();
  if (!description) return { error: "What was the task?", ok: null };

  const status = String(formData.get("status") ?? "Complete");
  if (!STATUSES.includes(status as DayStatus)) return { error: "Unknown status.", ok: null };

  const day = String(formData.get("day") ?? "") || undefined;
  const { id, error } = await myDay(day);
  if (!id) return { error, ok: null };

  const supabase = await createClient();
  const { data: last } = await supabase
    .from("staff_day_lines")
    .select("sort_order")
    .eq("day_id", id)
    .order("sort_order", { ascending: false })
    .limit(1)
    .maybeSingle();

  const { error: insertError } = await supabase.from("staff_day_lines").insert({
    day_id: id,
    status,
    description,
    notes: String(formData.get("notes") ?? "").trim(),
    client_id: String(formData.get("client_id") ?? "") || null,
    sort_order: (last?.sort_order ?? 0) + 1,
  });
  if (insertError) return { error: insertError.message, ok: null };

  revalidatePath("/end-of-day");
  return { error: null, ok: "Added." };
}

/** Takes a pasted report and makes a line of each hyphenated line in it. */
export async function pasteReport(_prev: DayState, formData: FormData): Promise<DayState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const lines = splitPastedReport(String(formData.get("pasted") ?? ""));
  if (lines.length === 0) {
    return {
      error: "Nothing there to read. Each task goes on its own line, starting with a hyphen.",
      ok: null,
    };
  }

  const day = String(formData.get("day") ?? "") || undefined;
  const { id, error } = await myDay(day);
  if (!id) return { error, ok: null };

  const supabase = await createClient();
  const { data: last } = await supabase
    .from("staff_day_lines")
    .select("sort_order")
    .eq("day_id", id)
    .order("sort_order", { ascending: false })
    .limit(1)
    .maybeSingle();
  const from = (last?.sort_order ?? 0) + 1;

  const { error: insertError } = await supabase.from("staff_day_lines").insert(
    lines.map((l, i) => ({
      day_id: id,
      status: l.status,
      description: l.description,
      sort_order: from + i,
    })),
  );
  if (insertError) return { error: insertError.message, ok: null };

  revalidatePath("/end-of-day");
  return { error: null, ok: `${lines.length} line${lines.length === 1 ? "" : "s"} read.` };
}

/** Changes one line — its status, its note, or the client it is about. */
export async function editLine(_prev: DayState, formData: FormData): Promise<DayState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const lineId = String(formData.get("line_id") ?? "");
  if (!lineId) return { error: "Which line?", ok: null };

  const status = String(formData.get("status") ?? "");
  if (!STATUSES.includes(status as DayStatus)) return { error: "Unknown status.", ok: null };

  const supabase = await createClient();
  const { data, error } = await supabase
    .from("staff_day_lines")
    .update({
      status,
      description: String(formData.get("description") ?? "").trim(),
      notes: String(formData.get("notes") ?? "").trim(),
      client_id: String(formData.get("client_id") ?? "") || null,
    })
    .eq("id", lineId)
    .select("id")
    .maybeSingle();

  if (error) return { error: error.message, ok: null };
  if (!data) return { error: "That line is not yours to change, or the day is submitted.", ok: null };

  revalidatePath("/end-of-day");
  return { error: null, ok: "Saved." };
}

export async function removeLine(_prev: DayState, formData: FormData): Promise<DayState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const supabase = await createClient();
  const { error } = await supabase
    .from("staff_day_lines")
    .delete()
    .eq("id", String(formData.get("line_id") ?? ""));
  if (error) return { error: error.message, ok: null };

  revalidatePath("/end-of-day");
  return { error: null, ok: "Removed." };
}

/** The bottlenecks half of the form. */
export async function saveBottlenecks(_prev: DayState, formData: FormData): Promise<DayState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const day = String(formData.get("day") ?? "") || undefined;
  const { id, error } = await myDay(day);
  if (!id) return { error, ok: null };

  const supabase = await createClient();
  const { error: saveError } = await supabase
    .from("staff_days")
    .update({
      bottlenecks: String(formData.get("bottlenecks") ?? "").trim(),
      actions_taken: String(formData.get("actions_taken") ?? "").trim(),
    })
    .eq("id", id);
  if (saveError) return { error: saveError.message, ok: null };

  revalidatePath("/end-of-day");
  return { error: null, ok: "Saved." };
}

/**
 * Submit the day.
 *
 * The database locks it, writes every client line to that client's record and
 * tells Admin and the manager. What is left for here is the one email, which
 * goes to service@ because that is where the practice's finished days have
 * always gone.
 *
 * The email is sent after the day is safely submitted and its failure is
 * reported rather than thrown: a day that is recorded but not emailed is a
 * nuisance, and a day that is emailed but not recorded is a lie.
 */
export async function submitDay(_prev: DayState, formData: FormData): Promise<DayState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const day = String(formData.get("day") ?? "") || undefined;
  const { id, error } = await myDay(day);
  if (!id) return { error, ok: null };

  const supabase = await createClient();
  const { data: summary, error: submitError } = await supabase.rpc("submit_staff_day", {
    p_day_id: id,
  });
  if (submitError) return { error: submitError.message, ok: null };

  revalidatePath("/end-of-day");
  revalidatePath("/my-day");

  if (!emailConfigured()) {
    return { error: null, ok: "Day submitted. Email is not set up, so nothing was sent." };
  }

  const sent = await sendEmail({
    to: DAYS_TO,
    subject: `End of day — ${me.name} — ${day ?? "today"}`,
    text: `${summary ?? ""}\n\n${ORG.name}\nSent from the CRM when the day was submitted.`,
  });

  if (!sent.ok) {
    return {
      error: null,
      ok: `Day submitted. The email to ${DAYS_TO} did not go: ${sent.error}`,
    };
  }

  return { error: null, ok: `Day submitted, and sent to ${DAYS_TO}.` };
}

/** Reopen it — the same day only, and the reason is kept. */
export async function reopenDay(_prev: DayState, formData: FormData): Promise<DayState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const reason = String(formData.get("reason") ?? "").trim();
  if (!reason) return { error: "Say why it is being reopened.", ok: null };

  const supabase = await createClient();
  const { error } = await supabase.rpc("reopen_staff_day", {
    p_day_id: String(formData.get("day_id") ?? ""),
    p_reason: reason,
  });
  if (error) return { error: error.message, ok: null };

  revalidatePath("/end-of-day");
  return { error: null, ok: "Reopened. It can be submitted again when it is right." };
}
