"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";

export type DetailState = { error: string | null; ok: string | null };

const CAN_EDIT = ["Admin", "Job Search", "Reports"];

const STAGES = [
  "Referral",
  "Intake",
  "Assessment",
  "Job Development",
  "Placement",
  "Job Coaching",
  "Follow-Along",
  "Closed",
];

/** Move a client along the pipeline. The history row is written by a trigger. */
export async function setStage(_prev: DetailState, formData: FormData): Promise<DetailState> {
  const me = await getCurrentStaff();
  if (!me || !CAN_EDIT.includes(me.role)) {
    return { error: "Your role cannot change the pipeline stage.", ok: null };
  }

  const id = String(formData.get("id") ?? "");
  const stage = String(formData.get("stage") ?? "");
  if (!STAGES.includes(stage)) return { error: "Unknown stage.", ok: null };

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
  const { error } = await supabase
    .from("clients")
    .update({
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
      status: str("status") || "Active",
      wsa_tier: str("wsa_tier") ? Number(str("wsa_tier")) : null,
      wsa_completed: orNull(str("wsa_completed")),
    })
    .eq("id", id);

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
