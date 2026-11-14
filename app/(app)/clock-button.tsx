"use client";

import { useActionState, useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { clockIn, startBreak, endBreak, type ClockState } from "./clock-actions";
import { ClockSummary } from "./clock-summary";

const initial: ClockState = { error: null, ok: null };

/**
 * The clock, in the header, on every screen.
 *
 * It is in the shared layout rather than copied onto each screen, which is how
 * "on every page" is true rather than nearly true - `check-clock-button`
 * asserts that it is mounted there and nowhere else.
 *
 * It shows one thing at rest - whether you are on the clock, how long today,
 * and how many times they have clocked in - and offers the one or two actions
 * that make sense from that state.
 *
 * Clock out opens the day's account (owner, 14 November 2026). Not a form
 * that holds somebody at six in the evening: "Clock out without saying" is
 * there, and taking it clocks them out. What happens instead is that the day
 * is flagged until somebody says what it was.
 */
export function ClockButton({
  staffId,
  startedAt,
  onBreakSince,
  breakSeconds,
  todayHours,
  todaySegments,
  daysToAccountFor,
}: {
  staffId: string;
  /** When the open session began, or null when the person is clocked out. */
  startedAt: string | null;
  onBreakSince: string | null;
  breakSeconds: number;
  /** Hours already recorded today, before the open session. */
  todayHours: number;
  /** Segments already finished today. The open one is counted on top. */
  todaySegments: number;
  /** Days behind them with time on the clock and nothing said about them. */
  daysToAccountFor: number;
}) {
  const router = useRouter();
  const [asking, setAsking] = useState(false);
  const [inState, inAction, clockingIn] = useActionState(clockIn, initial);
  const [breakState, breakAction, breaking] = useActionState(startBreak, initial);
  const [backState, backAction, backing] = useActionState(endBreak, initial);


  // The figure has to move, or a person reads it once and stops believing it.
  // Once a minute, on the minute, because minutes are all it shows.
  //
  // It ticked every second first, and the deploy's idle check caught what that
  // costs: the header re-rendering every second never settles, so Playwright
  // could not click a sidebar link within eight seconds and the walk stopped
  // at /dashboard. A person would have met the same header - a row of controls
  // that reflows under the cursor once a second - without anything saying why.
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    if (!startedAt) return;
    let id: ReturnType<typeof setTimeout>;
    const tick = () => {
      setNow(Date.now());
      // To the next minute boundary rather than a flat sixty seconds, so the
      // figure changes when the clock does and not up to a minute afterwards.
      id = setTimeout(tick, 60_000 - (Date.now() % 60_000));
    };
    id = setTimeout(tick, 60_000 - (Date.now() % 60_000));
    return () => clearTimeout(id);
  }, [startedAt]);

  const busy = clockingIn || breaking || backing;
  const problem = inState.error ?? breakState.error ?? backState.error ?? null;

  if (!startedAt) {
    return (
      <div className="clock-button no-print">
        <form action={inAction}>
          <button className="btn" type="submit" disabled={busy}>
            {clockingIn ? "…" : "Clock in"}
          </button>
        </form>
        {todayHours > 0 && (
          <span className="lock">
            {todayHours.toFixed(2)}h today
            {todaySegments > 1 ? ` · ${todaySegments} segments` : ""}
          </span>
        )}
        {daysToAccountFor > 0 && (
          <a className="chip warn" href="/my-day" style={{ textDecoration: "none" }}>
            {daysToAccountFor === 1 ? "A day to account for" : `${daysToAccountFor} days to account for`}
          </a>
        )}
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
      {todaySegments > 0 && (
        <span className="lock">{todaySegments + 1} segments</span>
      )}

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

      <button className="btn" type="button" disabled={busy} onClick={() => setAsking(true)}>
        Clock out
      </button>

      {problem && <span className="lock clock-problem">{problem}</span>}

      {/* An extended absence is a clock out, not a break (owner, 14 Nov). The
          sentence says the next move rather than the rule. */}
      {onBreakFor >= 60 * 60 && (
        <span className="lock clock-problem">
          Still on a break? Clock out if you have stopped for the day
        </span>
      )}

      {asking && (
        <ClockSummary
          staffId={staffId}
          onCancel={() => setAsking(false)}
          onDone={() => {
            setAsking(false);
            router.refresh();
          }}
        />
      )}
    </div>
  );
}
