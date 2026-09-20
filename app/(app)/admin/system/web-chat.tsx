"use client";

import { useActionState } from "react";
import { saveWebChat, type WebChatState } from "./web-chat-actions";

const initial: WebChatState = { error: null, ok: null };

const DAYS = [
  { n: 1, label: "Mon" },
  { n: 2, label: "Tue" },
  { n: 3, label: "Wed" },
  { n: 4, label: "Thu" },
  { n: 5, label: "Fri" },
  { n: 6, label: "Sat" },
  { n: 7, label: "Sun" },
];

export type WebChatSettings = {
  web_chat_enabled: boolean;
  web_chat_takers: string[];
  web_chat_open: string;
  web_chat_close: string;
  web_chat_days: number[];
  web_chat_greeting: string;
  web_chat_promise: string;
};

/**
 * The website chat, as the practice has set it up (Messaging brief, C).
 *
 * "Live" is not a switch anybody sets: it is true when the bubble is on,
 * inside these hours and on these days, and somebody who takes web chats has
 * a CRM window open. Outside that the bubble is still there and still takes
 * a message - it just says so, and says when the answer will come, rather
 * than letting somebody type into a room with nobody in it.
 */
export function WebChatSettingsForm({
  settings,
  staff,
  live,
  embed,
}: {
  settings: WebChatSettings;
  staff: { id: string; name: string }[];
  live: boolean;
  embed: string;
}) {
  const [state, action, pending] = useActionState(saveWebChat, initial);

  return (
    <form action={action} className="card" style={{ marginTop: 14 }}>
      {state.error && <div className="alert bad">{state.error}</div>}
      {state.ok && <div className="alert ok">{state.ok}</div>}

      <p className="sub" style={{ marginTop: 0 }}>
        Right now the bubble is{" "}
        {!settings.web_chat_enabled ? (
          <span className="chip">switched off</span>
        ) : live ? (
          <span className="chip ok">live — somebody is online to answer</span>
        ) : (
          <span className="chip warn">taking messages — nobody is online, or it is outside the hours</span>
        )}
      </p>

      <label style={{ display: "block", fontSize: "var(--text-base)", marginBottom: 12 }}>
        <input
          type="checkbox"
          name="enabled"
          defaultChecked={settings.web_chat_enabled}
          style={{ width: "auto", marginRight: 8 }}
        />
        Show the chat bubble on the website
      </label>

      <div className="row2">
        <label className="field">
          Open from
          <input type="time" name="open" defaultValue={settings.web_chat_open?.slice(0, 5)} required />
        </label>
        <label className="field">
          until
          <input type="time" name="close" defaultValue={settings.web_chat_close?.slice(0, 5)} required />
        </label>
        <fieldset className="field" style={{ border: 0, padding: 0, margin: 0, flex: 2 }}>
          <legend style={{ fontSize: "var(--text-xs)", textTransform: "uppercase", letterSpacing: "0.06em" }}>
            On these days
          </legend>
          <div className="row2" style={{ gap: 10, flexWrap: "wrap" }}>
            {DAYS.map((d) => (
              <label key={d.n} style={{ fontSize: "var(--text-base)", whiteSpace: "nowrap" }}>
                <input
                  type="checkbox"
                  name="day"
                  value={d.n}
                  defaultChecked={settings.web_chat_days?.includes(d.n)}
                  style={{ width: "auto", marginRight: 4 }}
                />
                {d.label}
              </label>
            ))}
          </div>
        </fieldset>
      </div>

      <label className="field" style={{ marginTop: 10 }}>
        Who takes website chats
        <select name="taker" multiple size={Math.min(6, Math.max(3, staff.length))} defaultValue={settings.web_chat_takers ?? []}>
          {staff.map((s) => (
            <option key={s.id} value={s.id}>
              {s.name}
            </option>
          ))}
        </select>
        <span className="lock">
          Choose nobody and it goes to whoever is online. Choose some and it goes to whichever of them has the fewest
          chats open, so it is shared out rather than always landing on the same person.
        </span>
      </label>

      <label className="field" style={{ marginTop: 10 }}>
        What the bubble says first
        <input name="greeting" defaultValue={settings.web_chat_greeting} maxLength={300} />
      </label>

      <label className="field">
        When somebody will hear back, if nobody is online
        <input name="promise" defaultValue={settings.web_chat_promise} maxLength={200} required />
        <span className="lock">
          Shown as &ldquo;we will come back to you <i>{settings.web_chat_promise || "…"}</i>&rdquo;, and a task is
          raised so somebody does.
        </span>
      </label>

      <button className="btn gold" type="submit" disabled={pending} style={{ marginTop: 10 }}>
        {pending ? "Saving…" : "Save"}
      </button>

      <h3 style={{ marginBottom: 4 }}>Putting it on the website</h3>
      <p className="sub" style={{ marginTop: 0 }}>
        One line, just before <code>&lt;/body&gt;</code>. It loads after the page, so it cannot slow the site down.
      </p>
      <pre
        style={{
          margin: 0,
          padding: "10px 12px",
          background: "var(--bone)",
          border: "1px solid var(--line)",
          borderRadius: 8,
          overflowX: "auto",
          fontSize: "var(--text-md)",
        }}
      >
        <code>{embed}</code>
      </pre>
      <p className="lock" style={{ marginTop: 8, marginBottom: 0 }}>
        The widget asks for a name and a phone number or email before anybody can type, shows the line they are
        agreeing to, and keeps nothing on their machine but a token that is gone when the tab closes. It answers only
        on zionrehabcenter.com.
      </p>
    </form>
  );
}
