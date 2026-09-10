"use client";

import { useActionState } from "react";
import { saveNoteTemplate, type TemplateState } from "./actions";

const initial: TemplateState = { error: null, ok: null };

/**
 * One activity type's headings.
 *
 * Shown as the box people will actually see, at the size they will see it,
 * because the only way to judge whether a set of headings is too long is to
 * look at it as a wall of text.
 */
export function TemplateEditor({
  noteType,
  body,
  active,
  updatedAt,
}: {
  noteType: string;
  body: string;
  active: boolean;
  updatedAt: string | null;
}) {
  const [state, action, pending] = useActionState(saveNoteTemplate, initial);

  return (
    <div className="card" style={{ marginTop: 12 }}>
      <div className="row2" style={{ alignItems: "baseline" }}>
        <h3 style={{ margin: 0 }}>{noteType}</h3>
        {!active && <span className="chip">Off — starts blank</span>}
      </div>

      {state.error && <div className="alert bad">{state.error}</div>}
      {state.ok && <div className="alert ok">{state.ok}</div>}

      <form action={action}>
        <input type="hidden" name="note_type" value={noteType} />
        <textarea
          name="body"
          rows={8}
          defaultValue={active ? body : ""}
          placeholder="Empty — a note of this type starts with a blank box"
          style={{ fontFamily: "inherit" }}
        />
        <div className="row2" style={{ marginTop: 8, alignItems: "center" }}>
          <button className="btn gold" type="submit" disabled={pending}>
            {pending ? "Saving…" : "Save"}
          </button>
          <span className="lock">
            {updatedAt ? `Last changed ${new Date(updatedAt).toLocaleDateString()}` : "Never changed"}
            {" · "}
            Clear the box to switch it off — the wording is kept.
          </span>
        </div>
      </form>
    </div>
  );
}
