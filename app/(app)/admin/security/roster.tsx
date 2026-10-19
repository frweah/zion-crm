"use client";

import { useActionState } from "react";
import { DataTable, type DataRow } from "../../data-table";
import { clearSecondFactor, setTwoFactorRequired, type SecurityState } from "./actions";

const initial: SecurityState = { error: null, ok: null };

export type RosterRow = {
  staffId: string;
  name: string;
  role: string;
  enrolled: boolean;
  enrolledAt: string | null;
};

export function TwoFactorRoster({ rows, required }: { rows: RosterRow[]; required: boolean }) {
  const [state, action, pending] = useActionState(setTwoFactorRequired, initial);
  const [clearState, clear, clearing] = useActionState(clearSecondFactor, initial);

  const left = rows.filter((r) => !r.enrolled);

  const table: DataRow[] = rows.map((r) => ({
    key: r.staffId,
    text: `${r.name} ${r.role}`,
    sort: { who: r.name, role: r.role, state: r.enrolled ? "1" : "0" },
    cells: {
      who: r.name,
      role: r.role,
      state: r.enrolled ? (
        <span className="sub">
          Set up
          {r.enrolledAt
            ? ` ${new Date(r.enrolledAt).toLocaleDateString("en-US", { month: "short", day: "numeric" })}`
            : ""}
        </span>
      ) : (
        <span className="chip">Not yet</span>
      ),
      action: r.enrolled ? (
        <form action={clear} style={{ display: "inline" }}>
          <input type="hidden" name="staff_id" value={r.staffId} />
          <button className="btn ghost" type="submit" disabled={clearing} style={{ padding: "2px 10px" }}>
            {clearing ? "…" : "Take it off"}
          </button>
        </form>
      ) : null,
    },
  }));

  return (
    <>
      <h2 className="h2">Two-step sign-in</h2>
      <p className="sub">
        {required
          ? "Required. Anybody without one is asked to set it up before they can go on."
          : left.length === 0
            ? "Everybody has one. It can be required now."
            : `Not required yet. ${left.length} of ${rows.length} still to set one up: ${left.map((r) => r.name).join(", ")}.`}
      </p>

      {state.error && <div className="alert bad">{state.error}</div>}
      {state.ok && <div className="alert ok">{state.ok}</div>}
      {clearState.error && <div className="alert bad">{clearState.error}</div>}
      {clearState.ok && <div className="alert ok">{clearState.ok}</div>}

      <form action={action} style={{ marginTop: 10 }}>
        <label className="field" style={{ maxWidth: 420 }}>
          <span className="row2" style={{ gap: 8, alignItems: "center" }}>
            <input type="checkbox" name="required" defaultChecked={required} />
            Require it of everybody
          </span>
        </label>
        <p className="lock" style={{ margin: "6px 0" }}>
          Nobody is locked out: they are walked through setting one up.</p>
        <button className="btn gold" type="submit" disabled={pending}>
          {pending ? "Saving…" : "Save"}
        </button>
      </form>

      <div className="card" style={{ padding: 0, marginTop: 10 }}>
        <DataTable
          label="staff"
          columns={[
            { key: "who", label: "Who" },
            { key: "role", label: "Role" },
            { key: "state", label: "Second factor" },
            { key: "action", label: "", sortable: false },
          ]}
          rows={table}
          empty="Nobody is on the staff list."
        />
      </div>
    </>
  );
}
