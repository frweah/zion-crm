"use client";

import { useActionState } from "react";
import { setChecklistItem, type StaffState } from "./checklist-actions";

const initial: StaffState = { error: null, ok: null };

export type ChecklistRow = {
  staff_id: string;
  task_id: string;
  phase: string;
  label: string;
  detail: string;
  auto_key: string | null;
  auto_done: boolean | null;
  required: boolean;
  done_on: string | null;
  note: string;
};

/**
 * One item on somebody's checklist.
 *
 * An automatic item has no control at all. It is not a disabled checkbox,
 * because a disabled checkbox reads as "you may not tick this" when what is
 * true is "ticking it would mean nothing" — the item is a report on the data,
 * and the way to complete it is to do the thing.
 */
function Item({ row }: { row: ChecklistRow }) {
  const [state, action, pending] = useActionState(setChecklistItem, initial);
  const auto = row.auto_key !== null;
  const done = auto ? row.auto_done === true : row.done_on !== null;

  return (
    <tr>
      <td style={{ width: 28 }}>
        {done ? (
          <span className="chip ok">✓</span>
        ) : row.required ? (
          <span className="chip warn">·</span>
        ) : (
          <span className="chip">·</span>
        )}
      </td>
      <td>
        <div style={{ opacity: done ? 0.65 : 1 }}>
          {row.label}
          {!row.required && <span className="lock"> optional</span>}
        </div>
        {row.detail && <div className="lock">{row.detail}</div>}
        {row.note && <div style={{ fontSize: 12 }}>{row.note}</div>}
        {state.error && <div style={{ color: "var(--bad)", fontSize: 12 }}>{state.error}</div>}
      </td>
      <td style={{ width: 190, textAlign: "right" }}>
        {auto ? (
          <span className="lock">{done ? "done" : "the system is watching this"}</span>
        ) : (
          <form action={action} style={{ display: "inline" }}>
            <input type="hidden" name="staff_id" value={row.staff_id} />
            <input type="hidden" name="task_id" value={row.task_id} />
            <input type="hidden" name="done" value={done ? "" : "on"} />
            <button className="btn ghost" type="submit" disabled={pending}>
              {pending ? "…" : done ? `done ${row.done_on} — undo` : "Mark done"}
            </button>
          </form>
        )}
      </td>
    </tr>
  );
}

export function Checklist({
  name,
  rows,
  phase,
}: {
  name: string;
  rows: ChecklistRow[];
  phase: string;
}) {
  const items = rows.filter((r) => r.phase === phase);
  if (items.length === 0) return null;

  const outstanding = items.filter(
    (r) => r.required && !(r.auto_key ? r.auto_done === true : r.done_on !== null),
  ).length;

  return (
    <details className="card" style={{ marginBottom: 10 }} open={phase === "Onboarding" && outstanding > 0}>
      <summary style={{ cursor: "pointer" }}>
        {phase} — {name}{" "}
        {outstanding === 0 ? (
          <span className="chip ok">complete</span>
        ) : (
          <span className="chip warn">{outstanding} outstanding</span>
        )}
      </summary>
      <table className="t">
        <tbody>
          {items.map((r) => (
            <Item key={r.task_id} row={r} />
          ))}
        </tbody>
      </table>
    </details>
  );
}
