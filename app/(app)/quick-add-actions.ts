"use server";

import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";
import { today } from "@/lib/constants";
import { kindsForRole, type QuickKind } from "@/lib/quick-add";
import { addNote, addTask, addPlacement } from "./clients/[id]/actions";
import { addClientJob, updateClientJob } from "./clients/[id]/job-actions";
import { logSession } from "./hours/actions";

export type QuickAddState = { error: string | null; ok: string | null };

/**
 * The "+" in the header.
 *
 * Everything here already exists on a screen somewhere; the point is the
 * distance to it. Recording a phone call meant Clients, find the person, open
 * them, Notes, type, save — six steps for one sentence, which is how a note
 * ends up not written at all.
 *
 * Each kind hands straight to the action the full screen uses, rather than
 * writing its own insert. The rules about who may do what, what a task needs,
 * and what happens to an employer that already exists are worth having in one
 * place — a second, quicker way in should not also be a second set of rules.
 */

export async function quickAddOptions(): Promise<{
  clients: { id: string; name: string }[];
  employers: { id: string; name: string }[];
  kinds: QuickKind[];
  today: string;
}> {
  const me = await getCurrentStaff();
  if (!me) return { clients: [], employers: [], kinds: [], today: today() };

  const supabase = await createClient();
  const [{ data: clients }, { data: employers }] = await Promise.all([
    supabase.from("clients").select("id, name").eq("status", "Active").order("name"),
    supabase.from("employers").select("id, name").order("name"),
  ]);

  return {
    clients: clients ?? [],
    employers: employers ?? [],
    kinds: kindsForRole(me.role),
    today: today(),
  };
}

/**
 * The jobs already on a client, for the interview picker.
 *
 * An interview belongs to a job. Offering a free-text employer here would
 * make a second, parallel record of the same application — so if there is no
 * job yet, the answer is to add the job first, and the modal says so.
 */
export async function jobsForClient(
  clientId: string,
): Promise<{ id: string; label: string; interview_on: string | null }[]> {
  if (!clientId) return [];
  const supabase = await createClient();
  const { data } = await supabase
    .from("client_job_history")
    .select("match_id, employer_name, title, status, interview_on")
    .eq("client_id", clientId)
    .order("status_rank", { ascending: false });

  return (data ?? [])
    .filter((j) => j.status !== "Hired" && j.status !== "Not selected")
    .map((j) => ({
      id: j.match_id as string,
      label: `${j.employer_name}${j.title ? " — " + j.title : ""} (${j.status})`,
      interview_on: j.interview_on,
    }));
}

export async function quickAdd(
  _prev: QuickAddState,
  formData: FormData,
): Promise<QuickAddState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const what = String(formData.get("what") ?? "");
  if (!kindsForRole(me.role).includes(what as QuickKind)) {
    return { error: "Your role cannot add that.", ok: null };
  }

  const clientId = String(formData.get("client_id") ?? "").trim();
  const needsClient = what !== "session";
  if (needsClient && !clientId) return { error: "Which client?", ok: null };

  const pass = (pairs: Record<string, string | null | undefined>) => {
    const fd = new FormData();
    for (const [k, v] of Object.entries(pairs)) if (v != null) fd.set(k, v);
    return fd;
  };

  const str = (k: string) => String(formData.get(k) ?? "").trim();

  if (what === "note") {
    const fd = pass({ id: clientId, text: str("text"), type: str("type") || "General" });
    // The same default the Notes tab offers. Widening it is a decision, and
    // decisions belong on the screen that shows what is already there.
    fd.append("visible_roles", "Job Search");
    return addNote(_prev, fd);
  }

  if (what === "task") {
    return addTask(
      _prev,
      pass({ id: clientId, title: str("title"), due: str("due") || null }),
    );
  }

  if (what === "job") {
    const employerId = str("employer_id");
    return addClientJob(
      _prev,
      pass({
        client_id: clientId,
        title: str("title"),
        status: str("status") || "Applied",
        employer_id: employerId === "new" ? "" : employerId,
        new_employer: employerId === "new" ? str("new_employer") : "",
      }),
    );
  }

  if (what === "interview") {
    const matchId = str("match_id");
    const on = str("interview_on");
    if (!matchId) return { error: "Which job is the interview for?", ok: null };
    if (!/^\d{4}-\d{2}-\d{2}$/.test(on)) return { error: "What date?", ok: null };

    // Read the job back rather than trusting the page for the fields this
    // update would otherwise blank — updateClientJob writes the whole row.
    const supabase = await createClient();
    const { data: match } = await supabase
      .from("lead_matches")
      .select("applied_on, follow_up_on, outcome, notes")
      .eq("id", matchId)
      .maybeSingle();

    const result = await updateClientJob(
      _prev,
      pass({
        match_id: matchId,
        client_id: clientId,
        status: "Interview",
        interview_on: on,
        applied_on: match?.applied_on ?? "",
        follow_up_on: match?.follow_up_on ?? "",
        outcome: match?.outcome ?? "",
        notes: match?.notes ?? "",
      }),
    );

    return result.error
      ? result
      : { error: null, ok: `Interview set for ${on}, with prep and the appointment.` };
  }

  if (what === "placement") {
    return addPlacement(
      _prev,
      pass({
        id: clientId,
        employer: str("employer"),
        title: str("title"),
        start_date: str("start_date") || null,
      }),
    );
  }

  // A work session is the one thing here that is about the person adding it
  // rather than a client, so the client is optional.
  return logSession(
    _prev,
    pass({
      worked_on: str("worked_on"),
      hours: str("hours"),
      description: str("description"),
      client_id: clientId || null,
    }),
  );
}
