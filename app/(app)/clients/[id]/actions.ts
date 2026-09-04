"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";
import { STAGES, CAN_EDIT_CLIENTS as CAN_EDIT } from "@/lib/constants";
import type { Update } from "@/lib/database.types";

export type DetailState = { error: string | null; ok: string | null };

/** Move a client along the pipeline. The history row is written by a trigger. */
export async function setStage(_prev: DetailState, formData: FormData): Promise<DetailState> {
  const me = await getCurrentStaff();
  if (!me || !CAN_EDIT.includes(me.role)) {
    return { error: "Your role cannot change the pipeline stage.", ok: null };
  }

  const id = String(formData.get("id") ?? "");
  const stage = String(formData.get("stage") ?? "");
  if (!(STAGES as readonly string[]).includes(stage)) {
    return { error: "Unknown stage.", ok: null };
  }

  const supabase = await createClient();
  const { error } = await supabase.from("clients").update({ stage }).eq("id", id);
  if (error) return { error: error.message, ok: null };

  revalidatePath(`/clients/${id}`);
  revalidatePath("/clients");
  return { error: null, ok: `Moved to ${stage}.` };
}

/** Edit the client's own fields. Date of birth and address are handled apart. */
export async function updateClient(_prev: DetailState, formData: FormData): Promise<DetailState> {
  const me = await getCurrentStaff();
  if (!me || !CAN_EDIT.includes(me.role)) {
    return { error: "Your role cannot edit client details.", ok: null };
  }

  const id = String(formData.get("id") ?? "");
  const str = (k: string) => String(formData.get(k) ?? "").trim();
  const orNull = (v: string) => (v === "" ? null : v);

  const supabase = await createClient();

  const patch: Update<"clients"> = {
    name: str("name"),
    agency_id: str("agency_id"),
    phone: str("phone"),
    email: str("email"),
    counselor_id: orNull(str("counselor_id")),
    counselor_contact: str("counselor_contact"),
    referring_office: str("referring_office"),
    caseload: str("caseload"),
    unit: str("unit"),
    schedule: str("schedule"),
    target_jobs: str("target_jobs"),
    assigned_staff_id: orNull(str("assigned_staff_id")),
    wsa_tier: str("wsa_tier") ? Number(str("wsa_tier")) : null,
    wsa_completed: orNull(str("wsa_completed")),
  };

  // Closing or holding a case is the owner's call — the prototype disables the
  // status control for everyone but Admin.
  if (me.role === "Admin" && str("status")) {
    patch.status = str("status");
  }

  const { error } = await supabase.from("clients").update(patch).eq("id", id);

  if (error) return { error: error.message, ok: null };

  revalidatePath(`/clients/${id}`);
  revalidatePath("/clients");
  return { error: null, ok: "Saved." };
}

/**
 * Save the restricted fields. Whether this is allowed is decided by the
 * database — can_see_restricted() on client_private — not by this code.
 */
export async function updateRestricted(
  _prev: DetailState,
  formData: FormData,
): Promise<DetailState> {
  const me = await getCurrentStaff();
  if (!me || !CAN_EDIT.includes(me.role)) {
    return { error: "Your role cannot edit client details.", ok: null };
  }

  const id = String(formData.get("id") ?? "");
  const dob = String(formData.get("dob") ?? "").trim() || null;
  const address = String(formData.get("address") ?? "").trim();

  const supabase = await createClient();
  const { error } = await supabase
    .from("client_private")
    .upsert({ client_id: id, dob, address }, { onConflict: "client_id" });

  if (error) {
    return {
      error:
        "Those fields are restricted to Admin, Intake & Reports, or this client's assigned staff member.",
      ok: null,
    };
  }

  revalidatePath(`/clients/${id}`);
  return { error: null, ok: "Saved." };
}

/**
 * Add a note.
 *
 * Notes carry per-role visibility and are attributed and timestamped. Admin is
 * always included — the owner can see everything — and the author is taken
 * from the session, never from the form.
 */
export async function addNote(_prev: DetailState, formData: FormData): Promise<DetailState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const clientId = String(formData.get("id") ?? "");
  const text = String(formData.get("text") ?? "").trim();
  if (!text) return { error: "Write something first.", ok: null };

  const roles = new Set<string>(["Admin"]);
  for (const r of formData.getAll("visible_roles")) roles.add(String(r));

  const supabase = await createClient();
  const { error } = await supabase.from("notes").insert({
    client_id: clientId,
    staff_id: me.id,
    staff_name: me.name,
    text,
    type: String(formData.get("type") ?? "General"),
    visible_roles: [...roles],
  });

  if (error) return { error: error.message, ok: null };

  revalidatePath(`/clients/${clientId}`);
  return { error: null, ok: "Note added." };
}

/** Raise a task against this client. */
export async function addTask(_prev: DetailState, formData: FormData): Promise<DetailState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const clientId = String(formData.get("id") ?? "");
  const title = String(formData.get("title") ?? "").trim();
  if (!title) return { error: "A task needs a title.", ok: null };

  const due = String(formData.get("due") ?? "").trim() || null;
  const assigned = String(formData.get("assigned_staff_id") ?? "").trim() || me.id;

  const supabase = await createClient();
  const { error } = await supabase.from("tasks").insert({
    client_id: clientId,
    assigned_staff_id: assigned,
    title,
    due,
    status: "Open",
    created_by: me.id,
  });

  if (error) return { error: error.message, ok: null };

  revalidatePath(`/clients/${clientId}`);
  revalidatePath("/tasks");
  return { error: null, ok: "Task added." };
}

/**
 * Open or close a task.
 *
 * The database decides whether this is allowed: only the assignee, the person
 * who raised it, or Admin can change a task.
 */
export async function toggleTask(_prev: DetailState, formData: FormData): Promise<DetailState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const taskId = String(formData.get("task_id") ?? "");
  const clientId = String(formData.get("id") ?? "");
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

  revalidatePath(`/clients/${clientId}`);
  revalidatePath("/tasks");
  return { error: null, ok: null };
}
