"use client";

import { useActionState, useState } from "react";
import { assignConversation, matchConversation, referralFromText, markSpam, type InboxState } from "./actions";

const initial: InboxState = { error: null, ok: null };

function Note({ state }: { state: InboxState }) {
  if (state.error) return <div style={{ color: "var(--bad)", fontSize: "var(--text-sm)" }}>{state.error}</div>;
  if (state.ok) return <div style={{ color: "var(--ok-ink)", fontSize: "var(--text-sm)" }}>{state.ok}</div>;
  return null;
}

/** Who is looking after this conversation. */
export function AssignForm({
  conversationId,
  assignedTo,
  staff,
}: {
  conversationId: string;
  assignedTo: string | null;
  staff: { id: string; name: string }[];
}) {
  const [state, action, pending] = useActionState(assignConversation, initial);
  return (
    <form action={action} className="row2" style={{ gap: 4, alignItems: "center" }}>
      <input type="hidden" name="conversation_id" value={conversationId} />
      <label className="sr-only" htmlFor={`assign-${conversationId}`}>
        Assign this conversation
      </label>
      <select id={`assign-${conversationId}`} name="staff_id" defaultValue={assignedTo ?? ""} style={{ maxWidth: 160 }}>
        <option value="">Nobody</option>
        {staff.map((s) => (
          <option key={s.id} value={s.id}>
            {s.name}
          </option>
        ))}
      </select>
      <button className="btn ghost" type="submit" disabled={pending} style={{ padding: "2px 10px" }}>
        {pending ? "…" : "Assign"}
      </button>
      <Note state={state} />
    </form>
  );
}

/**
 * A number nobody knows: whose it is, a referral, or spam. Never nothing - an
 * unmatched text that is ignored is a person who was ignored.
 */
export function UnmatchedActions({
  conversationId,
  clients,
}: {
  conversationId: string;
  clients: { id: string; name: string }[];
}) {
  const [mode, setMode] = useState<"" | "match" | "referral">("");
  const [matchState, matchAction, matching] = useActionState(matchConversation, initial);
  const [refState, refAction, referring] = useActionState(referralFromText, initial);
  const [spamState, spamAction, spamming] = useActionState(markSpam, initial);

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
      <div className="row2" style={{ gap: 6 }}>
        <button type="button" className={"btn " + (mode === "match" ? "" : "ghost")} style={{ padding: "2px 10px" }} onClick={() => setMode(mode === "match" ? "" : "match")}>
          Match to a client
        </button>
        <button type="button" className={"btn " + (mode === "referral" ? "" : "ghost")} style={{ padding: "2px 10px" }} onClick={() => setMode(mode === "referral" ? "" : "referral")}>
          Create a referral
        </button>
        <form action={spamAction}>
          <input type="hidden" name="conversation_id" value={conversationId} />
          <button className="btn ghost" type="submit" disabled={spamming} style={{ padding: "2px 10px" }}>
            {spamming ? "…" : "Spam"}
          </button>
        </form>
      </div>
      <Note state={spamState} />

      {mode === "match" && (
        <form action={matchAction} className="row2" style={{ gap: 4 }}>
          <input type="hidden" name="conversation_id" value={conversationId} />
          <label className="sr-only" htmlFor={`match-${conversationId}`}>
            Which client
          </label>
          <select id={`match-${conversationId}`} name="client_id" required defaultValue="" style={{ maxWidth: 220 }}>
            <option value="" disabled>
              Choose the client…
            </option>
            {clients.map((c) => (
              <option key={c.id} value={c.id}>
                {c.name}
              </option>
            ))}
          </select>
          <button className="btn gold" type="submit" disabled={matching} style={{ padding: "2px 10px" }}>
            {matching ? "…" : "That is them"}
          </button>
          <Note state={matchState} />
        </form>
      )}

      {mode === "referral" && (
        <form action={refAction} className="row2" style={{ gap: 4 }}>
          <input type="hidden" name="conversation_id" value={conversationId} />
          <label className="sr-only" htmlFor={`referral-${conversationId}`}>
            Their name
          </label>
          <input id={`referral-${conversationId}`} name="name" required placeholder="Their name" style={{ maxWidth: 200 }} />
          <button className="btn gold" type="submit" disabled={referring} style={{ padding: "2px 10px" }}>
            {referring ? "…" : "Start a referral"}
          </button>
          <Note state={refState} />
        </form>
      )}
    </div>
  );
}

/** Out of spam, when it was not. */
export function NotSpam({ conversationId }: { conversationId: string }) {
  const [state, action, pending] = useActionState(markSpam, initial);
  return (
    <form action={action}>
      <input type="hidden" name="conversation_id" value={conversationId} />
      <input type="hidden" name="spam" value="no" />
      <button className="btn ghost" type="submit" disabled={pending} style={{ padding: "2px 10px" }}>
        {pending ? "…" : "Not spam"}
      </button>
      <Note state={state} />
    </form>
  );
}
