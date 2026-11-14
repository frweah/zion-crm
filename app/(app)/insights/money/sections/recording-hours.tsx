"use client";

import { useActionState } from "react";
import { setRecordingHours, type MoneyState } from "./recording-hours-action";

const initial: MoneyState = { error: null, ok: null };

/**
 * The month's hours, changed where the bill is read (item F).
 *
 * Admin's, and one field. Raising it does not read anything that is already
 * held — a held recording is let through one at a time from the client's
 * record, because deciding to pay for a particular recording and deciding how
 * much the practice will pay in a month are two decisions.
 */
export function RecordingHours({ allowed }: { allowed: number }) {
  const [state, action, saving] = useActionState(setRecordingHours, initial);
  return (
    <form action={action} className="card" style={{ marginTop: 12 }}>
      {state.error && <p className="alert bad">{state.error}</p>}
      {state.ok && <p className="alert ok">{state.ok}</p>}
      <label className="field" style={{ maxWidth: 260 }}>
        <span>Hours a person a month</span>
        <input name="hours" type="number" min={0} max={200} defaultValue={allowed} required />
      </label>
      <button className="btn ghost" disabled={saving}>
        {saving ? "…" : "Change the limit"}
      </button>
    </form>
  );
}
