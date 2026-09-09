"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";
import { CAN_EDIT_CLIENTS, JOB_STATUSES, today } from "@/lib/constants";

export type JobState = { error: string | null; ok: string | null };

async function editor() {
  const me = await getCurrentStaff();
  if (!me) return { me: null, error: "You are not signed in." };
  if (!CAN_EDIT_CLIENTS.includes(me.role)) {
    return { me: null, error: "Your role does not change client records." };
  }
  return { me, error: null };
}

const isDate = (v: string) => /^\d{4}-\d{2}-\d{2}$/.test(v);

/**
 * Adds a job this client has tried.
 *
 * A job here is a lead plus this client against it, which is what the leads
 * board already stores — so a job added from the client's profile shows up on
 * the board, and one added on the board shows up here. There is one pipeline,
 * seen from two ends.
 *
 * The employer comes from the directory or is created alongside. Making
 * somebody leave the client, add an employer, and come back is how a job ends
 * up recorded as "Some Diner (?)" in a note instead.
 */
export async function addClientJob(_prev: JobState, formData: FormData): Promise<JobState> {
  const { me, error: denied } = await editor();
  if (!me) return { error: denied, ok: null };

  const clientId = String(formData.get("client_id") ?? "");
  const title = String(formData.get("title") ?? "").trim();
  const status = String(formData.get("status") ?? "Saved");
  const employerId = String(formData.get("employer_id") ?? "");
  const newEmployer = String(formData.get("new_employer") ?? "").trim();

  if (!clientId) return { error: "No client given.", ok: null };
  if (!title) return { error: "What is the position?", ok: null };
  if (!JOB_STATUSES.includes(status as never)) return { error: "Unknown status.", ok: null };
  if (!employerId && !newEmployer) {
    return { error: "Choose an employer, or type a new one.", ok: null };
  }

  const supabase = await createClient();

  // ── the employer ───────────────────────────────────────────
  let employer = employerId;
  if (!employer) {
    // Matched on name first. Typing an employer that already exists should
    // join it, not make a second one — a directory with "Smith's Diner" twice
    // is worse than no directory.
    const { data: existing } = await supabase
      .from("employers")
      .select("id")
      .ilike("name", newEmployer)
      .maybeSingle();

    if (existing) {
      employer = existing.id;
    } else {
      const { data: created, error } = await supabase
        .from("employers")
        .insert({
          name: newEmployer,
          contact_name: String(formData.get("contact_name") ?? "").trim(),
          contact_phone: String(formData.get("contact_phone") ?? "").trim(),
          contact_email: String(formData.get("contact_email") ?? "").trim(),
          created_by: me.id,
        })
        .select("id")
        .single();

      if (error) return { error: error.message, ok: null };
      employer = created.id;
    }
  }

  // ── the job ────────────────────────────────────────────────
  const { data: lead, error: leadError } = await supabase
    .from("job_leads")
    .insert({
      employer_id: employer,
      title,
      wage_range: String(formData.get("wage_range") ?? "").trim(),
      location: String(formData.get("location") ?? "").trim(),
      source: "Client profile",
      owner_staff_id: me.id,
      created_by: me.id,
    })
    .select("id")
    .single();

  if (leadError) return { error: leadError.message, ok: null };

  // ── this client against it ─────────────────────────────────
  const appliedOn = String(formData.get("applied_on") ?? "");
  const interviewOn = String(formData.get("interview_on") ?? "");
  const followUpOn = String(formData.get("follow_up_on") ?? "");

  const { error: matchError } = await supabase.from("lead_matches").insert({
    lead_id: lead.id,
    client_id: clientId,
    status,
    applied_on: isDate(appliedOn) ? appliedOn : status === "Applied" ? today() : null,
    interview_on: isDate(interviewOn) ? interviewOn : null,
    follow_up_on: isDate(followUpOn) ? followUpOn : null,
    notes: String(formData.get("notes") ?? "").trim(),
    created_by: me.id,
  });

  if (matchError) return { error: matchError.message, ok: null };

  revalidatePath(`/clients/${clientId}`);
  revalidatePath("/leads");
  return { error: null, ok: `${title} added, and noted on the record.` };
}

/**
 * Moves a job along, or changes its dates.
 *
 * The note is written by the trigger on the row, not here, so it happens
 * whether the status was changed from this panel, from the leads board, or by
 * a correction.
 */
export async function updateClientJob(_prev: JobState, formData: FormData): Promise<JobState> {
  const { me, error: denied } = await editor();
  if (!me) return { error: denied, ok: null };

  const matchId = String(formData.get("match_id") ?? "");
  const clientId = String(formData.get("client_id") ?? "");
  const status = String(formData.get("status") ?? "");

  if (!JOB_STATUSES.includes(status as never)) return { error: "Unknown status.", ok: null };

  const dateOrNull = (k: string) => {
    const v = String(formData.get(k) ?? "");
    return isDate(v) ? v : null;
  };

  const patch: Record<string, unknown> = {
    status,
    interview_on: dateOrNull("interview_on"),
    follow_up_on: dateOrNull("follow_up_on"),
    applied_on: dateOrNull("applied_on"),
    outcome: String(formData.get("outcome") ?? "").trim(),
    notes: String(formData.get("notes") ?? "").trim(),
  };

  // A date the status implies but nobody typed. Filled in rather than left
  // blank, because "Applied" with no date is a job nobody can chase.
  if (status === "Applied" && !patch.applied_on) patch.applied_on = today();
  if (status === "Interview" && !patch.interview_on) patch.interview_on = today();
  if (status === "Hired" || status === "Not selected") patch.decided_on = today();

  const supabase = await createClient();
  const { error } = await supabase
    .from("lead_matches")
    .update(patch as never)
    .eq("id", matchId);

  if (error) return { error: error.message, ok: null };

  revalidatePath(`/clients/${clientId}`);
  revalidatePath("/leads");
  return {
    error: null,
    ok:
      status === "Hired"
        ? "Saved. Create the placement when you are ready — it is a separate step on purpose."
        : "Saved, and noted on the record.",
  };
}

/** Removes a job that should not have been added. The note it wrote stays. */
export async function removeClientJob(_prev: JobState, formData: FormData): Promise<JobState> {
  const { me, error: denied } = await editor();
  if (!me) return { error: denied, ok: null };

  const clientId = String(formData.get("client_id") ?? "");
  const supabase = await createClient();

  const { error } = await supabase
    .from("lead_matches")
    .delete()
    .eq("id", String(formData.get("match_id") ?? ""));

  if (error) return { error: error.message, ok: null };

  revalidatePath(`/clients/${clientId}`);
  revalidatePath("/leads");
  return {
    error: null,
    ok: "Removed. The notes it wrote stay on the record — they are what happened.",
  };
}
