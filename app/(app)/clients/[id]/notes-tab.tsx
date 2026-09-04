"use client";

import { useActionState } from "react";
import { addNote, type DetailState } from "./actions";
import { NOTE_TYPES, fmtStamp } from "@/lib/constants";
import { ROLE_NAMES, ROLE_LABEL, type Role } from "@/lib/roles";

const initial: DetailState = { error: null, ok: null };

export type NoteRow = {
  id: string;
  text: string;
  type: string;
  ts: string;
  at: string;
  staff_name: string;
  visible_roles: string[];
};

export function NotesTab({
  clientId,
  notes,
  myName,
}: {
  clientId: string;
  notes: NoteRow[];
  myName: string;
}) {
  const [state, action, pending] = useActionState(addNote, initial);

  return (
    <>
      <div className="card" style={{ marginBottom: 12 }}>
        {state.error && <div className="alert bad">{state.error}</div>}
        {state.ok && <div className="alert ok">{state.ok}</div>}

        <form action={action}>
          <input type="hidden" name="id" value={clientId} />

          <div className="row2" style={{ marginBottom: 8 }}>
            <label className="field" style={{ maxWidth: 240 }}>
              Activity type
              <select name="type" defaultValue="General">
                {NOTE_TYPES.map((t) => (
                  <option key={t}>{t}</option>
                ))}
              </select>
            </label>
            <span className="lock">Stamped with the time and your name — {myName}</span>
          </div>

          <textarea
            name="text"
            rows={3}
            placeholder="What happened, what was done, what's next"
            required
          />

          <div className="row2" style={{ marginTop: 8, alignItems: "center" }}>
            <span style={{ fontSize: 12, color: "var(--muted)" }}>Visible to:</span>
            {ROLE_NAMES.map((r: Role) => (
              <label key={r} style={{ fontSize: 12 }}>
                <input
                  type="checkbox"
                  name="visible_roles"
                  value={r}
                  style={{ width: "auto", marginRight: 4 }}
                  defaultChecked={r === "Admin" || r === "Job Search"}
                  disabled={r === "Admin"}
                />
                {ROLE_LABEL[r]}
              </label>
            ))}
            <button className="btn gold" type="submit" disabled={pending}>
              {pending ? "Saving…" : "Add note"}
            </button>
          </div>
          <p className="lock" style={{ margin: "8px 0 0" }}>
            Admin always sees every note.
          </p>
        </form>
      </div>

      {notes.length === 0 && <div className="empty">No notes visible to your role yet.</div>}

      {notes.map((n) => (
        <div key={n.id} className="noteitem">
          <div className="meta">
            <b style={{ color: "var(--ink)" }}>{n.ts ? fmtStamp(n.ts) : n.at}</b> ·{" "}
            {n.staff_name || "—"}
            {n.type && n.type !== "General" && (
              <>
                {" "}
                · <span className="chip" style={{ padding: "0 6px" }}>{n.type}</span>
              </>
            )}{" "}
            · visible to{" "}
            {n.visible_roles
              .map((r) => ROLE_LABEL[r as Role] ?? r)
              .join(", ")}
          </div>
          {n.text}
        </div>
      ))}
    </>
  );
}
