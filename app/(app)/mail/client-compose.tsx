"use client";

import { useActionState, useState } from "react";
import { sendClientMessage, type SendState } from "./actions";
import type { AttachableDocument, Recipient } from "@/lib/mail-filing";

const initial: SendState = { error: null, ok: null };

export type FilledTemplate = { key: string; label: string; subject: string; body: string };

const size = (bytes: number | null) =>
  !bytes ? "" : bytes < 1024 * 1024 ? `${Math.max(1, Math.round(bytes / 1024))} KB` : `${(bytes / 1024 / 1024).toFixed(1)} MB`;

/**
 * A message about a client, written from their record.
 *
 * The recipients are picked, not typed: everybody this client's mail can
 * reasonably go to is on the record already, and an address typed into a box
 * is the one way a client's business reaches the wrong person. Anybody else
 * goes in Cc by hand, and the client themselves can only be reached at the
 * address on their own record - which the send checks rather than trusting
 * this screen.
 *
 * A template fills the subject and the message with the facts already merged
 * in. They are rendered on the server when the screen opens, so choosing one
 * is instant and nothing is fetched twice.
 */
export function ClientComposeForm({
  clientId,
  clientName,
  recipients,
  documents,
  templates,
  from,
  canSend,
  defaultTo,
}: {
  clientId: string;
  clientName: string;
  recipients: Recipient[];
  documents: AttachableDocument[];
  templates: FilledTemplate[];
  from: string;
  canSend: boolean;
  defaultTo: string[];
}) {
  const [state, action, pending] = useActionState(sendClientMessage, initial);
  const [subject, setSubject] = useState("");
  const [text, setText] = useState("");
  const [template, setTemplate] = useState("");

  const choose = (key: string) => {
    setTemplate(key);
    const picked = templates.find((t) => t.key === key);
    if (picked) {
      setSubject(picked.subject);
      setText(picked.body);
    }
  };

  return (
    <form action={action} className="card">
      {state.error && <div className="alert bad">{state.error}</div>}
      {state.ok && <div className="alert ok">{state.ok}</div>}
      <input type="hidden" name="client_id" value={clientId} />

      <p className="lock" style={{ margin: "0 0 10px" }}>
        From <b>{from}</b>, filed on {clientName} when it goes
      </p>

      {recipients.length === 0 ? (
        <p className="empty">
          {clientName} has nobody on their record to write to — add a counselor or an address first.
        </p>
      ) : (
        <fieldset className="field" style={{ border: 0, padding: 0, margin: "0 0 12px" }}>
          <legend className="label">To</legend>
          {recipients.map((r) => (
            <label key={r.address} className="row2" style={{ gap: 8, alignItems: "baseline" }}>
              <input
                type="checkbox"
                name="to"
                value={r.address}
                defaultChecked={defaultTo.includes(r.address.toLowerCase())}
              />
              <span>
                {r.label} <span className="lock">{r.address}</span>
              </span>
            </label>
          ))}
        </fieldset>
      )}

      <label className="field">
        Cc
        <input id="mail-cc" name="cc" autoComplete="off" placeholder="Anybody else, separated by commas" />
      </label>

      {templates.length > 0 && (
        <label className="field">
          Template
          <select id="mail-template" value={template} onChange={(e) => choose(e.target.value)}>
            <option value="">None</option>
            {templates.map((t) => (
              <option key={t.key} value={t.key}>
                {t.label}
              </option>
            ))}
          </select>
        </label>
      )}

      <label className="field">
        Subject
        <input
          id="mail-subject"
          name="subject"
          value={subject}
          onChange={(e) => setSubject(e.target.value)}
          required
        />
      </label>

      <label className="field">
        Message
        <textarea id="mail-text" name="text" rows={14} value={text} onChange={(e) => setText(e.target.value)} required />
      </label>

      {documents.length > 0 && (
        <fieldset className="field" style={{ border: 0, padding: 0, margin: "0 0 12px" }}>
          <legend className="label">Attach from the record</legend>
          <div className="scroll-list">
            {documents.map((d) => (
              <label key={d.id} className="row2" style={{ gap: 8, alignItems: "baseline" }}>
                <input type="checkbox" name="doc" value={d.id} />
                <span>
                  {d.filename}{" "}
                  <span className="lock">
                    {d.category}
                    {d.document_date ? ` · ${d.document_date}` : ""}
                    {d.size_bytes ? ` · ${size(d.size_bytes)}` : ""}
                  </span>
                  {d.restricted && <span className="chip warn"> Restricted</span>}
                </span>
              </label>
            ))}
          </div>
        </fieldset>
      )}

      <button className="btn gold" type="submit" disabled={pending || !canSend || Boolean(state.ok)}>
        {pending ? "Sending…" : state.ok ? "Sent" : "Send"}
      </button>
    </form>
  );
}
