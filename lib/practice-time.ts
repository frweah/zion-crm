import { PRACTICE_TZ } from "@/lib/constants";

/**
 * Wall-clock time in the practice's zone (America/Denver), both ways.
 *
 * A datetime-local field sends "2026-09-22T10:00" with no zone. new Date() on
 * that reads it in the server's zone, which on Vercel is UTC - so a 10:00
 * appointment became 04:00 in Outlook. These read and write it as the
 * practice's own time, daylight saving included.
 */
const parts = new Intl.DateTimeFormat("en-US", {
  timeZone: PRACTICE_TZ,
  hourCycle: "h23",
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
  hour: "2-digit",
  minute: "2-digit",
});

function wallOf(t: number): { y: number; mo: number; d: number; h: number; mi: number } {
  const p = parts.formatToParts(new Date(t));
  const g = (k: string) => Number(p.find((x) => x.type === k)?.value ?? 0);
  return { y: g("year"), mo: g("month"), d: g("day"), h: g("hour"), mi: g("minute") };
}

/** "2026-09-22T10:00" in the practice's zone, as an instant. Null if it is not that shape. */
export function practiceWallToDate(local: string): Date | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/.exec(local);
  if (!m) return null;
  const target = Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5]);
  const offsetAt = (t: number) => {
    const w = wallOf(t);
    return Date.UTC(w.y, w.mo - 1, w.d, w.h, w.mi) - t;
  };
  // Twice, so an instant either side of a clock change settles on the right one.
  let t = target - offsetAt(target);
  t = target - offsetAt(t);
  return new Date(t);
}

/** An instant as "2026-09-22T10:00" in the practice's zone, for a datetime-local field. */
export function dateToPracticeWall(d: Date): string {
  const w = wallOf(d.getTime());
  const two = (n: number) => String(n).padStart(2, "0");
  return `${w.y}-${two(w.mo)}-${two(w.d)}T${two(w.h)}:${two(w.mi)}`;
}
