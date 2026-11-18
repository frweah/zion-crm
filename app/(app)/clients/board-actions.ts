"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";
import { STAGES } from "@/lib/constants";

/**
 * What the board can do to a card.
 *
 * Every one of these is a thin wrapper. The rules - a move needs a note, a
 * close refuses while money is out with USOR, who may close at all - are in
 * the database (0223), so the agent, an import and this screen are held to
 * the same ones. What is here is the form data and the words that come back.
 *
 * The refusals are passed through as the database wrote them, because the
 * database wrote them for a person to read.
 */
export type BoardState = { error: string | null; ok: string | null };

const field = (f: FormData, k: string) => String(f.get(k) ?? "").trim();

/**
 * Who a client is assigned to, set from the board's own row.
 *
 * The board edits two cells, and this is one of them (clients board brief,
 * Part 2). It is a write to the client like the one the record's own form
 * makes - the same RLS policy decides whether this person may make it, and
 * the same `clients_log` trigger records it in the directory log - narrowed
 * to one column so that editing it from a grid cannot quietly blank the rest
 * of the record, which a form posting every field would do.
 */
export async function setAssignedStaff(_prev: BoardState, formData: FormData): Promise<BoardState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "Sign in again to change who is assigned.", ok: null };

  const id = field(formData, "client_id");
  const staffId = field(formData, "assigned_staff_id");

  const supabase = await createClient();
  const { data, error } = await supabase
    .from("clients")
    .update({ assigned_staff_id: staffId || null })
    .eq("id", id)
    .select("id, name")
    .maybeSingle();

  if (error) return { error: error.message, ok: null };
  if (!data) return { error: "That client is not yours to change.", ok: null };

  revalidatePath("/clients");
  return { error: null, ok: null };
}

/** Move one client to one stage, with the note the database insists on. */
export async function moveClient(_prev: BoardState, formData: FormData): Promise<BoardState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "Sign in again to move a client.", ok: null };

  const id = field(formData, "client_id");
  const stage = field(formData, "stage");
  const note = field(formData, "note");
  const name = field(formData, "name") || "They";

  if (!(STAGES as readonly string[]).includes(stage)) {
    return { error: "That is not one of the seven stages.", ok: null };
  }
  if (!note) return { error: "Say why they are moving.", ok: null };

  // A file attached to the move, already in storage and already recorded by
  // the browser before it got here (0231). What arrives is the row's id.
  const document = field(formData, "document_id") || null;

  // Moving into Job Placement starts the placement clock, which is the
  // placements row the retention checks and the fee both hang off. The
  // employer and the hire date are asked for in the same dialog, so the clock
  // starts with the move rather than a week later - and they are passed to
  // `move_client` rather than written here, because an approval is the other
  // door into that stage and this screen is not on that path (0373).
  const employer = field(formData, "employer");
  const hired = field(formData, "hire_date");

  try {
    const supabase = await createClient();
    const { data, error } = await supabase.rpc("move_client", {
      p_client: id,
      p_stage: stage,
      p_note: note,
      p_document: document,
      p_employer: employer || null,
      p_start: hired || null,
    });
    if (error) return { error: error.message, ok: null };

    revalidatePath("/clients");
    revalidatePath(`/clients/${id}`);
    // What the move had to say about the placement, where there was anything
    // to say: that it is recorded, or that the employer was left blank and so
    // the clock has not started.
    const said = Array.isArray(data) ? (data[0]?.said ?? null) : null;
    return { error: null, ok: `${name} moved to ${stage}${said ? ` — ${said}` : ""}.` };
  } catch (err) {
    return { error: err instanceof Error ? err.message : "That move did not go through.", ok: null };
  }
}

/** Off the board, with a reason, and their open authorizations closed with it. */
export async function closeClient(_prev: BoardState, formData: FormData): Promise<BoardState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "Sign in again to close a client.", ok: null };

  const id = field(formData, "client_id");
  const reason = field(formData, "reason");
  const name = field(formData, "name") || "They";
  if (!reason) return { error: "Say why they are being closed.", ok: null };

  try {
    const supabase = await createClient();
    const { data, error } = await supabase.rpc("close_client", { p_client: id, p_reason: reason });
    if (error) return { error: error.message, ok: null };

    const closed = Array.isArray(data) ? (data[0]?.closed_authorizations ?? 0) : 0;
    revalidatePath("/clients");
    revalidatePath(`/clients/${id}`);
    return {
      error: null,
      ok:
        closed > 0
          ? `${name} is inactive, and ${closed} authorization${closed === 1 ? "" : "s"} closed with them.`
          : `${name} is inactive.`,
    };
  } catch (err) {
    return { error: err instanceof Error ? err.message : "That did not go through.", ok: null };
  }
}

