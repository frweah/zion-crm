"use client";

import { useActionState } from "react";
import { setSchedule, type CredentialState } from "./credential-actions";

const initial: CredentialState = { error: null, ok: null };

const DAYS = [
  [1, "Mon"],
  [2, "Tue"],
  [3, "Wed"],
  [4, "Thu"],
  [5, "Fri"],
  [6, "Sat"],
  [7, "Sun"],
] as const;

/**
 * When somebody is expected to work.
 *
 * Two things read it: the reminder fifteen minutes after their start, and the
 * over-forty flag on Admin → Hours. Leaving the days empty is a real answer -
 * somebody with no fixed days is not late for anything - so it is not
 * required and nothing is filled in for them.
 */
export function ScheduleForm({
  staffId,
  workDays,
  startsAt,
  weeklyHours,
  note,
  readOnly,
}: {
  staffId: string;
  workDays: number[];
  startsAt: string | null;
  weeklyHours: number | null;
  note: string;
  readOnly?: boolean;
}) {
  const [state, action, saving] = useActionState(setSchedule, initial);

  if (readOnly) {
    return (
      <p className="lock" style={{ margin: 0 }}>
        {workDays.length === 0
          ? "No scheduled days"
          : `${DAYS.filter(([d]) => workDays.includes(d)).map(([, l]) => l).join(", ")}${
              startsAt ? ` from ${startsAt.slice(0, 5)}` : ""
            }${weeklyHours ? `, ${weeklyHours}h a week` : ""}`}
      </p>
    );
  }

  return (
    <form action={action} className="grid" style={{ gap: 8 }}>
      <input type="hidden" name="staff_id" value={staffId} />
      <div className="row2" style={{ gap: 10, flexWrap: "wrap" }}>
        {DAYS.map(([d, label]) => (
          <label key={d} className="row2" style={{ gap: 4, alignItems: "center" }}>
            <input type="checkbox" name={`day_${d}`} defaultChecked={workDays.includes(d)} />
            {label}
          </label>
        ))}
      </div>
      <div className="row2" style={{ gap: 10, flexWrap: "wrap" }}>
        <label className="field">
          Starts at
          <input type="time" name="starts_at" defaultValue={startsAt?.slice(0, 5) ?? ""} />
        </label>
        <label className="field">
          Hours a week
          <input
            type="number"
            name="weekly_hours"
            min="1"
            max="80"
            step="0.5"
            defaultValue={weeklyHours ?? ""}
          />
        </label>
      </div>
      <input name="note" placeholder="Anything worth saying about it" defaultValue={note} maxLength={200} />
      <div className="row2" style={{ gap: 6 }}>
        <button className="btn" type="submit" disabled={saving}>
          {saving ? "…" : "Record it"}
        </button>
        {state.error && <span className="lock" style={{ color: "var(--bad)" }}>{state.error}</span>}
        {state.ok && <span className="lock">{state.ok}</span>}
      </div>
    </form>
  );
}
