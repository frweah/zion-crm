"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";

export type ClientFormState = { error: string | null; ok: string | null };

const CAN_EDIT = ["Admin", "Job Search", "Reports"];

/**
 * Add a client.
 *
 * Mirrors the prototype's addClient: the record starts at Referral, and an
 * intake task is raised for Job Search automatically. The stage history row is
 * written by a database trigger, so it happens however the client was created.
 */
export async function addClient(
  _prev: ClientFormState,
  formData: FormData,
): Promise<ClientFormState> {
  const me = await getCurrentStaff();
  if (!me || !CAN_EDIT.includes(me.role)) {
    return { error: "Your role cannot add clients.", ok: null };
  }

  const name = String(formData.get("name") ?? "").trim();
  if (!name) return { error: "A full name is required.", ok: null };

  const str = (k: string) => String(formData.get(k) ?? "").trim();
  const orNull = (v: string) => (v === "" ? null : v);

  const supabase = await createClient();

  const { data: client, error } = await supabase
    .from("clients")
    .insert({
      name,
      agency_id: str("agency_id"),
      funding_source: str("funding_source") || "Utah VR",
      counselor_id: orNull(str("counselor_id")),
      counselor_contact: str("counselor_contact"),
      caseload: str("caseload"),
      unit: str("unit"),
      referring_office: str("referring_office"),
      assigned_staff_id: orNull(str("assigned_staff_id")),
      stage: "Referral",
      status: "Active",
    })
    .select("id, name, assigned_staff_id")
    .single();

  if (error) return { error: error.message, ok: null };

  // Date of birth is restricted, so it lives in its own table under its own
  // policy. Whoever can add the client may not be allowed to store this.
  const dob = orNull(str("dob"));
  let dobWarning = "";
  if (dob) {
    const { error: dobError } = await supabase
      .from("client_private")
      .insert({ client_id: client.id, dob });
    if (dobError) {
      dobWarning =
        " The date of birth was not saved — that field is limited to Admin, Intake & Reports, or the assigned staff member.";
    }
  }

  // Automation: new client raises the intake task for Job Search.
  const { data: jobSearch } = await supabase
    .from("staff")
    .select("id")
    .eq("role", "Job Search")
    .eq("active", true)
    .limit(1)
    .maybeSingle();

  await supabase.from("tasks").insert({
    client_id: client.id,
    assigned_staff_id: client.assigned_staff_id ?? jobSearch?.id ?? me.id,
    title: `Complete intake for ${client.name}`,
    due: new Date().toISOString().slice(0, 10),
    status: "Open",
    created_by: me.id,
    system_generated: true,
  });

  revalidatePath("/clients");
  revalidatePath("/tasks");

  return {
    error: null,
    ok: `${client.name} added at Referral, and the intake task was raised.${dobWarning}`,
  };
}
