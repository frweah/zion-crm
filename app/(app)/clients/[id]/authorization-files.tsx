"use client";

import { useActionState, useState } from "react";
import { getDownloadUrl, type FileState } from "./files/actions";
import { linkAuthorizationFile, type LinkState } from "./authorization-files-actions";

export type AuthFile = {
  id: string;
  storage_path: string;
  filename: string;
  category: string;
  auth_id: string | null;
  created_at: string;
};

export type AvailableFile = AuthFile & {
  /** The inbox read this file and found this authorization's number in it. */
  suggested: boolean;
  /** Dates read off it, if any, to start the form with. */
  start: string;
  end: string;
};

const openInitial: FileState = { error: null, ok: null };
const linkInitial: LinkState = { error: null, ok: null };

function OpenFile({ file }: { file: AuthFile }) {
  const [state, action, opening] = useActionState(getDownloadUrl, openInitial);

  // The signed link is short-lived, so it is opened as soon as it arrives.
  if (state.url) {
    window.open(state.url, "_blank", "noopener");
    state.url = undefined;
  }

  return (
    <form action={action} style={{ display: "inline" }}>
      <input type="hidden" name="storage_path" value={file.storage_path} />
      <button className="btn ghost" type="submit" disabled={opening}>
        {opening ? "…" : "Open"}
      </button>
      {state.error && <span style={{ color: "var(--bad)", fontSize: 12 }}> {state.error}</span>}
    </form>
  );
}

/**
 * The PDFs for one authorization, and a way to attach one.
 *
 * Files the inbox found this authorization's number in are offered first and
 * start the form with the dates read off them. Everything else on the
 * client's record is still offered, because 8 of the first 14 authorizations
 * filed were scans with no text to find a number in.
 */
export function AuthorizationFiles({
  clientId,
  authId,
  authNumber,
  linked,
  available,
  canConfirm,
}: {
  clientId: string;
  authId: string;
  authNumber: string;
  linked: AuthFile[];
  available: AvailableFile[];
  canConfirm: boolean;
}) {
  const ordered = [...available].sort(
    (x, y) =>
      Number(y.suggested) - Number(x.suggested) ||
      Number(y.category === "Authorization") - Number(x.category === "Authorization"),
  );
  const suggestedCount = ordered.filter((f) => f.suggested).length;
  const first = ordered.find((f) => f.suggested);

  const [open, setOpen] = useState(false);
  const [picked, setPicked] = useState(first?.id ?? "");
  const [start, setStart] = useState(first?.start ?? "");
  const [end, setEnd] = useState(first?.end ?? "");
  const [state, action, linking] = useActionState(linkAuthorizationFile, linkInitial);

  function choose(id: string) {
    setPicked(id);
    const f = ordered.find((x) => x.id === id);
    setStart(f?.start ?? "");
    setEnd(f?.end ?? "");
  }

  return (
    <div style={{ marginTop: 8, paddingTop: 8, borderTop: "1px solid var(--line)" }}>
      {linked.length === 0 ? (
        <div className="lock">
          No PDF attached
          {suggestedCount > 0 &&
            ` — ${suggestedCount} file${suggestedCount === 1 ? "" : "s"} on record name${suggestedCount === 1 ? "s" : ""} ${authNumber}`}
          .
        </div>
      ) : (
        linked.map((f) => (
          <div key={f.id} className="row2" style={{ alignItems: "center", gap: 6 }}>
            <b style={{ fontSize: 13 }}>{f.filename}</b>
            <span className="chip">{f.category}</span>
            <OpenFile file={f} />
          </div>
        ))
      )}

      {state.error && <div className="alert bad" style={{ marginTop: 6 }}>{state.error}</div>}
      {state.ok && <div className="alert ok" style={{ marginTop: 6 }}>{state.ok}</div>}

      {canConfirm && ordered.length > 0 && !open && (
        <button
          className={"btn " + (suggestedCount > 0 && linked.length === 0 ? "gold" : "ghost")}
          type="button"
          style={{ marginTop: 6 }}
          onClick={() => setOpen(true)}
        >
          {suggestedCount > 0 ? "Attach the PDF that names it" : "Attach a PDF on file"}
        </button>
      )}

      {canConfirm && open && (
        <form action={action} style={{ marginTop: 8 }}>
          <input type="hidden" name="client_id" value={clientId} />
          <input type="hidden" name="auth_id" value={authId} />

          <label className="field">
            File
            <select name="attachment_id" value={picked} onChange={(e) => choose(e.target.value)}>
              <option value="">Choose a file on this client&rsquo;s record…</option>
              {ordered.map((f) => (
                <option key={f.id} value={f.id}>
                  {f.suggested ? `Names ${authNumber} · ` : ""}
                  {f.filename} ({f.category})
                </option>
              ))}
            </select>
          </label>

          <div className="row2">
            <label className="field" style={{ maxWidth: 190 }}>
              Start date
              <input type="date" name="start_date" value={start} onChange={(e) => setStart(e.target.value)} />
            </label>
            <label className="field" style={{ maxWidth: 190 }}>
              End date
              <input type="date" name="end_date" value={end} onChange={(e) => setEnd(e.target.value)} />
            </label>
          </div>

          <p className="lock" style={{ margin: "0 0 8px" }}>
            Dates fill blanks only. A date already on this authorization is kept, and a different one
            here is reported instead of applied.
          </p>

          <button className="btn gold" type="submit" disabled={linking || !picked}>
            {linking ? "…" : "Attach"}
          </button>{" "}
          <button className="btn ghost" type="button" onClick={() => setOpen(false)}>
            Cancel
          </button>
        </form>
      )}
    </div>
  );
}
