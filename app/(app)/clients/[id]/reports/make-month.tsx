"use client";

import { useActionState } from "react";
import { makeMonth, type MonthState } from "./month-actions";

const initial: MonthState = { error: null, ok: null };

const title = (iso: string) =>
  new Date(`${iso}T12:00:00Z`).toLocaleDateString("en-US", { month: "long", year: "numeric" });

/** The month the scheduler missed, because the client arrived after the 1st. */
export function MakeMonth({ clientId, month }: { clientId: string; month: string }) {
  const [state, action, pending] = useActionState(makeMonth, initial);

  return (
    <form action={action} className="alert" style={{ marginBottom: 14 }}>
      <input type="hidden" name="client_id" value={clientId} />
      <input type="hidden" name="month" value={month} />
      <div className="row2" style={{ justifyContent: "space-between", alignItems: "center", gap: 12 }}>
        <span>{title(month)} has no report.</span>
        <button className="btn" disabled={pending}>
          Assemble it
        </button>
      </div>
      {state.error && <p className="alert bad" style={{ marginTop: 10 }}>{state.error}</p>}
    </form>
  );
}
