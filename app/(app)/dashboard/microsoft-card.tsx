"use client";

import { useActionState } from "react";
import { disconnectMicrosoft, type MicrosoftState } from "./microsoft-actions";

const initial: MicrosoftState = { error: null, ok: null };

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
}: {
  connection: {
    microsoft_email: string;
    display_name: string;
    connected_at: string;
    last_error: string;
  } | null;
  notice: string | null;
  detail: string | null;
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
          <form action={action}>
            <button className="btn ghost" type="submit" disabled={pending}>
              {pending ? "Disconnecting…" : "Disconnect"}
            </button>
          </form>
          <p className="lock" style={{ marginBottom: 0 }}>
            Disconnecting removes the stored permission from this system. It does not change
            anything in your Microsoft account, and you can connect again whenever you like.
          </p>
        </>
      ) : (
        <>
          <p className="sub" style={{ marginTop: 0 }}>
            Connect your work Microsoft account so the CRM can work with your Outlook calendar and
            mail. You will be shown exactly what it is asking for before you agree.
          </p>
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
