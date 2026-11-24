"use client";

import { useActionState } from "react";
import { askForAPass, type RunNowState } from "./run-now";

const initial: RunNowState = { error: null, ok: null };

/**
 * Run now, on Admin → Documents.
 *
 * The agent reads the client folders at ten and at seven. This asks it to
 * read them on its next wake instead, which is within fifteen minutes - the
 * quarter-hourly pass that fetches phone photos picks the ask up.
 *
 * What it says afterwards is what actually happened: the ask was written
 * down. Not "done", because nothing has been read yet, and not a spinner
 * waiting for a machine that might be switched off.
 */
export function RunNowButton({
  waiting,
  askedBy,
}: {
  /** An ask already waiting, so a second press does not make a second row. */
  waiting: boolean;
  askedBy: string;
}) {
  const [state, act, pending] = useActionState(askForAPass, initial);
  const said = state.error ?? state.ok;

  return (
    <form action={act} className="row2" style={{ gap: 8, alignItems: "baseline" }}>
      <button className="btn ghost" disabled={pending} style={{ textDecoration: "none" }}>
        {pending ? "Asking…" : "Run now"}
      </button>
      {said ? (
        <span className={state.error ? "bad lock" : "lock"}>{said}</span>
      ) : waiting ? (
        <span className="lock">
          Asked by {askedBy || "somebody"} — the agent takes it on its next wake
        </span>
      ) : null}
    </form>
  );
}