/** Back on the board, in a stage somebody chose. */
export async function reactivateClient(_prev: BoardState, formData: FormData): Promise<BoardState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "Sign in again to reactivate a client.", ok: null };

  const id = field(formData, "client_id");
  const stage = field(formData, "stage");
  const note = field(formData, "note");
  const name = field(formData, "name") || "They";

  if (!(STAGES as readonly string[]).includes(stage)) {
    return { error: "That is not one of the seven stages.", ok: null };
  }
  if (!note) return { error: "Say why they are coming back.", ok: null };

  try {
    const supabase = await createClient();
    const { error } = await supabase.rpc("reactivate_client", {
      p_client: id,
      p_stage: stage,
      p_note: note,
    });
    if (error) return { error: error.message, ok: null };

    revalidatePath("/clients");
    revalidatePath(`/clients/${id}`);
    return { error: null, ok: `${name} is back on the board, in ${stage}.` };
  } catch (err) {
    return { error: err instanceof Error ? err.message : "That did not go through.", ok: null };
  }
}

/**
 * Off the board, from the board's own panel, its menu, or All clients.
 *
 * The same end state as Close and a different act: Close is the end of the
 * work and takes the authorizations with it; this only takes somebody off
 * the board. So it does not touch billing, and it says so on the screen.
 *
 * No role check here any more. Anybody who can move a card can do this
 * (owner, 22 Oct 2026), and the note and the logging are the database's
 * (0232) - which is what makes them true of an import as well as of a click.
 */
export async function deactivateClient(_prev: BoardState, formData: FormData): Promise<BoardState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "Sign in again.", ok: null };

  const id = field(formData, "client_id");
  const reason = field(formData, "reason");
  const name = field(formData, "name") || "They";
  if (!reason) return { error: "Say why they are coming off the board.", ok: null };

  try {
    const supabase = await createClient();
    const { error } = await supabase.rpc("deactivate_client", {
      p_client: id,
      p_note: reason,
    });
    if (error) return { error: error.message, ok: null };

    revalidatePath("/clients");
    revalidatePath(`/clients/${id}`);
    return { error: null, ok: `${name} is off the board. Their billing is untouched.` };
  } catch (err) {
    return { error: err instanceof Error ? err.message : "That did not go through.", ok: null };
  }
}

/**
 * Request change: what every role but Admin gets where Admin gets Move
 * (clients board brief, Part 3).
 *
 * A thin wrapper again. Who may ask, who may not, one ask at a time per
 * client and stage, the Admin task and the bell are all `request_stage_change`
 * (0372) - so the screen cannot offer a shortcut round any of them, and
 * neither can the next caller.
 */
export async function requestStageChange(_prev: BoardState, formData: FormData): Promise<BoardState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "Sign in again to ask for a change.", ok: null };

  const id = field(formData, "client_id");
  const stage = field(formData, "stage");
  const reason = field(formData, "reason");

  if (!(STAGES as readonly string[]).includes(stage)) {
    return { error: "That is not one of the seven stages.", ok: null };
  }
  if (!reason) return { error: "Say why it should move.", ok: null };

  try {
    const supabase = await createClient();
    const { data, error } = await supabase.rpc("request_stage_change", {
      p_client: id,
      p_stage: stage,
      p_reason: reason,
    });
    if (error) return { error: error.message, ok: null };

    revalidatePath("/clients");
    revalidatePath(`/clients/${id}`);
    const said = Array.isArray(data) ? (data[0]?.said ?? null) : null;
    return { error: null, ok: said ?? `Asked to move them to ${stage}.` };
  } catch (err) {
    return { error: err instanceof Error ? err.message : "That did not go through.", ok: null };
  }
}

/**
 * Approve or decline one, which only Admin may do.
 *
 * The approval performs the move itself, inside the database, as the
 * administrator who pressed it - which is the only way a move can happen now.
 * The reason field is always sent: on an approve it is a word to add to the
 * note, on a decline it is the thing the person who asked will be told, and
 * the database refuses a decline without one.
 *
 * The employer and the start date are sent too, for an approval into Job
 * Placement: the same two questions Move asks, because an approval is the
 * other door into that stage and the placement clock starts at the door or
 * not at all (0373).
 */
export async function decideStageRequest(_prev: BoardState, formData: FormData): Promise<BoardState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "Sign in again to decide this.", ok: null };

  const request = field(formData, "request_id");
  const approve = field(formData, "decision") === "approve";
  const reason = field(formData, "reason");
  const client = field(formData, "client_id");

  if (!request) return { error: "That request is not there.", ok: null };
  if (!approve && !reason) {
    return { error: "Say why it is declined. Whoever asked needs to know what to do instead.", ok: null };
  }

  try {
    const supabase = await createClient();
    const { data, error } = await supabase.rpc("decide_stage_request", {
      p_request: request,
      p_approve: approve,
      p_reason: reason,
      p_employer: field(formData, "employer") || null,
      p_start: field(formData, "hire_date") || null,
    });
    if (error) return { error: error.message, ok: null };

    revalidatePath("/clients");
    if (client) revalidatePath(`/clients/${client}`);
    const said = Array.isArray(data) ? (data[0]?.said ?? null) : null;
    return { error: null, ok: said ?? (approve ? "Moved." : "Declined.") };
  } catch (err) {
    return { error: err instanceof Error ? err.message : "That did not go through.", ok: null };
  }
}
