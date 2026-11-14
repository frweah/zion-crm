/**
 * Today, this week, this pay period — worked, break, segments.
 *
 * One component because the owner asked for the same three figures in four
 * places (top-bar button, My day, the staff record, Admin -> Hours), and four
 * copies of a sum is four chances for two screens to disagree about what
 * somebody worked. The figures all come from `my_hours_summary`, which is one
 * query over the sessions that count.
 *
 * Segments are shown because they are the number a person can check against
 * their own memory of the day: "I clocked in twice" is a thing somebody
 * knows, and a day that says three is a day with something wrong in it.
 */
export type ClockTotals = {
  today_hours: number | string | null;
  today_break_seconds: number | string | null;
  today_segments: number | string | null;
  week_hours: number | string | null;
  week_break_seconds: number | string | null;
  week_segments: number | string | null;
  period_hours: number | string | null;
  period_break_seconds: number | string | null;
  period_segments: number | string | null;
  period_start?: string | null;
  period_end?: string | null;
};

/** The columns to select, in one place, so a screen cannot ask for half of them. */
export const CLOCK_TOTALS_COLUMNS =
  "today_hours, today_break_seconds, today_segments, week_hours, week_break_seconds, week_segments, period_hours, period_break_seconds, period_segments, period_start, period_end";

const hours = (v: number | string | null | undefined) => Number(v ?? 0);

/** Minutes, because a break is minutes and nobody thinks of it in hundredths. */
function breakSaid(seconds: number, segments: number): string {
  const parts: string[] = [];
  if (seconds > 0) parts.push(`${Math.round(seconds / 60)} min of break`);
  if (segments > 0) parts.push(segments === 1 ? "1 segment" : `${segments} segments`);
  return parts.join(" · ") || "hours worked";
}

export function ClockTotalsTiles({ totals }: { totals: ClockTotals | null }) {
  const t = totals;
  return (
    <div className="tiles">
      <div className="tile tile-lead">
        <span className="tile-label">Today</span>
        <span className="tile-value">{hours(t?.today_hours).toFixed(2)}</span>
        <span className="tile-note">
          {breakSaid(Number(t?.today_break_seconds ?? 0), Number(t?.today_segments ?? 0))}
        </span>
      </div>
      <div className="tile">
        <span className="tile-label">This week</span>
        <span className="tile-value">{hours(t?.week_hours).toFixed(2)}</span>
        <span className="tile-note">
          {breakSaid(Number(t?.week_break_seconds ?? 0), Number(t?.week_segments ?? 0))}
        </span>
      </div>
      <div className="tile">
        <span className="tile-label">This pay period</span>
        <span className="tile-value">{hours(t?.period_hours).toFixed(2)}</span>
        <span className="tile-note">
          {t?.period_start
            ? `${t.period_start} to ${t.period_end}`
            : breakSaid(Number(t?.period_break_seconds ?? 0), Number(t?.period_segments ?? 0))}
        </span>
      </div>
    </div>
  );
}

/** The same three figures on one line, where a page has no room for tiles. */
export function ClockTotalsLine({ totals }: { totals: ClockTotals | null }) {
  const t = totals;
  return (
    <p className="lock">
      Today {hours(t?.today_hours).toFixed(2)}h · this week {hours(t?.week_hours).toFixed(2)}h · this
      period {hours(t?.period_hours).toFixed(2)}h
      {Number(t?.today_segments ?? 0) > 0
        ? ` · ${Number(t?.today_segments)} ${Number(t?.today_segments) === 1 ? "segment" : "segments"} today`
        : ""}
    </p>
  );
}
