"use client";

import { useActionState } from "react";
import { setStaffPay, deleteStaffPay, type StaffState } from "./checklist-actions";

const initial: StaffState = { error: null, ok: null };

export type PayRow = {
  id: string;
  staff_id: string;
  pay_rate: number;
  rate_unit: string;
  effective_from: string;
  note: string;
};

const rate = (r: PayRow) =>
  `${Number(r.pay_rate).toLocaleString("en-US", { style: "currency", currency: "USD" })}${
    r.rate_unit === "Hourly" ? " an hour" : " flat"
  }`;

function RemoveRate({ id }: { id: string }) {
  const [state, action, pending] = useActionState(deleteStaffPay, initial);

  return (
    <form action={action} style={{ display: "inline" }}>
      <input type="hidden" name="pay_id" value={id} />
      <button className="btn ghost" type="submit" disabled={pending}>
        {pending ? "…" : "Remove"}
      </button>
      {state.error && <div style={{ color: "var(--bad)", fontSize: 12 }}>{state.error}</div>}
    </form>
  );
}

/**
 * One person's rate, and the rates before it.
 *
 * A rate is a dated record rather than a field, so setting a new one adds to
 * the history instead of replacing it — what somebody was paid under last year
 * is not something this screen should be able to change. Only the newest entry
 * can be removed, which covers mistyping the figure you just entered and
 * nothing else.
 */
export function PayRates({
  staffId,
  name,
  rows,
  today,
}: {
  staffId: string;
  name: string;
  rows: PayRow[];
  today: string;
}) {
  const [state, action, pending] = useActionState(setStaffPay, initial);

  const history = [...rows].sort((a, b) => b.effective_from.localeCompare(a.effective_from));
  const current = history.find((r) => r.effective_from <= today);
  const upcoming = history.filter((r) => r.effective_from > today);
  const newest = history[0];

  return (
    <details className="card" style={{ marginBottom: 10 }} open={rows.length === 0}>
      <summary style={{ cursor: "pointer" }}>
        <b>{name}</b>{" "}
        {current ? (
          <span className="chip ok">{rate(current)}</span>
        ) : (
          <span className="chip warn">no rate recorded</span>
        )}
        {upcoming.length > 0 && (
          <span className="chip" style={{ marginLeft: 6 }}>
            {rate(upcoming[upcoming.length - 1])} from {upcoming[upcoming.length - 1].effective_from}
          </span>
        )}
      </summary>

      {state.error && <div className="alert bad">{state.error}</div>}
      {state.ok && <div className="alert ok">{state.ok}</div>}

      {history.length > 0 && (
        <table className="t">
          <thead>
            <tr>
              <th>From</th>
              <th>Rate</th>
              <th>Note</th>
              <th />
            </tr>
          </thead>
          <tbody>
            {history.map((r) => (
              <tr key={r.id} style={r.effective_from > today ? { opacity: 0.7 } : undefined}>
                <td>
                  {r.effective_from}
                  {r.effective_from > today && <div className="lock">not yet in effect</div>}
                </td>
                <td>{rate(r)}</td>
                <td style={{ fontSize: 12, color: "var(--muted)" }}>{r.note || "—"}</td>
                <td style={{ textAlign: "right" }}>
                  {r.id === newest?.id ? (
                    <RemoveRate id={r.id} />
                  ) : (
                    <span className="lock">what they were paid under</span>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}

      <form action={action} style={{ marginTop: 12 }}>
        <input type="hidden" name="staff_id" value={staffId} />
        <div className="row2" style={{ alignItems: "flex-end" }}>
          <label className="field">
            Rate
            <input type="number" name="pay_rate" min="0.01" step="0.01" required />
          </label>
          <label className="field">
            Per
            <select name="rate_unit" defaultValue="Hourly">
              <option value="Hourly">Hour</option>
              <option value="Flat">Flat amount</option>
            </select>
          </label>
          <label className="field">
            In effect from
            <input type="date" name="effective_from" defaultValue={today} required />
          </label>
          <label className="field" style={{ flex: 2 }}>
            Note
            <input name="note" placeholder="What was agreed, and when" />
          </label>
          <button className="btn" type="submit" disabled={pending}>
            {pending ? "Saving…" : "Set rate"}
          </button>
        </div>
      </form>

      <p className="lock" style={{ marginBottom: 0 }}>
        Setting a rate adds to the history rather than replacing it, so work done before the date
        keeps the rate it was done under. A date in the future is fine — a raise can be recorded
        before it starts. {name.split(" ")[0]} can see this rate and nobody else&apos;s.
      </p>
    </details>
  );
}
