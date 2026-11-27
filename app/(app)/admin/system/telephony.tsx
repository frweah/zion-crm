"use client";

import { useActionState } from "react";
import { saveTelephony, type TelephonyState } from "./telephony-actions";

const initial: TelephonyState = { error: null, ok: null };

export type TelephonyChoice = {
  /** What the switch says now. */
  provider: "ghl" | "twilio";
  /** Whether each carrier has everything it needs to send. */
  ghlReady: boolean;
  twilioReady: boolean;
  /** The client line, so the screen names the number being moved. */
  number: string;
};

/**
 * Admin → System → Client line.
 *
 * One choice, and it governs texting and calls together: a practice half on
 * one carrier and half on another is a practice whose client line rings in
 * two places. Moving it is a row in `org_settings` rather than a deploy,
 * because the minute after a cutover goes wrong is not the minute to be
 * waiting for a build.
 *
 * A carrier whose keys are not set is shown as not ready and the switch
 * refuses it. That refusal is the point of the screen.
 */
export function TelephonyForm({ choice }: { choice: TelephonyChoice }) {
  const [state, action, pending] = useActionState(saveTelephony, initial);

  const options = [
    { value: "ghl", name: "GoHighLevel", ready: choice.ghlReady },
    { value: "twilio", name: "Twilio", ready: choice.twilioReady },
  ] as const;

  return (
    <form action={action} className="card" style={{ marginTop: 14 }}>
      {state.error && <div className="alert bad">{state.error}</div>}
      {state.ok && <div className="alert ok">{state.ok}</div>}

      <p className="sub" style={{ marginTop: 0 }}>
        {choice.number} texts and rings through{" "}
        <span className="chip ok">{choice.provider === "twilio" ? "Twilio" : "GoHighLevel"}</span>
      </p>

      <div style={{ display: "grid", gap: 8, marginTop: 10 }}>
        {options.map((o) => (
          <label key={o.value} style={{ display: "flex", alignItems: "center", gap: 8 }}>
            <input
              type="radio"
              name="provider"
              value={o.value}
              defaultChecked={choice.provider === o.value}
            />
            <span>{o.name}</span>
            {o.ready ? (
              <span className="chip ok">ready</span>
            ) : (
              <span className="chip warn">keys not set</span>
            )}
          </label>
        ))}
      </div>

      <button className="btn" type="submit" disabled={pending} style={{ marginTop: 12 }}>
        {pending ? "Moving…" : "Move the line"}
      </button>
    </form>
  );
}
