"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";
import { today } from "@/lib/constants";

export type LeadState = { error: string | null; ok: string | null };

const CAN_EDIT = ["Admin", "Job Search"];

async function editor() {
  const me = await getCurrentStaff();
  if (!me) return { me: null, error: "You are not signed in." };
  if (!CAN_EDIT.includes(me.role)) {
    return { me: null, error: "Job leads are worked by Job Search and Admin." };
  }
  return { me, error: null };
}

export async function createEmployer(_prev: LeadState, formData: FormData): Promise<LeadState> {
  const { me, error: denied } = await editor();
  if (!me) return { error: denied, ok: null };

  const name = String(formData.get("name") ?? "").trim();
  if (!name) return { error: "An employer needs a name.", ok: null };

  const str = (k: string) => String(formData.get(k) ?? "").trim();

  const supabase = await createClient();
  const { error } = await supabase.from("employers").insert({
    name,
    industry: str("industry"),
    address: str("address"),
    contact_name: str("contact_name"),
    contact_phone: str("contact_phone"),
    contact_email: str("contact_email"),
    hiring_pattern: str("hiring_pattern"),
    notes: str("notes"),
    relationship_status: str("relationship_status") || "Prospect",
    created_by: me.id,
  });

  if (error) {
    return {
      error: error.code === "23505" ? `${name} is already in the directory.` : error.message,
      ok: null,
    };
  }

  revalidatePath("/leads");
  return { error: null, ok: `${name} added.` };
}

export async function setEmployerStatus(_prev: LeadState, formData: FormData): Promise<LeadState> {
  const { me, error: denied } = await editor();
  if (!me) return { error: denied, ok: null };

  const supabase = await createClient();
  const { error } = await supabase
    .from("employers")
    .update({ relationship_status: String(formData.get("relationship_status") ?? "Prospect") })
    .eq("id", String(formData.get("employer_id") ?? ""));

  if (error) return { error: error.message, ok: null };
  revalidatePath("/leads");
  return { error: null, ok: "Saved." };
}

export async function createLead(_prev: LeadState, formData: FormData): Promise<LeadState> {
  const { me, error: denied } = await editor();
  if (!me) return { error: denied, ok: null };

  const employerId = String(formData.get("employer_id") ?? "").trim();
  const title = String(formData.get("title") ?? "").trim();
  if (!employerId) return { error: "Choose the employer.", ok: null };
  if (!title) return { error: "What is the job title?", ok: null };

  const str = (k: string) => String(formData.get(k) ?? "").trim();

  const supabase = await createClient();
  const { error } = await supabase.from("job_leads").insert({
    employer_id: employerId,
    title,
    wage_range: str("wage_range"),
    hours_week: str("hours_week"),
    shift: str("shift"),
    requirements: str("requirements"),
    source: str("source"),
    posted_date: str("posted_date") || null,
    status: "Open",
    owner_staff_id: str("owner_staff_id") || me.id,
    created_by: me.id,
  });

  if (error) return { error: error.message, ok: null };

  revalidatePath("/leads");
  return { error: null, ok: `${title} added.` };
}

export async function setLeadStatus(_prev: LeadState, formData: FormData): Promise<LeadState> {
  const { me, error: denied } = await editor();
  if (!me) return { error: denied, ok: null };

  const id = String(formData.get("lead_id") ?? "");
  const supabase = await createClient();
  const { error } = await supabase
    .from("job_leads")
    .update({ status: String(formData.get("status") ?? "Open") })
    .eq("id", id);

  if (error) return { error: error.message, ok: null };
  revalidatePath("/leads");
  revalidatePath(`/leads/${id}`);
  return { error: null, ok: "Saved." };
}

/**
 * Put a client forward for an opening.
 *
 * The typed note on the client is written by a database trigger, not here, so
 * it happens however the row is created — and so the same work never has to be
 * typed twice into the client record.
 */
