"use client";

import { useActionState, useState } from "react";
import { sendMessage, replyMessage, forwardMessage, deleteMessage, type SendState } from "./actions";

const initial: SendState = { error: null, ok: null };

function Message({ state }: { state: SendState }) {
  if (state.error) return <div className="alert bad">{state.error}</div>;
  if (state.ok) return <div className="alert ok">{state.ok}</div>;
  return null;
}

/** A new message. Sent from the person's own mailbox, only when they press Send. */
export function ComposeForm({
  to,
  cc,
  subject,
  from,
  canSend,
}: {
  to: string;
  cc: string;
  subject: string;
  from: string;
  canSend: boolean;
}) {
  const [state, action, pending] = useActionState(sendMessage, initial);
  return (
    <form action={action} className="card">
      <Message state={state} />
      <p className="lock" style={{ margin: "0 0 10px" }}>
        From <b>{from}</b>. Nothing about a client&apos;s restricted details belongs in an email.
      </p>
      <label className="field">
        To
        <input id="mail-to" name="to" defaultValue={to} required autoComplete="off" />
      </label>
      <label className="field">
        Cc
        <input id="mail-cc" name="cc" defaultValue={cc} autoComplete="off" />
      </label>
      <label className="field">
        Subject
        <input id="mail-subject" name="subject" defaultValue={subject} required />
      </label>
      <label className="field">
        Message
        <textarea id="mail-text" name="text" rows={12} required />
      </label>
      <button className="btn gold" type="submit" disabled={pending || !canSend || Boolean(state.ok)}>
        {pending ? "Sending…" : state.ok ? "Sent" : "Send"}
      </button>
    </form>
  );
}

/** Reply, reply all, or forward - one open at a time, under the message. */
export function RespondForms({ messageId, box, canSend }: { messageId: string; box: string; canSend: boolean }) {
  const [mode, setMode] = useState<"" | "reply" | "all" | "forward">("");
  const [replyState, replyAction, replying] = useActionState(replyMessage, initial);
  const [fwdState, fwdAction, forwarding] = useActionState(forwardMessage, initial);

  if (!canSend) return null;
  return (
    <div style={{ marginTop: 14 }}>
      <div className="row2" style={{ gap: 6 }}>
        <button type="button" className={"btn " + (mode === "reply" ? "" : "ghost")} onClick={() => setMode(mode === "reply" ? "" : "reply")}>
          Reply
        </button>
        <button type="button" className={"btn " + (mode === "all" ? "" : "ghost")} onClick={() => setMode(mode === "all" ? "" : "all")}>
          Reply all
        </button>
        <button type="button" className={"btn " + (mode === "forward" ? "" : "ghost")} onClick={() => setMode(mode === "forward" ? "" : "forward")}>
          Forward
        </button>
      </div>

      {(mode === "reply" || mode === "all") && (
        <form action={replyAction} style={{ marginTop: 10 }}>
          <Message state={replyState} />
          <input type="hidden" name="message_id" value={messageId} />
          <input type="hidden" name="box" value={box} />
          <input type="hidden" name="all" value={mode === "all" ? "yes" : "no"} />
          <label className="field">
            {mode === "all" ? "Reply to everyone" : "Reply"}
            <textarea id="mail-reply" name="text" rows={8} required />
          </label>
          <button className="btn gold" type="submit" disabled={replying || Boolean(replyState.ok)}>
            {replying ? "Sending…" : replyState.ok ? "Sent" : "Send"}
          </button>
        </form>
      )}

      {mode === "forward" && (
        <form action={fwdAction} style={{ marginTop: 10 }}>
          <Message state={fwdState} />
          <input type="hidden" name="message_id" value={messageId} />
          <input type="hidden" name="box" value={box} />
          <label className="field">
            To
            <input id="mail-fwd-to" name="to" required autoComplete="off" />
          </label>
          <label className="field">
            Note
            <textarea id="mail-fwd-text" name="text" rows={5} />
          </label>
          <button className="btn gold" type="submit" disabled={forwarding || Boolean(fwdState.ok)}>
            {forwarding ? "Sending…" : fwdState.ok ? "Forwarded" : "Forward"}
          </button>
        </form>
      )}
    </div>
  );
}

/** Delete - to the person's own Deleted Items, after a second press. */
/** Delete, with a second press before it happens. The reader's own mailbox. */
export function DeleteMessage({ messageId, back }: { messageId: string; back: string }) {
  const [sure, setSure] = useState(false);
  const [state, action, pending] = useActionState(deleteMessage, initial);
  if (!sure) {
    return (
      <button type="button" className="btn ghost" onClick={() => setSure(true)}>
        Delete
      </button>
    );
  }
  return (
    <form action={action} style={{ display: "inline-flex", gap: 6, alignItems: "center", flexWrap: "wrap" }}>
      <input type="hidden" name="message_id" value={messageId} />
      <input type="hidden" name="box" value="me" />
      <input type="hidden" name="back" value={back} />
      <button className="btn danger" type="submit" disabled={pending}>
        {pending ? "Deleting…" : "Move to Deleted Items"}
      </button>
      <button className="btn ghost" type="button" onClick={() => setSure(false)}>
        Keep it
      </button>
      {state.error && <span style={{ color: "var(--bad)", fontSize: "var(--text-sm)" }}>{state.error}</span>}
    </form>
  );
}
