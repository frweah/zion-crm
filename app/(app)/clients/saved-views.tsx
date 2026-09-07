"use client";

import { useActionState, useState } from "react";
import { saveView, deleteView, applyView, type ViewState } from "./view-actions";

const initial: ViewState = { error: null, ok: null };

export type SavedView = {
  id: string;
  name: string;
  shared: boolean;
  mine: boolean;
};

export function SavedViews({
  screen,
  views,
  activeId,
  query,
  isAdmin,
  canSave,
}: {
  screen: string;
  views: SavedView[];
  activeId: string | null;
  query: string;
  isAdmin: boolean;
  canSave: boolean;
}) {
  const [saveState, saveAction, saving] = useActionState(saveView, initial);
  const [delState, delAction, deleting] = useActionState(deleteView, initial);
  const [showSave, setShowSave] = useState(false);

  const message = saveState.error ?? delState.error ?? saveState.ok ?? delState.ok;
  const isError = Boolean(saveState.error ?? delState.error);

  return (
    <div style={{ marginBottom: 12 }}>
      {message && <div className={"alert " + (isError ? "bad" : "ok")}>{message}</div>}

      <div className="row2" style={{ alignItems: "center", gap: 8 }}>
        <span className="lock" style={{ marginRight: 2 }}>
          Views:
        </span>

        <form action={applyView} style={{ display: "inline" }}>
          <input type="hidden" name="screen" value={screen} />
          <input type="hidden" name="view_id" value="" />
          <button
            type="submit"
            className={"btn " + (activeId ? "ghost" : "")}
            style={{ padding: "4px 12px" }}
          >
            All
          </button>
        </form>

        {views.map((v) => (
          <span key={v.id} style={{ display: "inline-flex", alignItems: "center", gap: 2 }}>
            <form action={applyView} style={{ display: "inline" }}>
              <input type="hidden" name="screen" value={screen} />
              <input type="hidden" name="view_id" value={v.id} />
              <button
                type="submit"
                className={"btn " + (activeId === v.id ? "" : "ghost")}
                style={{ padding: "4px 12px" }}
                title={v.shared ? "Shared with the team" : "Yours"}
              >
                {v.name}
                {v.shared && (
                  <span style={{ opacity: 0.6, marginLeft: 5, fontSize: 11 }}>team</span>
                )}
              </button>
            </form>
            {(v.mine || (v.shared && isAdmin)) && (
              <form action={delAction} style={{ display: "inline" }}>
                <input type="hidden" name="screen" value={screen} />
                <input type="hidden" name="view_id" value={v.id} />
                <button
                  type="submit"
                  className="btn ghost"
                  disabled={deleting}
                  title={`Remove "${v.name}"`}
                  style={{ padding: "4px 7px", fontSize: 12 }}
                >
                  ×
                </button>
              </form>
            )}
          </span>
        ))}

        {canSave && !showSave && (
          <button
            className="btn ghost"
            style={{ padding: "4px 12px" }}
            onClick={() => setShowSave(true)}
          >
            Save this view
          </button>
        )}
      </div>

      {showSave && (
        <form action={saveAction} className="card" style={{ marginTop: 10 }}>
          <input type="hidden" name="screen" value={screen} />
          <input type="hidden" name="query" value={query} />
          <div className="row2" style={{ alignItems: "center" }}>
            <label className="field" style={{ marginBottom: 0, flex: 2 }}>
              Name this view
              <input name="name" placeholder="e.g. Rei — active" required autoFocus />
            </label>
            {isAdmin && (
              <label style={{ fontSize: 13 }}>
                <input type="checkbox" name="shared" style={{ width: "auto", marginRight: 6 }} />
                Share with the whole team
              </label>
            )}
            <button className="btn gold" type="submit" disabled={saving}>
              {saving ? "Saving…" : "Save"}
            </button>
            <button className="btn ghost" type="button" onClick={() => setShowSave(false)}>
              Cancel
            </button>
          </div>
          <p className="lock" style={{ margin: "8px 0 0" }}>
            Saves the filters and sort you have applied right now.
          </p>
        </form>
      )}
    </div>
  );
}