export async function createMatch(_prev: LeadState, formData: FormData): Promise<LeadState> {
  const { me, error: denied } = await editor();
  if (!me) return { error: denied, ok: null };

  const leadId = String(formData.get("lead_id") ?? "");
  const clientId = String(formData.get("client_id") ?? "").trim();
  if (!clientId) return { error: "Choose a client.", ok: null };

  const status = String(formData.get("status") ?? "Saved");
  const supabase = await createClient();
  const { error } = await supabase.from("lead_matches").insert({
    lead_id: leadId,
    client_id: clientId,
    status,
    notes: String(formData.get("notes") ?? "").trim(),
    applied_on: status === "Applied" ? today() : null,
    created_by: me.id,
  });

  if (error) {
    return {
      error:
        error.code === "23505"
          ? "That client is already on this opening."
          : error.message,
      ok: null,
    };
  }

  revalidatePath(`/leads/${leadId}`);
  revalidatePath("/leads");
  return { error: null, ok: "Added, and noted on the client record." };
}

export async function setMatchStatus(_prev: LeadState, formData: FormData): Promise<LeadState> {
  const { me, error: denied } = await editor();
  if (!me) return { error: denied, ok: null };

  const matchId = String(formData.get("match_id") ?? "");
  const leadId = String(formData.get("lead_id") ?? "");
  const status = String(formData.get("status") ?? "");

  const patch: Record<string, unknown> = { status };
  if (status === "Applied") patch.applied_on = today();
  if (status === "Interview") patch.interview_on = today();
  if (status === "Follow-up") patch.follow_up_on = today();
  // "Declined" was renamed to "Not selected" in 0034. Left as it was, a
  // rejection would have stopped recording the day it happened.
  if (status === "Hired" || status === "Not selected") patch.decided_on = today();

  const supabase = await createClient();
  const { error } = await supabase
    .from("lead_matches")
    .update(patch as never)
    .eq("id", matchId);

  if (error) return { error: error.message, ok: null };

  revalidatePath(`/leads/${leadId}`);
  revalidatePath("/leads");
  return {
    error: null,
    ok:
      status === "Hired"
        ? "Marked as hired and noted on the client. Create the placement when you are ready."
        : "Saved, and noted on the client record.",
  };
}

/**
 * Create the Placement record for a hired match.
 *
 * Deliberately a separate, explicit step rather than something that happens
 * when a card is dragged to Hired. A placement carries the 30/60/90 retention
 * checks USOR measures and the placement fee — it should exist because someone
 * decided it does.
 */
export async function createPlacementFromMatch(
  _prev: LeadState,
  formData: FormData,
): Promise<LeadState> {
  const { me, error: denied } = await editor();
  if (!me) return { error: denied, ok: null };

  const matchId = String(formData.get("match_id") ?? "");
  const leadId = String(formData.get("lead_id") ?? "");
  const startDate = String(formData.get("start_date") ?? "").trim() || null;

  const supabase = await createClient();

  const { data: match } = await supabase
    .from("lead_matches")
    .select("id, client_id, status, placement_id, lead_id")
    .eq("id", matchId)
    .maybeSingle();

  if (!match) return { error: "That match no longer exists.", ok: null };
  if (match.status !== "Hired") {
    return { error: "Mark the match as Hired first.", ok: null };
  }
  if (match.placement_id) {
    return { error: "A placement has already been created for this match.", ok: null };
  }

  const { data: lead } = await supabase
    .from("job_leads")
    .select("title, employer_id")
    .eq("id", match.lead_id)
    .maybeSingle();

  const { data: employer } = lead
    ? await supabase.from("employers").select("name").eq("id", lead.employer_id).maybeSingle()
    : { data: null };

  const { data: placement, error } = await supabase
    .from("placements")
    .insert({
      client_id: match.client_id,
      employer: employer?.name ?? "",
      title: lead?.title ?? "",
      start_date: startDate,
    })
    .select("id")
    .single();

  if (error) return { error: error.message, ok: null };

  await supabase.from("lead_matches").update({ placement_id: placement.id }).eq("id", matchId);

  revalidatePath(`/leads/${leadId}`);
  revalidatePath(`/clients/${match.client_id}`);
  redirect(`/clients/${match.client_id}?tab=placements`);
}
