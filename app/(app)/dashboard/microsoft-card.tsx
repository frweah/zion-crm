"use client";

import { useActionState } from "react";
import { disconnectMicrosoft, type MicrosoftState } from "./microsoft-actions";
import { syncNow, type SyncState } from "./sync-actions";

const initial: MicrosoftState = { error: null, ok: null };
const syncInitial: SyncState = { error: null, ok: null };

function SyncNow() {
  const [state, action, pending] = useActionState(syncNow, syncInitial);
  return (
    <>
      {state.error && <div className="alert bad">{state.error}</div>}
      {state.ok && <div className="alert ok">{state.ok}</div>}
      <form action={action} style={{ display: "inline" }}>
        <button className="btn" type="submit" disabled={pending}>
          {pending ? "Syncing…" : "Sync now"}
        </button>
      </form>{" "}
    </>
  );
}

/**
 * What the sync actually does, in the four sentences that answer the
 * questions people asked at the review: does it read all my mail, does it
 * send anything, what ends up on a client record, and can I stop it.
 */
function WhatSyncDoes() {
  return (
    <details style={{ marginTop: 10 }}>
      <summary style={{ cursor: "pointer", fontSize: 13 }}>What the sync does</summary>
      <ul style={{ fontSize: 12, color: "var(--muted)", margin: "8px 0 0", paddingLeft: 18 }}>
        <li>
          <b>Calendar, both ways.</b> Appointments you create in the CRM go into your Outlook
          calendar. Outlook events tagged with a client number come back onto that client.
        </li>
        <li>
          <b>Mail, read only, and only where it already matches.</b> A message is logged only if
          one of its addresses is already on a client or counselor record. Everything else in
          your mailbox is passed over and not stored at all.
        </li>
        <li>
          <b>Four things, never the message.</b> Subject, date, direction and a link to open it
          in Outlook. The body is never read into the CRM — there is nowhere to put it.
        </li>
        <li>
          <b>It never sends.</b> Everything the CRM emails goes out through its own address, not
          yours. You can exclude a thread, or disconnect, at any time.
        </li>
      </ul>
    </details>
  );
}

/**
 * What the last run did.
 *
 * Nothing found and nothing working look identical otherwise, which is what
 * the review said: people pressed Sync now, saw the message disappear, and
 * had no idea whether it had done anything.
 */
function LastRun({
  lastRun,
  lastResult,
}: {
  lastRun: string | null;
  lastResult: { mail_logged: number; events_pulled: number; last_error: string } | null;
}) {
  if (!lastRun) {
    return (
      <p className="lock" style={{ marginTop: 0 }}>
        Not synced yet. It runs overnight on its own, or press Sync now.
      </p>
    );
  }

  const mail = Number(lastResult?.mail_logged ?? 0);
  const events = Number(lastResult?.events_pulled ?? 0);
  const when = new Date(lastRun).toLocaleString();

  if (lastResult?.last_error) {
    return (
      <div className="alert warn">
        The last sync, {when}, did not finish: {lastResult.last_error}
      </div>
    );
  }

  return (
    <p className="sub" style={{ marginTop: 0 }}>
      Last synced {when} —{" "}
      {mail === 0 && events === 0
        ? "nothing new to bring in."
        : [
            mail > 0 ? `${mail} message${mail === 1 ? "" : "s"} logged` : null,
            events > 0 ? `${events} appointment${events === 1 ? "" : "s"} brought in` : null,
          ]
            .filter(Boolean)
            .join(", ") + "."}
    </p>
  );
}
/**
 * Connecting a Microsoft account.
 *
 * The person connects their own and nobody else's. Admin can see that somebody
 * is connected and can disconnect them, but cannot read their token — reading
 * it would be reading their mail as them, which is a different thing entirely.
 */
export function MicrosoftCard({
  connection,
  notice,
  detail,
  lastRun,
  lastResult,
}: {
  connection: {
    microsoft_email: string;
    display_name: string;
    connected_at: string;
    last_error: string;
  } | null;
  notice: string | null;
  detail: string | null;
  lastRun: string | null;
  /** What the last run actually did, so a quiet sync is distinguishable from a broken one. */
  lastResult: {
    mail_logged: number;
    events_pulled: number;
    last_error: string;
  } | null;
}) {
  const [state, action, pending] = useActionState(disconnectMicrosoft, initial);

  const message =
    notice === "connected"
      ? { tone: "ok", text: "Your Microsoft account is connected." }
      : notice === "declined"
        ? { tone: "warn", text: "You declined the permissions, so nothing was connected." }
        : notice === "expired"
          ? { tone: "warn", text: "That attempt timed out. Start again." }
          : notice === "unconfigured"
            ? {
                tone: "bad",
                text: "The Microsoft app details are not set on the server yet. Tell the administrator.",
              }
            : notice === "failed" || notice === "error"
              ? {
                  tone: "bad",
                  text: `Microsoft refused the connection${detail ? `: ${detail}` : "."}`,
                }
              : null;

  return (
    <div className="card" style={{ marginBottom: 18 }}>
      <h3>Outlook</h3>

      {message && <div className={`alert ${message.tone}`}>{message.text}</div>}
      {state.error && <div className="alert bad">{state.error}</div>}
      {state.ok && <div className="alert ok">{state.ok}</div>}

      {connection ? (
        <>
          <p className="sub" style={{ marginTop: 0 }}>
            Connected as <b>{connection.microsoft_email || connection.display_name}</b> since{" "}
            {connection.connected_at.slice(0, 10)}.
          </p>
          {connection.last_error && (
            <div className="alert warn">
              The connection stopped working: {connection.last_error}. Disconnect and connect again.
            </div>
          )}
          <LastRun lastRun={lastRun} lastResult={lastResult} />
          <SyncNow />
          <form action={action} style={{ display: "inline" }}>
            <button className="btn ghost" type="submit" disabled={pending}>
              {pending ? "Disconnecting…" : "Disconnect"}
            </button>
          </form>
          <WhatSyncDoes />
          <p className="lock" style={{ marginBottom: 0 }}>
            Disconnecting removes the stored permission from this system. It does not change
            anything in your Microsoft account, and you can connect again whenever you like.
          </p>
        </>
      ) : (
        <>
          <p className="sub" style={{ marginTop: 0 }}>
            Connect your work Microsoft account and the CRM will keep your Outlook calendar and
            your client records in step. You will be shown exactly what it asks for before you
            agree.
          </p>
          <WhatSyncDoes />
          <a className="btn" href="/api/auth/microsoft/start">
            Connect Outlook
          </a>
          <p className="lock" style={{ marginBottom: 0 }}>
            Only you can connect your account, and only you can disconnect it — apart from the
            administrator, who can disconnect it when somebody leaves. Nobody here can read your
            mail on your behalf.
          </p>
        </>
      )}
    </div>
  );
}
