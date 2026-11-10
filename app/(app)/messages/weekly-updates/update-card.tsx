"use client";

import Link from "next/link";
import { useActionState, useState } from "react";
import {
  approveUpdate,
  draftThisWeek,
  discardUpdate,
  editUpdate,
  sendApprovedUpdates,
  sendUpdate,
  type UpdateState,
} from "./actions";

const initial: UpdateState = { error: null, ok: null };

export type UpdateRow = {
  id: string;
  client_id: string;
  contact_id: string | null;
  client_name: string;
  to_name: string;
  relationship: string;
  phone: string | null;
  language: string;
  body: string;
  state: string;
  reason: string;
  consent: string | null;
  can_text: boolean;
  sent_at: string | null;
};

function Said({ state }: { state: UpdateState }) {
  if (state.error) return <p className="alert bad">{state.error}</p>;
  if (state.ok) return <p className="alert ok">{state.ok}</p>;
  return null;
}

/** Why this one cannot go, in a sentence, before anybody clicks. */
function cannotSend(row: UpdateRow): string | null {
  if (!row.phone) {
    return row.contact_id
      ? "No number on this contact, so there is nothing to send to."
      : "No number on this client, so there is nothing to send to.";
  }
  if (!row.can_text) {
    if (!row.consent) return `${row.phone} has no texting consent recorded, so nothing can be sent to it.`;
    return `${row.to_name} ${row.consent === "Withdrawn" ? "has withdrawn" : "declined"} consent for ${row.phone}.`;
  }
  return null;
}

/** The sweep, on demand: the same function, and it sends nothing. */
export function DraftThisWeek({ week }: { week: string }) {
  const [state, action, pending] = useActionState(draftThisWeek, initial);
  return (
    <form action={action} style={{ marginBottom: 12 }}>
      <input type="hidden" name="week" value={week} />
      <Said state={state} />
      <button className="btn ghost" disabled={pending}>
        {pending ? "Drafting…" : "Draft this week now"}
      </button>
    </form>
  );
}

export function SendAllApproved({ week, approved }: { week: string; approved: number }) {
  const [state, action, pending] = useActionState(sendApprovedUpdates, initial);
  return (
    <form action={action} style={{ marginBottom: 12 }}>
      <input type="hidden" name="week" value={week} />
      <Said state={state} />
      <button className="btn" disabled={pending || approved === 0}>
        {pending ? "Sending…" : `Send all approved (${approved})`}
      </button>
    </form>
  );
}

/**
 * One drafted update (part B, 9 November 2026).
 *
 * The body is editable before it goes and after it is approved, because the
 * draft is a draft - the owner reads it, and the sentence that needs changing
 * is usually one word. What cannot be changed is a sent one.
 *
 * A row that cannot be sent says so at the top with the reason, rather than
 * offering a button that fails. The reason is the number's, not the person's:
 * a client whose own number has no consent may still have a partner who has
 * given it, and that is two rows here with two different answers.
 */
export function UpdateCard({ row, canSend }: { row: UpdateRow; canSend: boolean }) {
  const [editState, edit, saving] = useActionState(editUpdate, initial);
  const [approveState, approve, approving] = useActionState(approveUpdate, initial);
  const [sendState, send, sending] = useActionState(sendUpdate, initial);
  const [discardState, discard, discarding] = useActionState(discardUpdate, initial);
  const [open, setOpen] = useState(false);

  const blocked = cannotSend(row);
  const settled = row.state === "Sent" || row.state === "Not sent";

  return (
    <div className="card" style={{ marginBottom: 12 }}>
      <div className="row2" style={{ justifyContent: "space-between", alignItems: "baseline" }}>
        <h3 className="h3" style={{ margin: 0 }}>
          <Link href={`/clients/${row.client_id}?tab=profile`} style={{ color: "var(--teal)" }}>
            {row.to_name}
          </Link>
          {row.contact_id ? (
            <span className="lock">
              {" "}
              · {row.relationship} of {row.client_name}
            </span>
          ) : null}
        </h3>
        <span
          className={
            row.state === "Sent"
              ? "chip ok"
              : row.state === "Approved"
                ? "chip"
                : row.state === "Not sent"
                  ? "chip bad"
                  : "chip warn"
          }
        >
          {row.state}
        </span>
      </div>

      <p className="lock" style={{ marginTop: 4 }}>
        {row.phone ?? "no number"}
        {row.language ? ` · reads ${row.language}` : ""}
        {row.sent_at ? ` · sent ${row.sent_at.slice(0, 16).replace("T", " ")}` : ""}
      </p>

      {row.language && !settled && (
        <p className="alert">
          Drafted in English. {row.to_name} reads {row.language} — rewrite it before it goes.
        </p>
      )}

      {blocked && !settled && <p className="alert bad">{blocked}</p>}
      {row.state === "Not sent" && row.reason && <p className="lock">Not sent: {row.reason}</p>}

      <Said state={editState} />
      <Said state={approveState} />
      <Said state={sendState} />
      <Said state={discardState} />

      {settled ? (
        <p style={{ whiteSpace: "pre-wrap", margin: 0 }}>{row.body}</p>
      ) : (
        <form action={edit}>
          <input type="hidden" name="id" value={row.id} />
          <label className="field">
            <span>What it says</span>
            <textarea name="body" rows={4} defaultValue={row.body} />
          </label>
          <button className="btn ghost" disabled={saving}>
            {saving ? "…" : "Save the wording"}
          </button>
        </form>
      )}

      {canSend && !settled && (
        <div className="row2" style={{ marginTop: 10, flexWrap: "wrap" }}>
          <form action={approve}>
            <input type="hidden" name="id" value={row.id} />
            <input type="hidden" name="approved" value={row.state === "Approved" ? "no" : "yes"} />
            <button className="btn ghost" disabled={approving}>
              {row.state === "Approved" ? "Back to a draft" : "Approve"}
            </button>
          </form>

          {row.state === "Approved" && !blocked && (
            <form action={send}>
              <input type="hidden" name="id" value={row.id} />
              <button className="btn" disabled={sending}>
                {sending ? "Sending…" : "Send it"}
              </button>
            </form>
          )}

          {open ? (
            <form action={discard} className="row2">
              <input type="hidden" name="id" value={row.id} />
              <label className="field">
                <span>Why it is not going</span>
                <input name="reason" required placeholder="Spoke to them on the phone instead" />
              </label>
              <button className="btn ghost" disabled={discarding}>
                Do not send
              </button>
            </form>
          ) : (
            <button type="button" className="btn ghost" onClick={() => setOpen(true)}>
              Do not send
            </button>
          )}
        </div>
      )}
    </div>
  );
}
