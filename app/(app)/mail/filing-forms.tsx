"use client";

import { useActionState, useEffect, useMemo, useRef, useState } from "react";
import {
  fileMessageOnClient,
  keepAttachment,
  restrictMailThread,
  unfileMessage,
  type SendState,
} from "./actions";

const initial: SendState = { error: null, ok: null };

export type FilingTarget = { id: string; name: string; client_no: number | null; stage: string };

/** What a dragged row carries: which message. */
const DRAG_TYPE = "application/x-zion-message";

/**
 * A message that can be dragged onto a client.
 *
 * No `draggable` attribute: the row is a link and a link already drags. All
 * this does is put the message's id on the drag alongside the link's own url,
 * so the client list knows what was dropped on it.
 */
export function DragSource({ id, children }: { id: string; children: React.ReactNode }) {
  return (
    <span
      style={{ display: "block" }}
      onDragStart={(e) => {
        e.dataTransfer.setData(DRAG_TYPE, id);
      }}
    >
      {children}
    </span>
  );
}

/**
 * Filing a message on a client (owner, 23 Oct 2026).
 *
 * Two ways to the same place, because dragging is quick when the client is in
 * front of you and impossible when they are not: drag a message onto a name,
 * or open it and press the name. Both file by hand, under the name of whoever
 * did it.
 *
 * Nothing in the mailbox is stored until one of them happens. That is the
 * whole rule, and it is why the list below is of clients rather than of
 * messages - the CRM has nothing to say about a message nobody has filed.
 */
