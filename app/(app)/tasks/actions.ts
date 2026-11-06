"use server";

import { today } from "@/lib/constants";
import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";

export type TaskState = { error: string | null; ok: string | null };

/**
 * Every screen a task is listed on (owner, 6 Nov 2026).
 *
 * The two actions are on every task row now, so a task marked complete on
 * Home has to disappear from the client's record and from My day as well -
 * and whoever presses it has no idea which of the five screens cached what.
 * Listed once here rather than three paths at each call site, which is how
 * `/my-day` came to be revalidated by removing a task and not by finishing
 * one.
 *
 * The client's record is a dynamic route, so it is revalidated by its shape:
 * the task knows its client, but the screens that list tasks across clients
 * do not, and a path per client would mean reading the task back to find out.
 */
function revalidateTaskScreens() {
  revalidatePath("/tasks");
  revalidatePath("/dashboard");
  revalidatePath("/dashboard/needs");
  revalidatePath("/my-day");
  revalidatePath("/clients/[id]", "page");
}

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
/**
 * A step of a task, a word about one, and how often it comes round
 * (Design language, §2/§3).
 *
 * A step is a task, so it goes through the same rules and shows the same
 * history; what makes it a step is its parent, and the database refuses a
 * step of a step because a tree nobody can read is worse than a flat list.
 */
export async function addStep(_prev: TaskState, formData: FormData): Promise<TaskState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const parent = String(formData.get("parent_id") ?? "");
  const title = String(formData.get("title") ?? "").trim();
  if (!title) return { error: "Say what the step is.", ok: null };

  const supabase = await createClient();
  const { data: owner } = await supabase
    .from("tasks")
    .select("client_id, assigned_staff_id, due")
    .eq("id", parent)
    .maybeSingle();
  if (!owner) return { error: "That task is not yours to add to.", ok: null };

  const { error } = await supabase.from("tasks").insert({
    parent_id: parent,
    title,
    client_id: owner.client_id,
    assigned_staff_id: owner.assigned_staff_id,
    due: owner.due,
    status: "Open",
    created_by: me.id,
  });
  if (error) return { error: error.message, ok: null };

  revalidatePath("/tasks");
  revalidatePath("/dashboard");
  return { error: null, ok: null };
}

export async function commentOnTask(_prev: TaskState, formData: FormData): Promise<TaskState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const taskId = String(formData.get("task_id") ?? "");
  const said = String(formData.get("said") ?? "").trim();
  if (!said) return { error: "Nothing to add.", ok: null };

  const supabase = await createClient();
  const { error } = await supabase
    .from("task_comments")
    .insert({ task_id: taskId, staff_id: me.id, staff_name: me.name, said });
  if (error) return { error: error.message, ok: null };

  revalidatePath("/tasks");
  return { error: null, ok: null };
}

/** How often it comes round. Finishing one opens the next (0138). */
export async function setTaskRepeat(_prev: TaskState, formData: FormData): Promise<TaskState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const taskId = String(formData.get("task_id") ?? "");
  const every = String(formData.get("repeat_every") ?? "").trim();

  const supabase = await createClient();
  const { data, error } = await supabase
    .from("tasks")
    .update({ repeat_every: every || null })
    .eq("id", taskId)
    .select("id")
    .maybeSingle();

  if (error) return { error: error.message, ok: null };
  if (!data) return { error: "Only the person a task is assigned to, whoever raised it, or Admin can change it.", ok: null };

  revalidatePath("/tasks");
  return { error: null, ok: null };
}

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

  revalidateTaskScreens();
  return { error: null, ok: null };
}

/**
 * Take a task off the list, for everybody (owner, 5 Nov 2026).
 *
 * Not Done. A task somebody finished and a task that should never have been
 * raised are different facts, and recording both as Done loses the second -
 * along with who decided it, which is the part anybody would ask about later.
 *
 * Who and when are written by a trigger (0297), not here and not by the
 * browser. A reason is optional, as asked, and kept with it; a blank one is
 * stored as nothing rather than as an empty string, so "no reason given" and
 * "the reason was an empty box" are the same thing on every screen.
 *
 * Who may: the same rule as closing one, which the database already holds -
 * the assignee, whoever raised it, or Admin. Nothing new is granted here.
 */
export async function removeTask(_prev: TaskState, formData: FormData): Promise<TaskState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const taskId = String(formData.get("task_id") ?? "");
  const reason = String(formData.get("reason") ?? "").trim();

  const supabase = await createClient();
  const { data, error } = await supabase
    .from("tasks")
    .update({ status: "Removed", removed_reason: reason || null })
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

  revalidateTaskScreens();
  return { error: null, ok: null };
}

/**
 * And put one back, which is the same rule in reverse.
 *
 * The record of who took it off stays: the status says whether it is off the
 * list now, removed_by says who took it off last. A removal undone and a
 * removal that never happened should not read the same.
 */
export async function restoreTask(_prev: TaskState, formData: FormData): Promise<TaskState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const taskId = String(formData.get("task_id") ?? "");
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("tasks")
    .update({ status: "Open" })
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

  revalidateTaskScreens();
  return { error: null, ok: null };
}
