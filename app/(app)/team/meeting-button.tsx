"use client";

import { useActionState } from "react";
import { startTeamsMeeting, type MeetingState } from "./meeting-actions";

const initial: MeetingState = { error: null, ok: null };

/**
 * "Start a Teams meeting", on a thread and on a client's record.
 *
 * The video is Teams'. What this does is create the meeting on the person's
 * own connection, put the join link where the people who need it will see it,
 * and open it.
 */
export function TeamsMeetingButton({
  conversationId,
  clientId,
  subject,
}: {
  conversationId?: string;
  clientId?: string;
  subject?: string;
}) {
  const [state, action, pending] = useActionState(startTeamsMeeting, initial);

  return (
    <div>
      <form action={action} style={{ display: "inline" }}>
        {conversationId && <input type="hidden" name="conversation_id" value={conversationId} />}
        {clientId && <input type="hidden" name="client_id" value={clientId} />}
        {subject && <input type="hidden" name="subject" value={subject} />}
        <button className="btn ghost" type="submit" disabled={pending}>
          {pending ? "Starting…" : "Start a Teams meeting"}
        </button>
      </form>
      {state.error && (
        <div className="lock" style={{ color: "var(--bad)" }}>
          {state.error}
        </div>
      )}
      {state.join && (
        <a className="btn gold" href={state.join} target="_blank" rel="noopener noreferrer">
          Open it in Teams
        </a>
      )}
    </div>
  );
}
