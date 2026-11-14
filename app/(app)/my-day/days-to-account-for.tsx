import Link from "next/link";

import { PRACTICE_TZ } from "@/lib/constants";

/**
 * Days with time on the clock that nobody has said anything about.
 *
 * The other half of "not required to clock out" (owner, 14 November 2026).
 * Nothing stops a person clocking out without writing their day up - a form
 * at six in the evening is how the last attempt failed - so the day is named
 * here instead, until somebody says what it was.
 *
 * It names the days rather than counting them. "Three days to account for"
 * tells somebody they are behind without telling them on what, and the thing
 * that gets it done is the link straight to the day.
 */
export function DaysToAccountFor({
  days,
  whose,
}: {
  days: { day: string; segments: number; hours: number }[];
  /** Whose days these are, when it is not the person reading. */
  whose?: string;
}) {
  if (days.length === 0) return null;

  return (
    <div className="alert warn">
      <b>
        {whose ? `${whose} has ` : ""}
        {days.length === 1 ? "a day with nothing said about it" : `${days.length} days with nothing said about them`}
      </b>
      <ul style={{ margin: "6px 0 0", paddingLeft: 18 }}>
        {days.map((d) => (
          <li key={d.day}>
            <Link href={`/end-of-day?day=${d.day}`}>
              {new Date(`${d.day}T12:00:00`).toLocaleDateString("en-US", {
                timeZone: PRACTICE_TZ,
                weekday: "short",
                month: "short",
                day: "numeric",
              })}
            </Link>{" "}
            <span className="lock">
              {d.hours.toFixed(2)}h
              {d.segments > 1 ? ` across ${d.segments} segments` : ""}
            </span>
          </li>
        ))}
      </ul>
    </div>
  );
}
