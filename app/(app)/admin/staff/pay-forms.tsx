"use client";

import { useActionState } from "react";
import { setStaffPay, deleteStaffPay, type StaffState } from "./checklist-actions";
import { formatPayRate } from "@/lib/constants";
import { DataTable } from "../../data-table";

const initial: StaffState = { error: null, ok: null };

export type PayRow = {
  id: string;
  staff_id: string;
  pay_rate: number;
  rate_unit: string;
  effective_from: string;
  note: string;
};

// Shared with the Hours screen, which also shows a rate. See formatPayRate.
const rate = (r: PayRow) => formatPayRate(r.pay_rate, r.rate_unit);

function RemoveRate({ id }: { id: string }) {
  const [state, action, pending] = useActionState(deleteStaffPay, initial);

  return (
    <form action={action} style={{ display: "inline" }}>
      <input type="hidden" name="pay_id" value={id} />
      <button className="btn ghost" type="submit" disabled={pending}>
        {pending ? "…" : "Remove"}
      </button>
      {state.error && <div style={{ color: "var(--bad)", fontSize: "var(--text-sm)" }}>{state.error}</div>}
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
 *
 * It sits on the person's own record now, so it is open rather than folded
 * away behind their name the way it was in a list of everybody.
 */
export function PayRates({
  staffId,
  name,
  rows,
  today,
  readOnly,
}: {
  staffId: string;
  name: string;
  rows: PayRow[];
  today: string;
  /** Somebody inactive: the history is shown as it was, and nothing can be set or removed. */
  readOnly?: boolean;
}) {
  const [state, action, pending] = useActionState(setStaffPay, initial);

  const history = [...rows].sort((a, b) => b.effective_from.localeCompare(a.effective_from));
  const current = history.find((r) => r.effective_from <= today);
  const upcoming = history.filter((r) => r.effective_from > today);
  const newest = history[0];

  return (
    <div className="card" style={{ padding: 0 }}>
      <div style={{ padding: "16px 16px 12px" }}>
        {current ? (
          <span className="chip ok">Now {rate(current)}</span>
        ) : (
          <span className="chip warn">no rate recorded</span>
        )}
        {upcoming.length > 0 && (
          <span className="chip" style={{ marginLeft: 6 }}>
            {rate(upcoming[upcoming.length - 1])} from {upcoming[upcoming.length - 1].effective_from}
          </span>
        )}
        {state.error && <div className="alert bad" style={{ marginTop: 10 }}>{state.error}</div>}
        {state.ok && <div className="alert ok" style={{ marginTop: 10 }}>{state.ok}</div>}
      </div>

      <DataTable
        label="rates"
        columns={[
          { key: "from", label: "From" },
          { key: "rate", label: "Rate", align: "right" },
          { key: "note", label: "Note" },
          { key: "actions", label: "", sortable: false },
        ]}
        rows={history.map((r) => ({
          key: r.id,
          sort: { from: r.effective_from, rate: Number(r.pay_rate), note: r.note },
          cells: {
            from: (
              <>
                {r.effective_from}
                {r.effective_from > today && <div className="lock">not yet in effect</div>}
              </>
            ),
            rate: rate(r),
            note: <span className="lock">{r.note || "—"}</span>,
            actions:
              r.id === newest?.id && !readOnly ? (
                <RemoveRate id={r.id} />
              ) : (
                <span className="lock">{r.id === newest?.id ? "their last rate" : "what they were paid under"}</span>
              ),
          },
        }))}
        empty={`No rate has been recorded for ${name} yet.`}
      />

      {readOnly ? (
        <p className="lock" style={{ margin: 0, padding: "10px 16px 16px" }}>
          Kept as it was when {name.split(" ")[0]} left. No rate can be set or removed.
        </p>
      ) : (
      <>
      <form action={action} style={{ padding: "12px 16px 0" }}>
        <input type="hidden" name="staff_id" value={staffId} />
        <div className="row2" style={{ alignItems: "flex-end" }}>
          <label className="field">
            Rate
            <input type="number" name="pay_rate" min="0.0001" step="0.0001" required />
            <span className="lock">Up to four decimals — 5.625 an hour is kept as 5.625</span>
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

      <p className="lock" style={{ margin: 0, padding: "10px 16px 16px" }}>
        Setting a rate adds to the history rather than replacing it, so work done before the date
        keeps the rate it was done under. A date in the future is fine — a raise can be recorded
        before it starts. {name.split(" ")[0]} can see this rate and nobody else&apos;s.
      </p>
      </>
      )}
    </div>
  );
}
