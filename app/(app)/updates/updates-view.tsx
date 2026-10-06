"use client";

import { useActionState, useState } from "react";
import { postUpdate, acknowledgeUpdate, retireUpdate, type UpdateState } from "./actions";

const initial: UpdateState = { error: null, ok: null };

export type UpdateRow = {
  id: string;
  title: string;
  text: string;
  link: string | null;
  attachment_path: string | null;
  attachment_name: string | null;
  audience: string[] | null;
  pinned: boolean;
  requires_ack: boolean;
  posted_by_name: string | null;
  posted_at: string | null;
  read_by_me: boolean;
  read_count: number;
};

type Shown = UpdateRow & { posted_when: string; not_read: string[] | null };

/** Admin's own form: a heading, what it says, who it is for, and how firmly. */
export function PostUpdate({ roles }: { roles: { key: string; label: string }[] }) {
  const [state, action, pending] = useActionState(postUpdate, initial);
  const [open, setOpen] = useState(false);

  if (!open) {
    return (
      <div style={{ marginBottom: 16 }}>
        <button className="btn gold" type="button" onClick={() => setOpen(true)}>
          Post an update
        </button>
      </div>
    );
  }

  return (
    <form action={action} className="card" style={{ marginBottom: 16 }}>
      <h3 style={{ marginTop: 0 }}>Post an update</h3>
      {state.error && <div className="alert bad">{state.error}</div>}
      {state.ok && <div className="alert ok">{state.ok}</div>}

      <label className="field">
        Heading
        <input name="title" required maxLength={120} />
      </label>
      <label className="field">
        What it says
        <textarea name="text" rows={4} required />
      </label>
      <label className="field">
        A link, if there is one
        <input name="link" type="url" placeholder="https://" />
      </label>

      <fieldset style={{ border: 0, padding: 0, margin: "10px 0 0" }}>
        <legend className="label">Who it is for</legend>
        <p className="lock" style={{ margin: "0 0 6px" }}>
          Tick nobody and it goes to everybody.
        </p>
        <div className="row2" style={{ gap: 14, flexWrap: "wrap" }}>
          {roles.map((r) => (
            <label key={r.key} style={{ display: "inline-flex", gap: 6, alignItems: "center" }}>
              <input type="checkbox" name="audience" value={r.key} />
              {r.label}
            </label>
          ))}
        </div>
      </fieldset>

      <div className="row2" style={{ gap: 14, marginTop: 10, flexWrap: "wrap" }}>
        <label style={{ display: "inline-flex", gap: 6, alignItems: "center" }}>
          <input type="checkbox" name="requires_ack" />
          Must be acknowledged
        </label>
        <label style={{ display: "inline-flex", gap: 6, alignItems: "center" }}>
          <input type="checkbox" name="pinned" />
          Pin it until it is read
        </label>
      </div>

      <div className="row2" style={{ gap: 8, marginTop: 12 }}>
        <button className="btn gold" type="submit" disabled={pending}>
          {pending ? "Posting…" : "Post it"}
        </button>
        <button className="row-link" type="button" onClick={() => setOpen(false)}>
          Not now
        </button>
      </div>
    </form>
  );
}

/** The feed itself: top-down, like the app it stands in for. */
export function UpdateFeed({ updates, isAdmin }: { updates: Shown[]; isAdmin: boolean }) {
  if (updates.length === 0) {
    return <p className="empty">Nothing has been posted yet.</p>;
  }

  return (
    <ul className="feed">
      {updates.map((u) => (
        <li key={u.id} className={"feed-item" + (u.pinned && !u.read_by_me ? " feed-pinned" : "")}>
          <div className="feed-head">
            <h3>{u.title}</h3>
            {u.pinned && !u.read_by_me && <span className="chip warn">pinned until read</span>}
            {u.requires_ack && !u.read_by_me && <span className="chip warn">needs acknowledging</span>}
            {(u.audience ?? []).length > 0 && <span className="chip">{(u.audience ?? []).join(", ")}</span>}
          </div>

          <p className="feed-body">{u.text}</p>

          {u.link && (
            <p style={{ margin: "0 0 8px" }}>
              <a href={u.link} target="_blank" rel="noopener noreferrer">
                {u.link}
              </a>
            </p>
          )}

          <div className="feed-foot">
            <span className="lock">
              {u.posted_by_name ?? "The practice"} · {u.posted_when}
              {isAdmin && ` · ${u.read_count} read`}
            </span>

            {u.read_by_me ? (
              <span className="lock">You have read this</span>
            ) : (
              <form action={acknowledgeUpdate}>
                <input type="hidden" name="update_id" value={u.id} />
                <button className="btn gold" type="submit">
                  {u.requires_ack ? "I have read this" : "Mark as read"}
                </button>
              </form>
            )}

            {isAdmin && (
              <form action={retireUpdate}>
                <input type="hidden" name="update_id" value={u.id} />
                <button className="row-link" type="submit">
                  Take it down
                </button>
              </form>
            )}
          </div>

          {isAdmin && u.not_read && u.not_read.length > 0 && (
            <p className="lock" style={{ margin: "6px 0 0" }}>
              Not yet read by {u.not_read.join(", ")}.
            </p>
          )}
        </li>
      ))}
    </ul>
  );
}
