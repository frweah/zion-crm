"use server";

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
  return { error: null, ok: "Task added." };
}

/**
 * Open or close a task. The database decides: only the assignee, whoever
 * raised it, or Admin may change one.
 */
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
      done_at: nowOpen ? new Date().toISOString().slice(0, 10) : null,
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
  return { error: null, ok: null };
}
