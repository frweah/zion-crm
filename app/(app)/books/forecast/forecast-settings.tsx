"use client";

import { useActionState } from "react";
import { setAlertThresholds, type BooksState } from "../actions";

const initial: BooksState = { error: null, ok: null };

/**
 * The two numbers that turn the alerts on.
 *
 * Both are off until somebody sets them, which is deliberate: an alert the
 * practice did not ask for is an alert they learn to ignore, and the first
 * one they ignore is the one that mattered.
 */
export function ForecastSettings({
  cashFloor,
  tolerance,
}: {
  cashFloor: number | null;
  tolerance: number;
}) {
  const [state, action, pending] = useActionState(setAlertThresholds, initial);

  return (
    <form action={action} className="card no-print" style={{ marginTop: 24 }}>
      <h3 style={{ marginTop: 0 }}>When to warn me</h3>
      {state.error && <div className="alert bad">{state.error}</div>}
      {state.ok && <div className="alert ok">{state.ok}</div>}
      <div className="row2" style={{ gap: 8, flexWrap: "wrap", alignItems: "flex-end" }}>
        <label>
          Cash floor
          <input
            name="cash_floor"
            inputMode="decimal"
            defaultValue={cashFloor === null ? "" : String(cashFloor)}
            placeholder="Leave empty for no warning"
          />
        </label>
        <label>
          Over budget by
          <input name="budget_tolerance" inputMode="decimal" defaultValue={String(tolerance)} />
        </label>
        <button className="btn" type="submit" disabled={pending}>
          Save
        </button>
      </div>
      <p className="sub">
        A percentage, so a cost account a few dollars over on the second of the month is not an
        alert. Both are checked nightly, with the rest.
      </p>
    </form>
  );
}
