"use client";

import { useActionState, useEffect, useRef } from "react";
import { useRouter } from "next/navigation";
import { sendChatMessage, markRead, type ChatState } from "./actions";

const initial: ChatState = { error: null, ok: null };

/**
 * The open conversation, kept current: a message arriving in it (the
 * foundation's live delivery, live-messaging.tsx) redraws it, and whatever is
 * shown is marked read.
 */
export function ThreadLive({ conversationId, lastSeq }: { conversationId: string; lastSeq: number }) {
  const router = useRouter();
  const end = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (lastSeq > 0) void markRead(conversationId, lastSeq);
    end.current?.scrollIntoView({ block: "end" });
  }, [conversationId, lastSeq]);

  useEffect(() => {
    const onMessage = (e: Event) => {
      const row = (e as CustomEvent<{ conversation_id: string }>).detail;
      if (row.conversation_id === conversationId) router.refresh();
    };
    window.addEventListener("zion:message", onMessage);
    return () => window.removeEventListener("zion:message", onMessage);
  }, [conversationId, router]);

  return <div ref={end} />;
}

export function Composer({ conversationId }: { conversationId: string }) {
  const [state, action, pending] = useActionState(sendChatMessage, initial);
  const form = useRef<HTMLFormElement>(null);
  useEffect(() => {
    if (state.ok) form.current?.reset();
  }, [state]);

  return (
    <form ref={form} action={action} className="composer">
      {state.error && <div className="alert bad">{state.error}</div>}
      <input type="hidden" name="conversation_id" value={conversationId} />
      <label className="field" style={{ margin: 0 }}>
        <span className="sr-only">Message</span>
        <textarea
          id="chat-body"
          name="body"
          rows={2}
          required
          maxLength={8000}
          placeholder="Write a message - no restricted client details in chat"
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
  );
}
