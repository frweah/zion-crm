"use client";

import { useActionState } from "react";
import { setEngagement, type EngagementState } from "./engagement-actions";

const initial: EngagementState = { error: null, ok: null };

export function EngagementForm({
  staffId,
  current,
  startedOn,
  readOnly,
}: {
  staffId: string;
  current: string | null;
  startedOn: string | null;
  readOnly?: boolean;
}) {
  const [state, action, pending] = useActionState(setEngagement, initial);
  if (readOnly) return <p style={{ margin: 0 }}>{current ?? "Not recorded"}</p>;
  return (
    <form action={action}>
      {state.error && <div className="alert bad">{state.error}</div>}
      {state.ok && <div className="alert ok">{state.ok}</div>}
      {!current && (
        <p className="lock" style={{ marginTop: 0 }}>
          Not recorded yet. Until it is, their onboarding holds the identity and tax steps - it decides the I-9 and
          which tax form is theirs.
        </p>
      )}
      <div className="row2" style={{ alignItems: "flex-end" }}>
        <input type="hidden" name="staff_id" value={staffId} />
        <label className="field">
          Engaged as
          <select id="engagement-type" name="employment_type" defaultValue={current ?? ""} required>
            <option value="">Choose…</option>
            <option value="Employee">Employee - W-4 and I-9</option>
            <option value="Contractor">Contractor - W-9 or W-8BEN</option>
            {current === "Owner" && <option value="Owner">Owner</option>}
          </select>
        </label>
        <label className="field" style={{ maxWidth: 180 }}>
          Start date
          <input id="engagement-start" name="started_on" type="date" defaultValue={startedOn ?? ""} />
        </label>
        <button className="btn" type="submit" disabled={pending}>
          {pending ? "Saving…" : "Save"}
        </button>
      </div>
    </form>
  );
}
