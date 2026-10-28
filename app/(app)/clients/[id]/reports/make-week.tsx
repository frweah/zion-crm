"use client";

import { useActionState } from "react";
import { makeWeek, type ReportState } from "./actions";

const initial: ReportState = { error: null, ok: null };

/** The week the scheduler missed, because the client arrived after Monday. */
export function MakeWeek({ clientId, weekStart }: { clientId: string; weekStart: string }) {
  const [state, action, pending] = useActionState(makeWeek, initial);

  return (
    <form action={action} className="alert" style={{ marginBottom: 14 }}>
      <input type="hidden" name="client_id" value={clientId} />
      <input type="hidden" name="week_start" value={weekStart} />
      <div className="row2" style={{ justifyContent: "space-between", alignItems: "center", gap: 12 }}>
        <span>The week of {weekStart} has no report.</span>
        <button className="btn" disabled={pending}>
          Draft it
        </button>
      </div>
      {state.error && <p className="alert bad" style={{ marginTop: 10 }}>{state.error}</p>}
    </form>
  );
}
