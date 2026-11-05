"use client";

import { useActionState } from "react";
import { confirmAutoClosed, type ClockState } from "../clock-actions";

const initial: ClockState = { error: null, ok: null };

/**
 * A session the fourteen-hour rule closed, waiting to be believed.
 *
 * It is at the top of the Time clock screen rather than in a list of hours,
 * because it is the one thing on this screen that is somebody's to do. The
 * figure is the clock's guess - the last thing they did in the CRM - and the
 * two answers are "that is right" and "no, it was this", which is an ordinary
 * correction and goes through the ordinary correction.
 */
export function ConfirmClosed({
  sessions,
}: {
  sessions: { id: string; worked_on: string; hours: number; started_at: string | null; ended_at: string | null }[];
}) {
  const [state, action, saving] = useActionState(confirmAutoClosed, initial);

  if (sessions.length === 0) return null;

  const at = (iso: string | null) =>
    iso
      ? new Date(iso).toLocaleTimeString("en-US", {
          timeZone: "America/Denver",
          hour: "numeric",
          minute: "2-digit",
        })
      : "—";

  return (
    <section className="alert bad" style={{ marginBottom: 14 }} aria-label="Sessions closed for you">
      <b>
        {sessions.length === 1
          ? "A session was closed for you"
          : `${sessions.length} sessions were closed for you`}
      </b>
      <ul className="day-list" style={{ marginTop: 6 }}>
        {sessions.map((s) => (
          <li key={s.id}>
            <span className="day-main">
              {s.worked_on} · {at(s.started_at)} to {at(s.ended_at)} · {Number(s.hours).toFixed(2)}h
            </span>
            <form action={action} style={{ display: "inline" }}>
              <input type="hidden" name="session_id" value={s.id} />
              <button className="btn" type="submit" disabled={saving}>
                {saving ? "…" : "That is right"}
              </button>
            </form>
          </li>
        ))}
      </ul>
      <p className="lock" style={{ margin: "6px 0 0" }}>
        It ended at the last thing you did here.
      </p>
      {state.error && <div style={{ color: "var(--bad)" }}>{state.error}</div>}
    </section>
  );
}