export function FileToClient({
  clients,
  box,
  selected,
  selectedSubject,
}: {
  clients: FilingTarget[];
  box: string;
  selected: string | null;
  selectedSubject: string;
}) {
  const [state, action, pending] = useActionState(fileMessageOnClient, initial);
  const [find, setFind] = useState("");
  const [over, setOver] = useState<string | null>(null);
  const [whole, setWhole] = useState(true);
  const [dropped, setDropped] = useState<{ client: string; message: string } | null>(null);
  const form = useRef<HTMLFormElement>(null);

  const shown = useMemo(() => {
    const q = find.trim().toLowerCase();
    const matching = q
      ? clients.filter((c) => c.name.toLowerCase().includes(q) || String(c.client_no ?? "").includes(q))
      : clients;
    return matching.slice(0, 60);
  }, [clients, find]);

  // A drop and a press are the same act, so they go through the same form:
  // the drop fills it in and submits it rather than having a path of its own.
  useEffect(() => {
    if (dropped) form.current?.requestSubmit();
  }, [dropped]);

  const messageId = dropped?.message ?? selected ?? "";

  return (
    <section className="card" aria-label="File to client">
      <h2 className="h2" style={{ marginBottom: 6 }}>
        File to client
      </h2>
      {state.error && <div className="alert bad">{state.error}</div>}
      {state.ok && <div className="alert ok">{state.ok}</div>}

      <p className="lock" style={{ margin: "0 0 10px" }}>
        {selected ? `Drag onto a name, or pick one for “${selectedSubject}”` : "Drag a message onto a name"}
      </p>

      <form ref={form} action={action}>
        <input type="hidden" name="box" value={box} />
        <input type="hidden" name="message_id" value={messageId} />
        <input type="hidden" name="client_id" value={dropped?.client ?? ""} />
        <input type="hidden" name="thread" value={whole ? "yes" : "no"} />
      </form>

      <label className="row2" style={{ gap: 8, alignItems: "baseline", marginBottom: 10 }}>
        <input type="checkbox" checked={whole} onChange={(e) => setWhole(e.target.checked)} />
        <span>The whole thread</span>
      </label>

      <label className="field">
        Find a client
        <input
          id="file-find"
          type="search"
          value={find}
          onChange={(e) => setFind(e.target.value)}
          placeholder="Name or number"
          autoComplete="off"
        />
      </label>

      <div className="file-targets">
        {shown.length === 0 ? (
          <p className="empty" style={{ margin: 0 }}>
            Nobody matches “{find}”.
          </p>
        ) : (
          shown.map((c) => (
            <button
              key={c.id}
              type="button"
              className={"file-target" + (over === c.id ? " over" : "")}
              disabled={pending}
              onDragOver={(e) => {
                if (e.dataTransfer.types.includes(DRAG_TYPE)) {
                  e.preventDefault();
                  setOver(c.id);
                }
              }}
              onDragLeave={() => setOver((o) => (o === c.id ? null : o))}
              onDrop={(e) => {
                e.preventDefault();
                setOver(null);
                const id = e.dataTransfer.getData(DRAG_TYPE);
                if (id) setDropped({ client: c.id, message: id });
              }}
              onClick={() => {
                if (messageId) setDropped({ client: c.id, message: messageId });
              }}
            >
              <span>
                <b>{c.name}</b>
                {c.client_no ? <span className="lock"> #{c.client_no}</span> : null}
              </span>
              <span className="lock">{c.stage}</span>
            </button>
          ))
        )}
      </div>
    </section>
  );
}

/**
 * Take a filed message off a client, with a reason.
 *
 * The reason is required and the control says what will happen to the
 * mailbox, because the fear somebody has when they press this is that they
 * are deleting an email. They are not: the message stays where it is and
 * stops being part of the client's record.
 */
export function Unfile({
  mailId,
  clientId,
  clientName,
}: {
  mailId: string;
  clientId: string;
  clientName: string;
}) {
  const [open, setOpen] = useState(false);
  const [state, action, pending] = useActionState(unfileMessage, initial);

  if (state.ok) return <span className="chip">{state.ok}</span>;
  if (!open) {
    return (
      <button type="button" className="btn ghost" onClick={() => setOpen(true)}>
        Take off {clientName}
      </button>
    );
  }
  return (
    <form action={action} className="row2" style={{ gap: 6, flexWrap: "wrap", alignItems: "flex-end" }}>
      <input type="hidden" name="mail_id" value={mailId} />
      <input type="hidden" name="client_id" value={clientId} />
      <label className="field" style={{ margin: 0, minWidth: 220 }}>
        Why it is coming off
        <input id={`unfile-${mailId}`} name="reason" required autoComplete="off" />
      </label>
      <button className="btn danger" type="submit" disabled={pending}>
        {pending ? "Taking it off…" : "Take it off"}
      </button>
      <button type="button" className="btn ghost" onClick={() => setOpen(false)}>
        Leave it
      </button>
      {state.error && <span style={{ color: "var(--bad)", fontSize: "var(--text-sm)" }}>{state.error}</span>}
    </form>
  );
}

/** Keep an attachment from a filed message on the client's record. */
export function KeepAttachment({
  messageId,
  attachmentId,
  name,
  clientId,
  box,
  categories,
}: {
  messageId: string;
  attachmentId: string;
  name: string;
  clientId: string;
  box: string;
  categories: string[];
}) {
  const [open, setOpen] = useState(false);
  const [state, action, pending] = useActionState(keepAttachment, initial);

  if (state.ok) return <span className="chip ok">{state.ok}</span>;
  if (!open) {
    return (
      <button type="button" className="btn ghost" onClick={() => setOpen(true)}>
        Keep on the record
      </button>
    );
  }
  return (
    <form action={action} className="row2" style={{ gap: 6, flexWrap: "wrap", alignItems: "flex-end" }}>
      <input type="hidden" name="message_id" value={messageId} />
      <input type="hidden" name="attachment_id" value={attachmentId} />
      <input type="hidden" name="client_id" value={clientId} />
      <input type="hidden" name="box" value={box} />
      <label className="field" style={{ margin: 0 }}>
        What {name} is
        <select id={`keep-${attachmentId}`} name="category" defaultValue="Other">
          {categories.map((c) => (
            <option key={c} value={c}>
              {c}
            </option>
          ))}
        </select>
      </label>
      <label className="row2" style={{ gap: 6, alignItems: "baseline" }}>
        <input type="checkbox" name="restricted" />
        <span>Restricted</span>
      </label>
      <button className="btn gold" type="submit" disabled={pending}>
        {pending ? "Keeping…" : "Keep it"}
      </button>
      <button type="button" className="btn ghost" onClick={() => setOpen(false)}>
        Cancel
      </button>
      {state.error && <span style={{ color: "var(--bad)", fontSize: "var(--text-sm)" }}>{state.error}</span>}
    </form>
  );
}

/**
 * Restrict a thread, or let it back out.
 *
 * The same rule as a restricted document, because it is the same decision
 * about the same person - the database asks `can_staff_see_restricted` and
 * this screen does not keep a second copy of the answer.
 */
export function RestrictThread({
  conversation,
  clientId,
  restricted,
}: {
  conversation: string;
  clientId: string;
  restricted: boolean;
}) {
  const [state, action, pending] = useActionState(restrictMailThread, initial);
  return (
    <form action={action} style={{ display: "inline-flex", gap: 6, alignItems: "center" }}>
      <input type="hidden" name="conversation" value={conversation} />
      <input type="hidden" name="client_id" value={clientId} />
      <input type="hidden" name="restricted" value={restricted ? "no" : "yes"} />
      <button className="btn ghost" type="submit" disabled={pending}>
        {pending ? "Changing…" : restricted ? "No longer restricted" : "Restrict"}
      </button>
      {state.error && <span style={{ color: "var(--bad)", fontSize: "var(--text-sm)" }}>{state.error}</span>}
    </form>
  );
}
