"use client";

import { useActionState, useState } from "react";
import { STAGES, stageLabel } from "@/lib/constants";
import { reactivateClient, deactivateClient, closeClient, type BoardState } from "./board-actions";
import { deleteClient } from "./[id]/actions";

/**
 * Putting a client back on the board, or taking one off, from All clients.
 *
 * Three things, and they are not opposites. Reactivate asks which stage they
 * are coming back into, because a person who left in Job Coaching rarely
 * comes back to Intake, and it defaults to the one they left. Deactivate only
 * takes them off the board. Close ends the work and closes the open
 * authorizations with it.
 *
 * Close was on the kanban card's menu, and the kanban is gone (clients board
 * brief, Part 2) - the stage board's row is read-only but for two cells, by
 * the same brief, so it did not go there. It belongs here anyway: this is
 * where a client is already taken off the board and put back.
 */
const initial: BoardState = { error: null, ok: null };

export function ClientRowActions({
  id,
  name,
  status,
  stage,
  canDeactivate,
  isAdmin,
}: {
  id: string;
  name: string;
  status: string;
  stage: string;
  canDeactivate: boolean;
  /** Deleting is Admin's, here as on the record (0231). */
  isAdmin: boolean;
}) {
  const [open, setOpen] = useState<"board" | "close" | "delete" | null>(null);
  const active = status === "Active";

  if (active && !canDeactivate && !isAdmin) return null;

  return (
    <>
      <span className="row2" style={{ gap: 6 }}>
        {(canDeactivate || !active) && (
          <button
            className="btn ghost"
            type="button"
            onClick={() => setOpen("board")}
            style={{ padding: "2px 10px" }}
          >
            {active ? "Take off the board" : "Put back"}
          </button>
        )}
        {active && canDeactivate && (
          <button
            className="btn ghost"
            type="button"
            onClick={() => setOpen("close")}
            style={{ padding: "2px 10px" }}
          >
            Close
          </button>
        )}
        {isAdmin && (
          <button
            className="btn ghost"
            type="button"
            onClick={() => setOpen("delete")}
            style={{ padding: "2px 10px" }}
          >
            Delete
          </button>
        )}
      </span>
      {open === "board" && (
        <div className="board-dialog">
          {active ? (
            <Deactivate id={id} name={name} onDone={() => setOpen(null)} />
          ) : (
            <Reactivate id={id} name={name} stage={stage} onDone={() => setOpen(null)} />
          )}
        </div>
      )}
      {open === "close" && (
        <div className="board-dialog">
          <CloseRow id={id} name={name} onDone={() => setOpen(null)} />
        </div>
      )}
      {open === "delete" && (
        <div className="board-dialog">
          <DeleteRow id={id} name={name} onDone={() => setOpen(null)} />
        </div>
      )}
    </>
  );
}

/**
 * Deleting from the list, with the same two steps the record asks for.
 *
 * The reason and the typed name are not ceremony. The name is the step that
 * makes somebody read which row they are on, and a list is exactly where that
 * mistake is easiest to make - the record screen at least shows you whose
 * record it is. Every refusal is the database's and is shown as it arrives.
 */
function DeleteRow({ id, name, onDone }: { id: string; name: string; onDone: () => void }) {
  const [state, action, pending] = useActionState(deleteClient, {
    error: null,
    ok: null,
  } as { error: string | null; ok: string | null });
  const [typed, setTyped] = useState("");
  const matches = typed.trim().toLowerCase() === name.trim().toLowerCase();

  return (
    <form className="card" action={action}>
      <h3 style={{ marginTop: 0 }}>Delete {name}</h3>
      <p className="sub">Everything of theirs goes with them, and cannot be undone.</p>
      {state.error && <div className="alert bad">{state.error}</div>}

      <input type="hidden" name="id" value={id} />
      <input type="hidden" name="name" value={name} />

      <label className="field" htmlFor={`del-why-${id}`}>
        Why
        <textarea id={`del-why-${id}`} name="reason" rows={2} required />
      </label>
      <label className="field" htmlFor={`del-name-${id}`}>
        Type the name to confirm
        <input
          id={`del-name-${id}`}
          name="confirm_name"
          value={typed}
          onChange={(e) => setTyped(e.target.value)}
          required
        />
      </label>

      <div className="row2" style={{ gap: 8 }}>
        <button className="btn gold" type="submit" disabled={pending || !matches}>
          {pending ? "Deleting…" : "Delete"}
        </button>
        <button className="btn ghost" type="button" onClick={onDone} disabled={pending}>
          Keep them
        </button>
      </div>
    </form>
  );
}

