"use client";

import { useActionState } from "react";
import {
  addSharedMailbox,
  removeSharedMailbox,
  type SharedState,
} from "./shared-mailbox-actions";

const initial: SharedState = { error: null, ok: null };

export type SharedMailboxRow = {
  address: string;
  label: string;
  last_run_at: string | null;
  last_mail_sync_at: string | null;
  mail_logged: number;
  last_error: string;
};

function Remove({ address }: { address: string }) {
  const [state, action, pending] = useActionState(removeSharedMailbox, initial);
  return (
    <form action={action} style={{ display: "inline" }}>
      <input type="hidden" name="address" value={address} />
      <button className="btn ghost" type="submit" disabled={pending}>
        {pending ? "…" : "Stop reading it"}
      </button>
      {state.error && <div style={{ color: "var(--bad)", fontSize: 12 }}>{state.error}</div>}
    </form>
  );
}

/**
 * The practice's shared mailbox.
 *
 * Admin only, because it is the practice's mailbox rather than anybody's own,
 * and because reading it depends on an Exchange permission that only an
 * administrator would have been given.
 */
export function SharedMailboxCard({ mailboxes }: { mailboxes: SharedMailboxRow[] }) {
  const [state, action, pending] = useActionState(addSharedMailbox, initial);

  return (
    <div className="card" style={{ marginBottom: 18 }}>
      <h3>Shared mailbox</h3>
      <p className="sub" style={{ marginTop: 0 }}>
        Counselor correspondence that arrives at a practice address rather than in somebody&apos;s
        own mailbox. The same rules apply: subject, date, direction and a link, only where the
        address is already on a client or counselor record.
      </p>

      {state.error && <div className="alert bad">{state.error}</div>}
      {state.ok && <div className="alert ok">{state.ok}</div>}

      {mailboxes.length > 0 && (
        <table className="t">
          <tbody>
            {mailboxes.map((m) => (
              <tr key={m.address}>
                <td>
                  <b>{m.address}</b>
                  {m.label && <div style={{ fontSize: 12, color: "var(--muted)" }}>{m.label}</div>}
                  {m.last_run_at ? (
                    <div style={{ fontSize: 12, color: "var(--muted)" }}>
                      Last swept {new Date(m.last_run_at).toLocaleString()} · {m.mail_logged} logged
                    </div>
                  ) : (
                    <div className="lock">Not swept yet.</div>
                  )}
                  {m.last_error && <div className="alert warn">{m.last_error}</div>}
                </td>
                <td style={{ textAlign: "right" }}>
                  <Remove address={m.address} />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}

      <form action={action} style={{ marginTop: 12 }}>
        <div className="row2" style={{ alignItems: "flex-end" }}>
          <label className="field" style={{ flex: 2 }}>
            Mailbox address
            <input name="address" placeholder="service@zionvocrehab.com" required />
          </label>
          <label className="field">
            Label
            <input name="label" placeholder="Counselor mail" />
          </label>
          <button className="btn" type="submit" disabled={pending}>
            {pending ? "Checking…" : "Add"}
          </button>
        </div>
      </form>

      <p className="lock" style={{ marginBottom: 0 }}>
        The address is tried against Microsoft before it is saved, so a mailbox you cannot actually
        read is refused now rather than logging nothing quietly for weeks. Two things have to be in
        place first: an Exchange administrator has given your account access to the mailbox, and
        you have connected using{" "}
        <a href="/api/auth/microsoft/start?shared=1">Connect the shared mailbox</a>, which is the
        only place the extra Mail.Read.Shared permission is asked for.
      </p>
    </div>
  );
}
