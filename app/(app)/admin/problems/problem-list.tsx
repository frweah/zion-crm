"use client";

import { useActionState, useState } from "react";
import { DataTable, type DataRow } from "../../data-table";
import { closeProblem, type ProblemState } from "../../report-problem-actions";

const initial: ProblemState = { error: null, ok: null };

export type ProblemRow = {
  id: string;
  who: string;
  screen: string;
  what: string;
  created_at: string;
  resolved_at: string | null;
  resolved_by: string;
  note: string;
};

/** Closing one, with a note about what was done about it. */
function Close({ id, onDone }: { id: string; onDone: () => void }) {
  const [state, action, pending] = useActionState(closeProblem, initial);
  return (
    <div className="card" style={{ marginTop: 10 }}>
      {state.error && <div className="alert bad">{state.error}</div>}
      <form action={action} className="row2" style={{ alignItems: "flex-end", gap: 8 }}>
        <input type="hidden" name="report_id" value={id} />
        <label className="field" style={{ flex: 2 }}>
          What was done
          <input name="note" placeholder="Fixed, or why it stands" />
        </label>
        <button className="btn gold" type="submit" disabled={pending}>
          {pending ? "…" : "Close it"}
        </button>
        <button className="btn ghost" type="button" onClick={onDone}>
          Leave it open
        </button>
      </form>
    </div>
  );
}

export function ProblemList({ rows }: { rows: ProblemRow[] }) {
  const [closing, setClosing] = useState<string | null>(null);
  const open = rows.filter((r) => !r.resolved_at).length;

  const table: DataRow[] = rows.map((r) => ({
    key: r.id,
    text: `${r.who} ${r.screen} ${r.what} ${r.note}`,
    sort: { when: r.created_at, who: r.who, state: r.resolved_at ?? "" },
    cells: {
      when: new Date(r.created_at).toLocaleDateString("en-US", { month: "short", day: "numeric" }),
      who: r.who,
      screen: r.screen || "—",
      what: (
        <>
          {r.what}
          {r.note && <span className="sub"> · {r.note}</span>}
        </>
      ),
      state: r.resolved_at ? (
        <span className="sub">Closed{r.resolved_by ? ` by ${r.resolved_by}` : ""}</span>
      ) : (
        <button
          className="btn ghost"
          type="button"
          onClick={() => setClosing(r.id)}
          style={{ padding: "2px 10px" }}
        >
          Close
        </button>
      ),
    },
  }));

  return (
    <>
      <h2 className="h2">Problems reported</h2>
      <p className="sub">
        {open === 0
          ? "Nothing open. Staff report these from the avatar menu on any screen."
          : `${open} open. Staff report these from the avatar menu on any screen.`}
      </p>

      {closing && <Close id={closing} onDone={() => setClosing(null)} />}

      <div className="card" style={{ padding: 0, marginTop: 10 }}>
        <DataTable
          label="problem reports"
          columns={[
            { key: "when", label: "When" },
            { key: "who", label: "Who" },
            { key: "screen", label: "Screen" },
            { key: "what", label: "What" },
            { key: "state", label: "" },
          ]}
          rows={table}
          pageSize={25}
          empty="Nobody has reported a problem."
        />
      </div>
    </>
  );
}
