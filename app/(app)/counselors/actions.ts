"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";

export type CounselorState = { error: string | null; ok: string | null };

export async function addCounselor(
  _prev: CounselorState,
  formData: FormData,
): Promise<CounselorState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const name = String(formData.get("name") ?? "").trim();
  if (!name) return { error: "A name is required.", ok: null };

  const str = (k: string) => String(formData.get(k) ?? "").trim();

  const supabase = await createClient();
  const { error } = await supabase.from("counselors").insert({
    name,
    agency: str("agency") || "Utah State Office of Rehabilitation",
    office: str("office") || null,
    phone: str("phone") || null,
    fax: str("fax") || null,
    email: str("email") || null,
    notes: str("notes"),
  });

  if (error) return { error: error.message, ok: null };

  revalidatePath("/counselors");
  return { error: null, ok: `${name} added to the directory.` };
}

/** Log a contact. The logger is taken from the session, never the form. */
export async function logContact(
  _prev: CounselorState,
  formData: FormData,
): Promise<CounselorState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const counselorId = String(formData.get("counselor_id") ?? "").trim();
  const topic = String(formData.get("topic") ?? "").trim();
  if (!counselorId) return { error: "Choose a counselor.", ok: null };
  if (!topic) return { error: "What was the contact about?", ok: null };

  const supabase = await createClient();
  const { error } = await supabase.from("contact_log").insert({
    counselor_id: counselorId,
    client_id: String(formData.get("client_id") ?? "").trim() || null,
    date: String(formData.get("date") ?? "").trim() || undefined,
    method: String(formData.get("method") ?? "Phone call"),
    topic,
    outcome: String(formData.get("outcome") ?? "").trim(),
    follow_up: String(formData.get("follow_up") ?? "").trim() || null,
    staff_id: me.id,
  });

  if (error) return { error: error.message, ok: null };

  revalidatePath("/counselors");
  return { error: null, ok: "Contact logged." };
}

export async function requestHours(
  _prev: CounselorState,
  formData: FormData,
): Promise<CounselorState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const authId = String(formData.get("auth_id") ?? "").trim();
  const hours = String(formData.get("hours") ?? "").trim();
  const reason = String(formData.get("reason") ?? "").trim();

  if (!authId) return { error: "Choose the authorization.", ok: null };
  if (!hours) return { error: "How many hours?", ok: null };
  if (!reason) return { error: "A reason is required — the counselor will ask.", ok: null };

  const supabase = await createClient();
  const { error } = await supabase.from("hours_requests").insert({
    auth_id: authId,
    counselor_id: String(formData.get("counselor_id") ?? "").trim() || null,
    date: String(formData.get("date") ?? "").trim() || undefined,
    hours: Number(hours),
    reason,
    response: "Pending",
    staff_id: me.id,
  });

  if (error) return { error: error.message, ok: null };

  revalidatePath("/counselors");
  return { error: null, ok: "Request recorded." };
}

/**
 * Record what the counselor said.
 *
 * Approved hours deliberately do not touch the authorization: the counselor
 * issues a new or amended authorization, which Billing then enters. That keeps
 * our record matching USOR's rather than drifting from it.
 */
export async function updateHoursRequest(
  _prev: CounselorState,
  formData: FormData,
): Promise<CounselorState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const id = String(formData.get("request_id") ?? "");
  const response = String(formData.get("response") ?? "Pending");
  const approved = String(formData.get("approved") ?? "").trim();
  const approvedDate = String(formData.get("approved_date") ?? "").trim();

  const supabase = await createClient();
  const { data, error } = await supabase
    .from("hours_requests")
    .update({
      response,
      approved: response === "Pending" || response === "Denied" || !approved ? null : Number(approved),
      approved_date: response === "Pending" || response === "Denied" ? null : approvedDate || null,
    })
    .eq("id", id)
    .select("id")
    .maybeSingle();

  if (error) return { error: error.message, ok: null };
  if (!data) {
    return { error: "Only Admin, Billing, or whoever raised the request can update it.", ok: null };
  }

  revalidatePath("/counselors");
  return { error: null, ok: "Response recorded." };
}
