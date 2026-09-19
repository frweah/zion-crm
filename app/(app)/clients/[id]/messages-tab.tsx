"use client";

import { useActionState, useEffect, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import { sendText, cancelScheduledText, saveTemplate, type TextState } from "./text-actions";
import { markRead } from "../../messages/actions";

const initial: TextState = { error: null, ok: null };

export type Template = { id: string; label: string; body: string };
export type ThreadMessage = {
  id: string;
  seq: number;
  sender_kind: string;
  sender_label: string;
  body: string;
  status: string;
  created_at: string;
};
export type Scheduled = { id: string; body: string; send_after: string | null };

/**
 * The client's texts (Messaging brief, A), on a phone first: one thread, the
 * replies and what the system did, and a box to answer from. Whether a text
 * may go at all is the database's call - this only says why not.
 */
export function TextThread({
  clientId,
  clientName,
  conversationId,
  messages,
  scheduled,
  templates,
  canText,
  consentState,
  phone,
  canSend,
  insideHours,
  nextWindow,
}: {
  clientId: string;
  clientName: string;
  conversationId: string | null;
  messages: ThreadMessage[];
  scheduled: Scheduled[];
  templates: Template[];
  canText: boolean;
  consentState: string | null;
  phone: string;
  canSend: boolean;
  insideHours: boolean;
  nextWindow: string;
}) {
  const router = useRouter();
  const [state, action, pending] = useActionState(sendText, initial);
  const [cancelState, cancelAction] = useActionState(cancelScheduledText, initial);
  const [body, setBody] = useState("");
  const [addingTemplate, setAddingTemplate] = useState(false);
  const form = useRef<HTMLFormElement>(null);
  const first = clientName.split(" ")[0] ?? "";

  useEffect(() => {
    if (state.ok) {
      setBody("");
      form.current?.reset();
    }
  }, [state]);

  // A reply arriving redraws the thread (the foundation's live delivery).
  useEffect(() => {
    const onMessage = (e: Event) => {
      const row = (e as CustomEvent<{ conversation_id: string }>).detail;
      if (conversationId && row.conversation_id === conversationId) router.refresh();
    };
    window.addEventListener("zion:message", onMessage);
    return () => window.removeEventListener("zion:message", onMessage);
  }, [conversationId, router]);

  useEffect(() => {
    if (conversationId && messages.length > 0) void markRead(conversationId, Number(messages[messages.length - 1].seq));
  }, [conversationId, messages]);

  return (
    <div className="texting">
      <div className="row2" style={{ justifyContent: "space-between", alignItems: "center" }}>
        <p className="sub" style={{ margin: 0 }}>
          {phone ? `Texting ${phone}` : "No number on this record"} ·{" "}
          {canText ? (
            <span className="chip ok">Agreed to be texted</span>
          ) : (
            <span className="chip bad">{consentState === "Withdrawn" ? "Replied STOP" : "No consent on file"}</span>
          )}
        </p>
        <Link className="lock" href={`/clients/${clientId}?tab=profile#texting`}>
          Consent
        </Link>
      </div>

      <ol className="thread-list texts" aria-label={`Texts with ${clientName}`}>
        {messages.length === 0 && <li className="empty">Nothing texted yet.</li>}
        {messages.map((m) => (
          <li
            key={m.id}
            className={
              "bubble " +
              (m.sender_kind === "client" ? "" : m.sender_kind === "system" ? "system" : "mine") +
              (m.status === "failed" ? " failed" : "")
            }
          >
            <div className="lock">
              {m.sender_kind === "client"
                ? first || "Them"
                : m.sender_kind === "system"
                  ? m.sender_label || "System"
                  : m.sender_label || "You"}{" "}
              · {new Date(m.created_at).toLocaleString("en-US", { timeZone: "America/Denver", month: "short", day: "numeric", hour: "numeric", minute: "2-digit" })}
              {m.status === "failed" && " · not delivered"}
              {m.status === "queued" && " · sending"}
            </div>
            <div className="bubble-text">{m.body}</div>
          </li>
        ))}
      </ol>

      {scheduled.length > 0 && (
        <div className="alert" style={{ marginTop: 10 }}>
          {scheduled.map((s) => (
            <form key={s.id} action={cancelAction} className="row2" style={{ gap: 8, alignItems: "center" }}>
              <input type="hidden" name="text_id" value={s.id} />
              <input type="hidden" name="client_id" value={clientId} />
              <span style={{ flex: 1 }}>
                Waiting for{" "}
                {s.send_after
                  ? new Date(s.send_after).toLocaleString("en-US", { timeZone: "America/Denver", weekday: "short", hour: "numeric", minute: "2-digit" })
                  : "the next window"}
                : “{s.body}”
              </span>
              <button className="btn ghost" type="submit" style={{ padding: "2px 10px" }}>
                Do not send
              </button>
            </form>
          ))}
          {cancelState.error && <div style={{ color: "var(--bad)" }}>{cancelState.error}</div>}
        </div>
      )}

      {!canSend ? (
        <p className="lock" style={{ marginTop: 10 }}>
          Your role does not send texts.
        </p>
      ) : !canText ? (
        <p className="lock" style={{ marginTop: 10 }}>
          Nothing can be sent until {first || "this client"} has agreed to be texted at the number on their record.
          Record it under <Link href={`/clients/${clientId}?tab=profile#texting`}>Consent</Link>.
        </p>
      ) : (
        <>
          {templates.length > 0 && (
            <div className="row2 templates" style={{ gap: 6, marginTop: 10 }}>
              {templates.map((t) => (
                <button
                  key={t.id}
                  type="button"
                  className="btn ghost"
                  style={{ padding: "2px 10px" }}
                  onClick={() => setBody(t.body.replaceAll("{first}", first))}
                >
                  {t.label}
                </button>
              ))}
            </div>
          )}

          <form ref={form} action={action} className="composer" style={{ marginTop: 8 }}>
            {state.error && <div className="alert bad">{state.error}</div>}
            {state.ok && <div className="alert ok">{state.ok}</div>}
            <input type="hidden" name="client_id" value={clientId} />
            <label className="field" style={{ margin: 0, flex: 1 }}>
              <span className="sr-only">Text to send</span>
              <textarea
                id="text-body"
                name="body"
                rows={3}
                required
                maxLength={600}
                value={body}
                onChange={(e) => setBody(e.target.value)}
                placeholder={insideHours ? "Write a text" : "Texts go out 8am to 9pm"}
              />
              <span className="lock">{600 - body.length} characters left</span>
            </label>
            <div className="row2" style={{ gap: 6 }}>
              {insideHours ? (
                <button className="btn gold" type="submit" disabled={pending}>
                  {pending ? "Sending…" : "Send"}
                </button>
              ) : (
                <button className="btn gold" type="submit" name="later" value="yes" disabled={pending}>
                  {pending
                    ? "Saving…"
                    : `Send at ${new Date(nextWindow).toLocaleString("en-US", { timeZone: "America/Denver", hour: "numeric", minute: "2-digit" })}`}
                </button>
              )}
            </div>
          </form>

          {!addingTemplate ? (
            <button className="lock" type="button" onClick={() => setAddingTemplate(true)} style={{ background: "none", border: 0, padding: 0, textDecoration: "underline" }}>
              Save something you send often as a template
            </button>
          ) : (
            <TemplateForm clientId={clientId} body={body} onDone={() => setAddingTemplate(false)} />
          )}
        </>
      )}
    </div>
  );
}

function TemplateForm({ clientId, body, onDone }: { clientId: string; body: string; onDone: () => void }) {
  const [state, action, pending] = useActionState(saveTemplate, initial);
  useEffect(() => {
    if (state.ok) onDone();
  }, [state, onDone]);
  return (
    <form action={action} style={{ marginTop: 10 }}>
      {state.error && <div className="alert bad">{state.error}</div>}
      <input type="hidden" name="client_id" value={clientId} />
      <div className="row2">
        <label className="field">
          Name it
          <input id="template-label" name="label" required placeholder="Appointment change" />
        </label>
        <label className="field" style={{ flex: 2 }}>
          The words
          <input id="template-body" name="body" required defaultValue={body} />
        </label>
        <button className="btn" type="submit" disabled={pending}>
          {pending ? "Saving…" : "Save template"}
        </button>
        <button className="btn ghost" type="button" onClick={onDone}>
          Cancel
        </button>
      </div>
      <p className="lock" style={{ margin: "6px 0 0" }}>
        Write {"{first}"} where the client&apos;s first name goes.
      </p>
    </form>
  );
}
