"use client";

import { useActionState, useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { findClients, type Found } from "../search-actions";
import { fileMessageToClient, fileChatFileToClient, type FileState } from "./file-actions";
import { NOTE_CATEGORIES } from "@/lib/report-shape";

const initial: FileState = { error: null, ok: null };

/**
 * "File to client" (owner, 30 Oct 2026).
 *
 * A message or a dropped file onto somebody's record, with the category
 * chosen. The original stays in the thread.
 *
 * The client is searched rather than picked from a list, through the same
 * `search_clients` the Ctrl+K box uses - so what this finds and what the rest
 * of the CRM finds are the same thing, and a thread is not holding the whole
 * caseload in a select.
 *
 * The category is required and has no default. 0266 would fill one in from the
 * client's stage, which is a guess; whoever is filing has the answer in front
 * of them, and 'Personal' narrows the note to Admin and Case Manager.
 */
export function FileToClient({
  messageId,
  fileId,
  label,
}: {
  messageId?: string;
  fileId?: string;
  label?: string;
}) {
  const action = messageId ? fileMessageToClient : fileChatFileToClient;
  const [state, submit, pending] = useActionState(action, initial);
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const [found, setFound] = useState<Found[]>([]);
  const [chosen, setChosen] = useState<Found | null>(null);
  const router = useRouter();

  useEffect(() => {
    if (!open) return;
    let stale = false;
    const timer = window.setTimeout(() => {
      void findClients(query).then((rows) => {
        if (!stale) setFound(rows);
      });
    }, 150);
    return () => {
      stale = true;
      window.clearTimeout(timer);
    };
  }, [open, query]);

  useEffect(() => {
    if (state.ok) {
      setOpen(false);
      setChosen(null);
      setQuery("");
      router.refresh();
    }
  }, [state, router]);

  if (!open) {
    return (
      <button type="button" className="linkish" onClick={() => setOpen(true)}>
        {label ?? "File to client"}
      </button>
    );
  }

  return (
    <div className="card" style={{ marginTop: 6, display: "grid", gap: 8 }}>
      {state.error && <div className="alert bad">{state.error}</div>}

      {!chosen ? (
        <>
          <label className="field" style={{ margin: 0 }}>
            Which client
            <input
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              placeholder="Name or number"
              autoFocus
            />
          </label>
          <div style={{ display: "grid", gap: 4 }}>
            {found.map((c) => (
              <button key={c.id} type="button" className="pane-row" onClick={() => setChosen(c)}>
                <b>{c.name}</b>
                {c.stage && <span className="lock">{c.stage}</span>}
              </button>
            ))}
          </div>
        </>
      ) : (
        <form action={submit} style={{ display: "grid", gap: 8 }}>
          {messageId && <input type="hidden" name="message_id" value={messageId} />}
          {fileId && <input type="hidden" name="file_id" value={fileId} />}
          <input type="hidden" name="client_id" value={chosen.id} />
          <div>
            <b>{chosen.name}</b>{" "}
            <button type="button" className="linkish" onClick={() => setChosen(null)}>
              Somebody else
            </button>
          </div>
          <label className="field" style={{ margin: 0 }}>
            Which service it is about
            <select name="category" defaultValue="" required>
              <option value="" disabled>
                Choose…
              </option>
              {NOTE_CATEGORIES.map((c) => (
                <option key={c}>{c}</option>
              ))}
            </select>
          </label>
          <div className="row2" style={{ gap: 6 }}>
            <button className="btn" type="submit" disabled={pending}>
              {pending ? "Filing…" : "File it"}
            </button>
            <button className="btn ghost" type="button" onClick={() => setOpen(false)}>
              Cancel
            </button>
          </div>
        </form>
      )}

      {!chosen && (
        <button className="btn ghost" type="button" onClick={() => setOpen(false)}>
          Cancel
        </button>
      )}
    </div>
  );
}
