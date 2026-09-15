"use client";

import { useActionState } from "react";
import { setChecklistItem, type StaffState } from "./checklist-actions";
import { DataTable } from "../../data-table";

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

const isDone = (row: ChecklistRow) => (row.auto_key !== null ? row.auto_done === true : row.done_on !== null);

/**
 * What can be done to one item on somebody's checklist.
 *
 * An automatic item has no control at all. It is not a disabled checkbox,
 * because a disabled checkbox reads as "you may not tick this" when what is
 * true is "ticking it would mean nothing" — the item is a report on the data,
 * and the way to complete it is to do the thing.
 */
function ItemControl({ row }: { row: ChecklistRow }) {
  const [state, action, pending] = useActionState(setChecklistItem, initial);
  const done = isDone(row);

  if (row.auto_key !== null) {
    return <span className="lock">{done ? "done" : "the system is watching this"}</span>;
  }

  return (
    <form action={action} style={{ display: "inline" }}>
      <input type="hidden" name="staff_id" value={row.staff_id} />
      <input type="hidden" name="task_id" value={row.task_id} />
      <input type="hidden" name="done" value={done ? "" : "on"} />
      <button className="btn ghost" type="submit" disabled={pending}>
        {pending ? "…" : done ? `done ${row.done_on} — undo` : "Mark done"}
      </button>
      {state.error && <div style={{ color: "var(--bad)", fontSize: 12 }}>{state.error}</div>}
    </form>
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

  const outstanding = items.filter((r) => r.required && !isDone(r)).length;

  return (
    <div className="card" style={{ padding: 0, marginBottom: 10 }}>
      <p style={{ margin: 0, padding: "12px 14px" }}>
        {phase} — {name}{" "}
        {outstanding === 0 ? (
          <span className="chip ok">complete</span>
        ) : (
          <span className="chip warn">{outstanding} outstanding</span>
        )}
      </p>
      <DataTable
        label={`${phase.toLowerCase()} items`}
        columns={[
          { key: "state", label: "", sortable: false, width: 28 },
          { key: "item", label: "Item" },
          { key: "action", label: "", sortable: false, width: 190, align: "right" },
        ]}
        rows={items.map((r) => {
          const done = isDone(r);
          return {
            key: r.task_id,
            text: `${r.label} ${r.detail} ${r.note}`,
            sort: { item: r.label },
            cells: {
              state: done ? (
                <span className="chip ok">✓</span>
              ) : r.required ? (
                <span className="chip warn">·</span>
              ) : (
                <span className="chip">·</span>
              ),
              item: (
                <>
                  <div style={{ opacity: done ? 0.65 : 1 }}>
                    {r.label}
                    {!r.required && <span className="lock"> optional</span>}
                  </div>
                  {r.detail && <div className="lock">{r.detail}</div>}
                  {r.note && <div style={{ fontSize: 12 }}>{r.note}</div>}
                </>
              ),
              action: <ItemControl row={r} />,
            },
          };
        })}
        empty={`There is nothing on ${name}'s ${phase.toLowerCase()} checklist.`}
      />
    </div>
  );
}
