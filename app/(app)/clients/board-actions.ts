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

  try {
    const supabase = await createClient();
    const { error } = await supabase.rpc("move_client", {
      p_client: id,
      p_stage: stage,
      p_note: note,
      p_document: document,
    });
    if (error) return { error: error.message, ok: null };

    // Moving into Job Placement starts the placement clock, which is the
    // placements row the retention checks and the fee both hang off. The
    // employer and the hire date are asked for in the same dialog, so the
    // clock starts with the move rather than a week later.
    const employer = field(formData, "employer");
    const hired = field(formData, "hire_date");
    if (stage === "Job Placement" && employer) {
      const { error: placed } = await supabase.from("placements").insert({
        client_id: id,
        employer,
        start_date: hired || null,
      });
      if (placed) {
        return {
          error: `Moved to ${stage}, but the placement was not recorded: ${placed.message}`,
          ok: null,
        };
      }
    }

    revalidatePath("/clients");
    revalidatePath(`/clients/${id}`);
    return { error: null, ok: `${name} moved to ${stage}.` };
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
