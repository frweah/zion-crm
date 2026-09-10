"use client";

import { useActionState } from "react";
import { logRequest, type RequestState } from "./actions";

const initial: RequestState = { error: null, ok: null };

export function RequestForm({
  clients,
  today,
}: {
  clients: { id: string; name: string }[];
  today: string;
}) {
  const [state, action, pending] = useActionState(logRequest, initial);

  return (
    <div className="card" style={{ marginTop: 14 }}>
      <h3 style={{ marginTop: 0 }}>Somebody has asked for a record</h3>

      {state.error && <div className="alert bad">{state.error}</div>}
      {state.ok && <div className="alert ok">{state.ok}</div>}

      <form action={action}>
        <div className="row2" style={{ alignItems: "flex-end" }}>
          <label className="field" style={{ flex: 2 }}>
            Whose record
            <select name="client_id" defaultValue="">
              <option value="">Choose a client…</option>
              {clients.map((c) => (
                <option key={c.id} value={c.id}>
                  {c.name}
                </option>
              ))}
            </select>
          </label>
          <label className="field" style={{ flex: 2 }}>
            Who asked
            <input name="requested_by" placeholder="The client · an attorney, by name · USOR audit" />
          </label>
          <label className="field" style={{ maxWidth: 170 }}>
            When they asked
            <input name="requested_on" type="date" defaultValue={today} />
          </label>
        </div>
        <label className="field">
          Anything worth noting
          <input name="note" placeholder="Asked for everything since 2024 · wants it by post" />
        </label>
        <button className="btn gold" disabled={pending}>
          {pending ? "Saving…" : "Log the request"}
        </button>
      </form>
    </div>
  );
}
