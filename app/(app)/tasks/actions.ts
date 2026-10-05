"use server";

import { today } from "@/lib/constants";
import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";

export type TaskState = { error: string | null; ok: string | null };

export async function createTask(_prev: TaskState, formData: FormData): Promise<TaskState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const title = String(formData.get("title") ?? "").trim();
  if (!title) return { error: "A task needs a title.", ok: null };

  // Only Admin may hand work to someone else; everyone else raises their own.
  const requested = String(formData.get("assigned_staff_id") ?? "").trim();
  const assigned = me.role === "Admin" && requested ? requested : me.id;

  const supabase = await createClient();
  const { error } = await supabase.from("tasks").insert({
    title,
    client_id: String(formData.get("client_id") ?? "").trim() || null,
    assigned_staff_id: assigned,
    due: String(formData.get("due") ?? "").trim() || null,
    status: "Open",
    created_by: me.id,
  });

  if (error) return { error: error.message, ok: null };

  revalidatePath("/tasks");
  revalidatePath("/dashboard");
  return { error: null, ok: "Task added." };
}

/**
 * Open or close a task. The database decides: only the assignee, whoever
 * raised it, or Admin may change one.
 */
/**
 * The date a task is due, and who has it, changed where the task is listed
 * (Rei, Oct 2026).
 *
 * Both were a trip to a form: open the task, change the one field, come back.
 * On a list of twenty that is twenty trips, and the usual outcome is that the
 * dates stop being true. The rules decide whether this person may change this
 * task, exactly as they do for the status - nothing here is trusted to the
 * screen, which is why both of these end by asking what the database actually
 * changed.
 */
export async function setTaskDue(_prev: TaskState, formData: FormData): Promise<TaskState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const taskId = String(formData.get("task_id") ?? "");
  const due = String(formData.get("due") ?? "").trim();

  const supabase = await createClient();
  const { data, error } = await supabase
    .from("tasks")
    .update({ due: due || null })
    .eq("id", taskId)
    .select("id")
    .maybeSingle();

  if (error) return { error: error.message, ok: null };
  if (!data) return { error: "Only the person a task is assigned to, whoever raised it, or Admin can change it.", ok: null };

  revalidatePath("/tasks");
  revalidatePath("/dashboard");
  return { error: null, ok: null };
}

export async function setTaskAssignee(_prev: TaskState, formData: FormData): Promise<TaskState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const taskId = String(formData.get("task_id") ?? "");
  const staffId = String(formData.get("staff_id") ?? "").trim();

  const supabase = await createClient();
  const { data, error } = await supabase
    .from("tasks")
    .update({ assigned_staff_id: staffId || null })
    .eq("id", taskId)
    .select("id")
    .maybeSingle();

  if (error) return { error: error.message, ok: null };
  if (!data) return { error: "Only the person a task is assigned to, whoever raised it, or Admin can change it.", ok: null };

  revalidatePath("/tasks");
  revalidatePath("/dashboard");
  return { error: null, ok: null };
}

export async function setTaskStatus(_prev: TaskState, formData: FormData): Promise<TaskState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const taskId = String(formData.get("task_id") ?? "");
  const nowOpen = String(formData.get("open") ?? "") === "true";

  const supabase = await createClient();
  const { data, error } = await supabase
    .from("tasks")
    .update({
      status: nowOpen ? "Done" : "Open",
      done_at: nowOpen ? today() : null,
    })
    .eq("id", taskId)
    .select("id")
    .maybeSingle();

  if (error) return { error: error.message, ok: null };
  if (!data) {
    return {
      error: "Only the person a task is assigned to, whoever raised it, or Admin can change it.",
      ok: null,
    };
  }

  revalidatePath("/tasks");
  revalidatePath("/dashboard");
  return { error: null, ok: null };
}
