"use client";

import Link from "next/link";
import { useActionState, useState } from "react";
import { sendReconciliation, type ReconcileState } from "./reconcile-actions";

const initial: ReconcileState = { error: null, ok: null };

/**
 * The draft, and the two steps to send it: read it, then confirm. Nothing
 * leaves until the second button.
 */
export function ReconcilePanel({
  billingOfficeId,
  billingOfficeName,
  to,
  cc,
  counselorsWithoutEmail,
  subject,
  body,
  summary,
  nothingToSend,
  closeHref,
}: {
  billingOfficeId: string;
  billingOfficeName: string;
  to: string;
  cc: string;
  counselorsWithoutEmail: string[];
  subject: string;
  body: string;
  summary: string;
  nothingToSend: boolean;
  closeHref: string;
}) {
  const [state, action, pending] = useActionState(sendReconciliation, initial);
  const [confirming, setConfirming] = useState(false);

  if (state.ok) {
    return (
      <div className="card">
        <div className="alert ok">{state.ok}</div>
        <Link className="btn ghost" href={closeHref} style={{ textDecoration: "none" }}>
          Close
        </Link>
      </div>
    );
  }

  return (
    <div className="card">
      <p className="sub" style={{ margin: "0 0 12px" }}>
        {summary}
      </p>

      {nothingToSend ? (
        <div className="alert ok">
          Nothing is waiting on {billingOfficeName}: every invoice sent to them has been paid, and no
          authorization of theirs is about to lapse with value left to invoice.
        </div>
      ) : (
        <form action={action}>
          <input type="hidden" name="billing_office_id" value={billingOfficeId} />
          <input type="hidden" name="confirmed" value={confirming ? "yes" : ""} />

          <div className="field">
            To
            <div style={{ marginTop: 6, textTransform: "none", letterSpacing: "normal", fontSize: "var(--text-base)", color: "var(--ink)" }}>
              {billingOfficeName} &lt;{to}&gt;
            </div>
          </div>

          <label className="field" htmlFor="reconcile-cc">
            Copy
            <input id="reconcile-cc" name="cc" defaultValue={cc} />
            <small>
              The counselor on each case listed. Separate addresses with commas.
              {counselorsWithoutEmail.length > 0 &&
                ` No email on file for ${counselorsWithoutEmail.join(", ")}, so they are not copied.`}
            </small>
          </label>

          <label className="field" htmlFor="reconcile-subject">
            Subject
            <input id="reconcile-subject" name="subject" defaultValue={subject} required />
          </label>

          <label className="field" htmlFor="reconcile-body">
            Message
            <textarea id="reconcile-body" name="body" defaultValue={body} rows={18} required />
            <small>Sent as written, from service@. Change anything before sending.</small>
          </label>

          {state.error && <div className="alert bad">{state.error}</div>}

          {confirming ? (
            <div className="alert" style={{ marginTop: 4 }}>
              <b>Send this to {billingOfficeName} now?</b> It goes to {to} from service@ and is logged
              on every case it lists.
              <div className="row2" style={{ marginTop: 10 }}>
                <button className="btn gold" type="submit" disabled={pending}>
                  {pending ? "Sending…" : "Yes, send it"}
                </button>
                <button className="btn ghost" type="button" disabled={pending} onClick={() => setConfirming(false)}>
                  Not yet
                </button>
              </div>
            </div>
          ) : (
            <div className="row2">
              <button className="btn" type="button" onClick={() => setConfirming(true)}>
                I have read it - send…
              </button>
              <Link className="btn ghost" href={closeHref} style={{ textDecoration: "none" }}>
                Cancel
              </Link>
            </div>
          )}
        </form>
      )}
    </div>
  );
}
