"use client";

import { useActionState, useEffect, useState } from "react";
import { clockIn, startBreak, endBreak, clockOut, type ClockState } from "./clock-actions";

const initial: ClockState = { error: null, ok: null };

/**
 * The clock, in the header, on every screen.
 *
 * It is in the shared layout rather than copied onto each screen, which is how
 * "on every page" is true rather than nearly true - `check-clock-button`
 * asserts that it is mounted there and nowhere else.
 *
 * It shows one thing at rest - whether you are on the clock, and for how long
 * today - and offers the one or two actions that make sense from that state.
 * Nothing is asked at clock-out: somebody pressing it at six in the evening
 * should not meet a form, and what the time was spent on is added on the Time
 * clock screen where the fuller entry has always lived.
 */
export function ClockButton({
  startedAt,
  onBreakSince,
  breakSeconds,
  todayHours,
}: {
  /** When the open session began, or null when the person is clocked out. */
  startedAt: string | null;
  onBreakSince: string | null;
  breakSeconds: number;
  /** Hours already recorded today, before the open session. */
  todayHours: number;
}) {
  const [inState, inAction, clockingIn] = useActionState(clockIn, initial);
  const [breakState, breakAction, breaking] = useActionState(startBreak, initial);
  const [backState, backAction, backing] = useActionState(endBreak, initial);
  const [outState, outAction, clockingOut] = useActionState(clockOut, initial);

  // The figure has to move, or a person reads it once and stops believing it.
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    if (!startedAt) return;
    const id = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(id);
  }, [startedAt]);

  const busy = clockingIn || breaking || backing || clockingOut;
  const problem =
    inState.error ?? breakState.error ?? backState.error ?? outState.error ?? null;

  if (!startedAt) {
    return (
      <div className="clock-button no-print">
        <form action={inAction}>
          <button className="btn" type="submit" disabled={busy}>
            {clockingIn ? "…" : "Clock in"}
          </button>
        </form>
        {todayHours > 0 && <span className="lock">{todayHours.toFixed(2)}h today</span>}
        {problem && <span className="lock clock-problem">{problem}</span>}
      </div>
    );
  }

  const openSeconds = Math.max(0, Math.floor((now - Date.parse(startedAt)) / 1000));
  const onBreakFor = onBreakSince
    ? Math.max(0, Math.floor((now - Date.parse(onBreakSince)) / 1000))
    : 0;
  const worked = Math.max(0, openSeconds - breakSeconds - onBreakFor);
  const running = todayHours + worked / 3600;

  const clock = `${Math.floor(running)}h ${String(Math.floor((running % 1) * 60)).padStart(2, "0")}m`;

  return (
    <div className="clock-button no-print">
      <span className={onBreakSince ? "chip" : "chip ok"}>
        {onBreakSince ? "On a break" : clock}
      </span>

      {onBreakSince ? (
        <form action={backAction}>
          <button className="btn ghost" type="submit" disabled={busy}>
            {backing ? "…" : "End break"}
          </button>
        </form>
      ) : (
        <form action={breakAction}>
          <button className="btn ghost" type="submit" disabled={busy}>
            {breaking ? "…" : "Start break"}
          </button>
        </form>
      )}

      <form action={outAction}>
        <button className="btn" type="submit" disabled={busy}>
          {clockingOut ? "…" : "Clock out"}
        </button>
      </form>

      {problem && <span className="lock clock-problem">{problem}</span>}
    </div>
  );
}
