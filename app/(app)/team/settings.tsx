"use client";

import { useActionState, useEffect, useState } from "react";
import { setChatPref, type PrefState } from "./pref-actions";
import { CHAT_PREFS, CHAT_PREF_LABELS, type ChatPref, type ChatSettings } from "@/lib/chat-prefs";

const initial: PrefState = { error: null, ok: null };

/**
 * The three settings, and the one thing only a button press can do.
 *
 * A browser will only ask about notifications from a gesture, and it only asks
 * once ever - told no, it never asks again and the person has to find it in
 * site settings. So it is asked here, by a button, on the screen about Team
 * chat, rather than on the way in where it would be answered by whoever was
 * dismissing dialogs that morning.
 */
function Toggle({ pref, on }: { pref: ChatPref; on: boolean }) {
  const [state, action, pending] = useActionState(setChatPref, initial);

  return (
    <form action={action} className="row2" style={{ gap: 8, alignItems: "center" }}>
      <input type="hidden" name="pref" value={pref} />
      <input type="hidden" name="on" value={on ? "0" : "1"} />
      <button className={"btn " + (on ? "" : "ghost")} type="submit" disabled={pending}>
        {on ? "On" : "Off"}
      </button>
      <span>{CHAT_PREF_LABELS[pref]}</span>
      {state.error && (
        <span style={{ color: "var(--bad)", fontSize: "var(--text-sm)" }}>{state.error}</span>
      )}
    </form>
  );
}

export function TeamSettings({ settings }: { settings: ChatSettings }) {
  const on: Record<ChatPref, boolean> = {
    "chat:preview": settings.preview,
    "chat:sound": settings.sound,
    "chat:dnd": settings.dnd,
  };

  // "default" until asked, "granted" or "denied" after. Read in an effect
  // because the server has no idea and rendering one answer then the other
  // would make the button flicker.
  const [permission, setPermission] = useState<string | null>(null);
  useEffect(() => {
    setPermission(typeof Notification === "undefined" ? "unsupported" : Notification.permission);
  }, []);

  return (
    <section style={{ marginTop: 22 }}>
      <h2 className="h2">Pop-ups and sound</h2>
      <div className="card" style={{ display: "grid", gap: 10 }}>
        {CHAT_PREFS.map((p) => (
          <Toggle key={p} pref={p} on={on[p]} />
        ))}

        <hr className="side-rule" />

        {permission === "granted" && (
          <div>Desktop notifications are on for this browser</div>
        )}
        {permission === "denied" && (
          <div>
            This browser is blocking notifications — turn them back on in its site settings for
            this address
          </div>
        )}
        {permission === "unsupported" && <div>This browser does not do desktop notifications</div>}
        {permission === "default" && (
          <div className="row2" style={{ gap: 8, alignItems: "center" }}>
            <button
              className="btn"
              type="button"
              onClick={() => void Notification.requestPermission().then(setPermission)}
            >
              Allow desktop notifications
            </button>
            <span>Only when this window is not the one in front</span>
          </div>
        )}
      </div>
    </section>
  );
}
