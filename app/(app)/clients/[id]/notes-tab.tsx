"use client";

import { useActionState, useEffect, useRef, useState } from "react";
import { addNote, type DetailState } from "./actions";
import { NOTE_TYPES, fmtStamp } from "@/lib/constants";
import { ROLE_NAMES, ROLE_LABEL, type Role } from "@/lib/roles";
import { onTypeChange } from "@/lib/note-template";

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
  templates,
}: {
  clientId: string;
  notes: NoteRow[];
  myName: string;
  /** The skeleton each activity type starts with. A type with none is blank. */
  templates: Record<string, string>;
}) {
  const [state, action, pending] = useActionState(addNote, initial);

  const [type, setType] = useState("General");
  const [text, setText] = useState("");
  // The skeleton last written into the box, so "has this been touched?" is a
  // comparison rather than a guess. Null the moment they type.
  const [applied, setApplied] = useState<string | null>(null);
  // Set when a type changed but the box already held somebody's writing.
  const [offer, setOffer] = useState("");

  const box = useRef<HTMLTextAreaElement>(null);

  // A saved note leaves an empty box, not the skeleton of whatever was just
  // written — otherwise the next note looks half-written before it is begun.
  useEffect(() => {
    if (state.ok) {
      setText("");
      setApplied(null);
      setOffer("");
    }
  }, [state.ok]);

  function chooseType(next: string) {
    setType(next);
    const result = onTypeChange(text, applied, templates[next] ?? "");

    if (result.action === "keep") {
      setOffer(result.offer);
      return;
    }
    setOffer("");
    setText(result.body);
    setApplied(result.applied);
    // Land the cursor after the first heading rather than at the top, so the
    // first thing typed is an answer.
    queueMicrotask(() => {
      const el = box.current;
      if (!el) return;
      const at = result.body.indexOf("\n");
      el.focus();
      el.setSelectionRange(at < 0 ? el.value.length : at + 1, at < 0 ? el.value.length : at + 1);
    });
  }

  function useHeadings() {
    setText(offer);
    setApplied(offer);
    setOffer("");
    box.current?.focus();
  }

  const hasTemplate = Boolean(templates[type]);

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
              <select name="type" value={type} onChange={(e) => chooseType(e.target.value)}>
                {NOTE_TYPES.map((t) => (
                  <option key={t}>{t}</option>
                ))}
              </select>
            </label>
            <span className="lock">Stamped with the time and your name — {myName}</span>
          </div>

          {offer && (
            <div className="alert" style={{ marginBottom: 8 }}>
              You have already written something, so it has been left alone.{" "}
              <button type="button" className="btn" onClick={useHeadings}>
                Replace it with the {type.toLowerCase()} headings
              </button>
            </div>
          )}

          <textarea
            ref={box}
            name="text"
            rows={hasTemplate ? 10 : 3}
            value={text}
            onChange={(e) => {
              setText(e.target.value);
              // From here on the text is theirs, whatever it started as.
              if (applied !== null && e.target.value !== applied) setApplied(null);
            }}
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
            {hasTemplate && " The headings are a starting point — change or delete any of them."}
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
