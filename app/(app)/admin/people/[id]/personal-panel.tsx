"use client";

import { useActionState } from "react";
import { revealPersonalDetails, type RevealState } from "./personal-actions";

const initial: RevealState = { error: null, details: null };

/** Closed until asked for; asking is what the access log records. */
export function PersonalDetailsPanel({ staffId, onFile }: { staffId: string; onFile: boolean }) {
  const [state, action, pending] = useActionState(revealPersonalDetails, initial);

  if (!onFile) return <p className="empty">No personal details are on file yet.</p>;

  if (!state.details) {
    return (
      <form action={action}>
        <input type="hidden" name="staff_id" value={staffId} />
        {state.error && <div className="alert bad">{state.error}</div>}
        <button className="btn ghost" type="submit" disabled={pending}>
          {pending ? "Opening…" : "Show personal details"}
        </button>
        <span className="lock" style={{ marginLeft: 8 }}>
          Legal name, address, date of birth, emergency contact. Opening them is recorded in the access log.
        </span>
      </form>
    );
  }

  const d = state.details;
  const rows: [string, string][] = [
    ["Legal name", d.legal_name],
    ["Address", d.address],
    ["Phone", d.phone],
    ["Date of birth", d.date_of_birth ?? ""],
    ["Emergency contact", d.emergency],
  ];
  return (
    <div className="grid" style={{ gridTemplateColumns: "max-content 1fr", gap: "6px 16px" }}>
      {rows.map(([k, v]) => (
        <div key={k} style={{ display: "contents" }}>
          <span className="lock">{k}</span>
          <span>{v || "—"}</span>
        </div>
      ))}
    </div>
  );
}
