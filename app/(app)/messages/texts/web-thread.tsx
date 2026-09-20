"use client";

import { useActionState, useEffect, useRef } from "react";
import { useRouter } from "next/navigation";
import { replyToWebChat, markInboxRead, type InboxState } from "./actions";

const initial: InboxState = { error: null, ok: null };

export type WebMessage = {
  id: string;
  seq: number;
  sender_kind: string;
  sender_label: string;
  body: string;
  created_at: string;
};

/**
 * A website chat, open and answerable (Messaging brief, C).
 *
 * It is answered here rather than on a client record, because the person on
 * the other end may not be anybody the practice knows yet - and somebody
 * waiting on a website should not have to become a client first.
 *
 * The visitor's own end polls every few seconds; this end is live, as the
 * rest of the CRM's messaging has been since the foundation.
 */
export function WebThread({
  conversationId,
  visitor,
  messages,
  canAnswer,
}: {
  conversationId: string;
  visitor: string;
  messages: WebMessage[];
  canAnswer: boolean;
}) {
  const router = useRouter();
  const [state, action, pending] = useActionState(replyToWebChat, initial);
  const form = useRef<HTMLFormElement>(null);
  const end = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (state.ok) {
      form.current?.reset();
      router.refresh();
    }
  }, [state, router]);

  useEffect(() => {
    const onMessage = (e: Event) => {
      const row = (e as CustomEvent<{ conversation_id: string }>).detail;
      if (row.conversation_id === conversationId) router.refresh();
    };
    window.addEventListener("zion:message", onMessage);
    return () => window.removeEventListener("zion:message", onMessage);
  }, [conversationId, router]);

  useEffect(() => {
    if (messages.length > 0) void markInboxRead(conversationId, Number(messages[messages.length - 1].seq));
    end.current?.scrollIntoView({ block: "end" });
  }, [conversationId, messages]);

  return (
    <>
      <ol className="thread-list texts" aria-label={`Website chat with ${visitor}`}>
        {messages.length === 0 && <li className="empty">Nothing said yet.</li>}
        {messages.map((m) => (
          <li
            key={m.id}
            className={
              "bubble " + (m.sender_kind === "visitor" ? "" : m.sender_kind === "system" ? "system" : "mine")
            }
          >
            <div className="lock">
              {m.sender_kind === "visitor" ? visitor : m.sender_kind === "system" ? "Website" : m.sender_label || "You"} ·{" "}
              {new Date(m.created_at).toLocaleString("en-US", {
                timeZone: "America/Denver",
                month: "short",
                day: "numeric",
                hour: "numeric",
                minute: "2-digit",
              })}
            </div>
            <div className="bubble-text">{m.body}</div>
          </li>
        ))}
      </ol>
      <div ref={end} />

      {canAnswer ? (
        <form ref={form} action={action} className="composer" style={{ marginTop: 10 }}>
          {state.error && <div className="alert bad">{state.error}</div>}
          <input type="hidden" name="conversation_id" value={conversationId} />
          <label className="field" style={{ margin: 0, flex: 1 }}>
            <span className="sr-only">Reply to {visitor}</span>
            <textarea
              id="web-reply"
              name="body"
              rows={2}
              required
              maxLength={2000}
              placeholder="Answer them"
              onKeyDown={(e) => {
                if (e.key === "Enter" && !e.shiftKey) {
                  e.preventDefault();
                  form.current?.requestSubmit();
                }
              }}
            />
          </label>
          <button className="btn gold" type="submit" disabled={pending}>
            {pending ? "Sending…" : "Send"}
          </button>
        </form>
      ) : (
        <p className="lock" style={{ marginTop: 10 }}>
          Your role does not answer the website chat.
        </p>
      )}
    </>
  );
}
