"use client";

import { useActionState, useState } from "react";
import { decideCorrection, type HoursDecision } from "./actions";

const initial: HoursDecision = { error: null, ok: null };

/**
 * Approve or decline a correction to somebody's hours.
 *
 * Approving takes one press, because the common case is a manager who already
 * knows the punch was missed. Declining asks for a reason first: the person
 * reads it and it is the whole answer they get, so "no" on its own is not an
 * answer this screen will send.
 */
export function Decide({ correctionId }: { correctionId: string }) {
  const [state, action, pending] = useActionState(decideCorrection, initial);
  const [declining, setDeclining] = useState(false);

  if (state.ok) return <span className="lock">{state.ok}</span>;

  return (
    <form action={action} className="row2" style={{ gap: 6, alignItems: "center", flexWrap: "wrap" }}>
      <input type="hidden" name="correction_id" value={correctionId} />
      {declining ? (
        <>
          <input
            name="reason"
            placeholder="Why it is declined"
            maxLength={300}
            required
            style={{ minWidth: 200 }}
          />
          <input type="hidden" name="decision" value="decline" />
          <button className="btn" type="submit" disabled={pending}>
            {pending ? "…" : "Decline it"}
          </button>
          <button className="btn ghost" type="button" onClick={() => setDeclining(false)}>
            Leave it
          </button>
        </>
      ) : (
        <>
          <input type="hidden" name="decision" value="approve" />
          <button className="btn" type="submit" disabled={pending}>
            {pending ? "…" : "Approve"}
          </button>
          <button className="btn ghost" type="button" onClick={() => setDeclining(true)}>
            Decline
          </button>
        </>
      )}
      {state.error && <span className="lock" style={{ color: "var(--bad)" }}>{state.error}</span>}
    </form>
  );
}
