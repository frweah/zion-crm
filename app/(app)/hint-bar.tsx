"use client";

import { useActionState } from "react";
import { dismissHint, type HintState } from "./hint-actions";

const initial: HintState = { error: null, ok: null };

/**
 * One short note saying what a screen is for.
 *
 * Shown once. Half of what Margaret asked for after her first week already
 * existed, which is not a documentation problem — it is the screens not saying
 * what they are. So this says it, in two lines, where the thing itself is, and
 * then goes away for good.
 */
export function HintBar({
  hintKey,
  title,
  body,
}: {
  hintKey: string;
  title: string;
  body: string;
}) {
  const [state, action, pending] = useActionState(dismissHint, initial);

  // Optimistic: once dismissed the bar goes, without waiting for the reload.
  if (state.ok) return null;

  return (
    <div
      className="card"
      style={{ marginBottom: 14, borderLeft: "3px solid var(--gold)" }}
    >
      <div
        style={{ display: "flex", justifyContent: "space-between", gap: 12, alignItems: "start" }}
      >
        <div>
          <b style={{ fontSize: 13 }}>{title}</b>
          <p className="sub" style={{ margin: "4px 0 0" }}>
            {body}
          </p>
        </div>
        <form action={action}>
          <input type="hidden" name="key" value={hintKey} />
          <button className="btn ghost" type="submit" disabled={pending}>
            {pending ? "…" : "Got it"}
          </button>
        </form>
      </div>
      {state.error && <div style={{ color: "var(--bad)", fontSize: 12 }}>{state.error}</div>}
    </div>
  );
}
