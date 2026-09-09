"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";
import { JOB_STATUSES } from "@/lib/constants";

export type ReminderState = { error: string | null; ok: string | null };

/**
 * "How did it go?"
 *
 * Completing an interview or follow-up reminder is the moment somebody knows
 * something new about the job, and the moment they are least likely to go and
 * find the job to record it. So the answer moves the job along from here, and
 * the note trigger writes it up exactly as it would from anywhere else.
 *
 * The status is optional. Sometimes the honest answer is "still waiting", and
 * a prompt that insists on a change would be answered with a wrong one.
 */
export async function answerReminder(
  _prev: ReminderState,
  formData: FormData,
): Promise<ReminderState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const status = String(formData.get("status") ?? "").trim();
  if (status && !JOB_STATUSES.includes(status as never)) {
    return { error: "Unknown status.", ok: null };
  }

  const supabase = await createClient();
  const { error } = await supabase.rpc("answer_reminder", {
    p_task_id: String(formData.get("task_id") ?? ""),
    p_status: status || null,
    p_outcome: String(formData.get("outcome") ?? "").trim(),
  });

  if (error) return { error: error.message, ok: null };

  revalidatePath("/tasks");
  revalidatePath("/dashboard");
  const clientId = String(formData.get("client_id") ?? "");
  if (clientId) revalidatePath(`/clients/${clientId}`);

  return {
    error: null,
    ok: status
      ? `Done, and the job moved to ${status}.`
      : "Done, and what you wrote is on the record.",
  };
}
