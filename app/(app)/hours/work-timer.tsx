"use client";

import { useState, useEffect, useActionState } from "react";
import {
  startWorkTimer,
  discardWorkTimer,
  saveTimerSession,
  type HoursState,
} from "./actions";
import { formatPayRate } from "@/lib/constants";

const initial: HoursState = { error: null, ok: null };

/** Hours to two decimals, the way work_sessions stores them. */
function elapsedHours(startedAt: string, now: number): number {
  const hours = (now - new Date(startedAt).getTime()) / 3600000;
  return Math.min(Math.round(hours * 100) / 100, 24);
}

function clock(startedAt: string, now: number): string {
  const seconds = Math.max(0, Math.floor((now - new Date(startedAt).getTime()) / 1000));
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = seconds % 60;
  return `${h}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
}

/**
 * Start and end a work session.
 *
 * A convenience for logging rather than a shift clock: nothing starts on
 * login, nothing knows about breaks, and ending it opens the ordinary logging
 * form with the elapsed figure filled in — to be corrected if it is wrong,
 * which after a long phone call it usually is.
 */
export function WorkTimer({
  running,
  todayHours,
  periodHours,
  periodStart,
  periodEnd,
  clients,
  today,
  rate,
}: {
  running: { started_at: string } | null;
  todayHours: number;
  periodHours: number;
  periodStart: string;
  periodEnd: string;
  clients: { id: string; name: string }[];
  today: string;
  /**
   * The person's own rate, shown only where they came to think about their
   * time. Nobody else's rate is reachable from here — the database returns
   * nothing for anybody but the caller.
   */
  rate?: { pay_rate: number; rate_unit: string } | null;
}) {
  const [startState, startAction, starting] = useActionState(startWorkTimer, initial);
  const [discardState, discardAction, discarding] = useActionState(discardWorkTimer, initial);
  const [saveState, saveAction, saving] = useActionState(saveTimerSession, initial);
  const [ending, setEnding] = useState(false);

  // Ticks only while something is running, and only in the browser — the
  // server renders the started_at and nothing else, so there is no clock to
  // disagree about.
  const [now, setNow] = useState<number | null>(null);
  useEffect(() => {
    if (!running) return;
    setNow(Date.now());
    const id = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(id);
  }, [running]);

  const hours = running && now ? elapsedHours(running.started_at, now) : 0;
  const tooLong = hours >= 24;
  const tooShort = hours < 0.01;

  return (
    <div className="card" style={{ marginBottom: 14 }}>
      <div className="row2" style={{ justifyContent: "space-between", alignItems: "center" }}>
        <div>
          <h3 style={{ margin: 0 }}>Work session</h3>
          <p className="sub" style={{ margin: "4px 0 0" }}>
            <b>{Number(todayHours).toLocaleString()}</b> today ·{" "}
            <b>{Number(periodHours).toLocaleString()}</b> this period ({periodStart} to{" "}
            {periodEnd})
          </p>
          {rate !== undefined && (
            <p className="lock" style={{ margin: "4px 0 0" }}>
              {rate
                ? `Your rate is ${formatPayRate(rate.pay_rate, rate.rate_unit)}. Work done before a change keeps the rate it was done under.`
                : "No rate is on file for you yet. Ask the administrator."}
            </p>
          )}
        </div>

        {!running ? (
          <form action={startAction}>
            <button className="btn gold" type="submit" disabled={starting}>
              {starting ? "Starting…" : "Start work session"}
            </button>
          </form>
        ) : (
          <div style={{ textAlign: "right" }}>
            <div style={{ fontSize: 22, fontVariantNumeric: "tabular-nums", fontWeight: 600 }}>
              {now ? clock(running.started_at, now) : "—"}
            </div>
            <div className="lock">since {new Date(running.started_at).toLocaleTimeString()}</div>
          </div>
        )}
      </div>

      {startState.error && <div className="alert bad">{startState.error}</div>}
      {discardState.error && <div className="alert bad">{discardState.error}</div>}
      {discardState.ok && <div className="alert ok">{discardState.ok}</div>}
      {saveState.error && <div className="alert bad">{saveState.error}</div>}
      {saveState.ok && <div className="alert ok">{saveState.ok}</div>}

      {running && !ending && (
        <div className="row2" style={{ gap: 6, marginTop: 10 }}>
          <button className="btn" type="button" onClick={() => setEnding(true)}>
            End work session
          </button>
          <form action={discardAction} style={{ display: "inline" }}>
            <button className="btn ghost" type="submit" disabled={discarding}>
              {discarding ? "…" : "Discard"}
            </button>
          </form>
        </div>
      )}

      {running && ending && (
        <form action={saveAction} style={{ marginTop: 12 }}>
          {tooLong && (
            <div className="alert warn">
              This has been running for more than a day, so the figure below is capped at 24. It
              was probably left on — change it to what you actually worked, or discard it.
            </div>
          )}
          {tooShort && (
            <div className="alert warn">
              That is under a minute. Change it to what you actually worked, or discard it.
            </div>
          )}

          <div className="row2">
            <label className="field">
              Day
              <input type="date" name="worked_on" defaultValue={today} max={today} required />
            </label>
            <label className="field">
              Hours
              <input
                type="number"
                name="hours"
                step="0.01"
                min="0.01"
                max="24"
                defaultValue={hours > 0 ? hours.toFixed(2) : ""}
                required
              />
              <span className="lock">From the clock. Change it if it is not right.</span>
            </label>
            <label className="field" style={{ flex: 2 }}>
              Client, if it was for one
              <select name="client_id" defaultValue="">
                <option value="">Not for one client</option>
                {clients.map((c) => (
                  <option key={c.id} value={c.id}>
                    {c.name}
                  </option>
                ))}
              </select>
            </label>
          </div>

          <label className="field">
            What the time was spent on
            <input name="description" required placeholder="Needed — it is the billing record" />
          </label>

          <div className="row2" style={{ gap: 6 }}>
            <button className="btn gold" type="submit" disabled={saving}>
              {saving ? "Saving…" : "Save the session"}
            </button>
            <button className="btn ghost" type="button" onClick={() => setEnding(false)}>
              Keep it running
            </button>
          </div>
        </form>
      )}

      {!running && (
        <p className="lock" style={{ marginTop: 10, marginBottom: 0 }}>
          Nothing starts on its own, and nothing is logged until you save it. Logging hours by hand
          works exactly as before.
        </p>
      )}
    </div>
  );
}