function Reactivate({
  id,
  name,
  stage,
  onDone,
}: {
  id: string;
  name: string;
  stage: string;
  onDone: () => void;
}) {
  const [state, action, pending] = useActionState(reactivateClient, initial);
  // The stage they left, which is where they usually belong again.
  const fallback = (STAGES as readonly string[]).includes(stage) ? stage : "Intake";

  if (state.ok) {
    return (
      <div className="card">
        <h3 style={{ marginTop: 0 }}>Back on the board</h3>
        <p className="sub">{state.ok}</p>
        <button className="btn gold" type="button" onClick={onDone}>
          Back to the list
        </button>
      </div>
    );
  }

  return (
    <form className="card" action={action}>
      <h3 style={{ marginTop: 0 }}>Put {name} back</h3>
      {state.error && <div className="alert bad">{state.error}</div>}
      <input type="hidden" name="client_id" value={id} />
      <input type="hidden" name="name" value={name} />

      <label className="field" htmlFor={`stage-${id}`}>
        Stage
        <select id={`stage-${id}`} name="stage" defaultValue={fallback}>
          {STAGES.map((s) => (
            <option key={s} value={s}>
              {stageLabel(s)}
            </option>
          ))}
        </select>
      </label>
      <p className="lock">The stage they left is already chosen.</p>

      <label className="field" htmlFor={`note-${id}`}>
        Why
        <textarea id={`note-${id}`} name="note" rows={3} required />
      </label>

      <div className="row2" style={{ gap: 8 }}>
        <button className="btn gold" type="submit" disabled={pending}>
          {pending ? "Putting back…" : "Put back"}
        </button>
        <button className="btn ghost" type="button" onClick={onDone} disabled={pending}>
          Leave them off
        </button>
      </div>
    </form>
  );
}

/** Closing: the work ends, and the open authorizations end with it. */
function CloseRow({ id, name, onDone }: { id: string; name: string; onDone: () => void }) {
  const [state, action, pending] = useActionState(closeClient, initial);

  if (state.ok) {
    return (
      <div className="card">
        <h3 style={{ marginTop: 0 }}>Closed</h3>
        <p className="sub">{state.ok}</p>
        <button className="btn gold" type="button" onClick={onDone}>
          Back to the list
        </button>
      </div>
    );
  }

  return (
    <form className="card" action={action}>
      <h3 style={{ marginTop: 0 }}>Close {name}</h3>
      <p className="sub">Their open authorizations close with them.</p>
      {state.error && <div className="alert bad">{state.error}</div>}
      <input type="hidden" name="client_id" value={id} />
      <input type="hidden" name="name" value={name} />

      <label className="field" htmlFor={`closing-${id}`}>
        Why
        <textarea id={`closing-${id}`} name="reason" rows={3} required />
      </label>

      <div className="row2" style={{ gap: 8 }}>
        <button className="btn gold" type="submit" disabled={pending}>
          {pending ? "Closing…" : "Close them"}
        </button>
        <button className="btn ghost" type="button" onClick={onDone} disabled={pending}>
          Leave them open
        </button>
      </div>
    </form>
  );
}

function Deactivate({ id, name, onDone }: { id: string; name: string; onDone: () => void }) {
  const [state, action, pending] = useActionState(deactivateClient, initial);

  if (state.ok) {
    return (
      <div className="card">
        <h3 style={{ marginTop: 0 }}>Off the board</h3>
        <p className="sub">{state.ok}</p>
        <button className="btn gold" type="button" onClick={onDone}>
          Back to the list
        </button>
      </div>
    );
  }

  return (
    <form className="card" action={action}>
      <h3 style={{ marginTop: 0 }}>Take {name} off the board</h3>
      <p className="sub">Their record and their billing stay as they are.</p>
      {state.error && <div className="alert bad">{state.error}</div>}
      <input type="hidden" name="client_id" value={id} />
      <input type="hidden" name="name" value={name} />

      <label className="field" htmlFor={`why-${id}`}>
        Why
        <textarea id={`why-${id}`} name="reason" rows={3} required />
      </label>

      <div className="row2" style={{ gap: 8 }}>
        <button className="btn gold" type="submit" disabled={pending}>
          {pending ? "Taking off…" : "Take them off"}
        </button>
        <button className="btn ghost" type="button" onClick={onDone} disabled={pending}>
          Leave them on
        </button>
      </div>
    </form>
  );
}
