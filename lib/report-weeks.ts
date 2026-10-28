/**
 * Week and month arithmetic for the reports.
 *
 * Its own file, with nothing imported into it, for two reasons. The weeks are
 * what the monthly report is made of, so getting a boundary wrong does not
 * produce an error - it produces a report missing a Monday, or counting a
 * Sunday twice, which nobody would spot. And a function with no imports can
 * be run by `scripts/check-reports.mjs` over every day of a year before every
 * build, which is the only way a date rule gets tested rather than reviewed.
 *
 * Every date here is `YYYY-MM-DD` and every calculation goes through UTC on
 * purpose. The practice lives in Mountain time and the clock moves twice a
 * year; `new Date("2026-11-01")` plus seven days in local time lands on the
 * wrong day in one of those weeks. A date with no time in it has no timezone
 * to be wrong about, so it is kept that way.
 */

const at = (date: string): Date => new Date(`${date}T00:00:00Z`);
const iso = (d: Date): string => d.toISOString().slice(0, 10);

export function addDays(date: string, days: number): string {
  const d = at(date);
  d.setUTCDate(d.getUTCDate() + days);
  return iso(d);
}

/** The Monday of the week a date falls in. A week is Monday to Sunday. */
export function mondayOf(date: string): string {
  const d = at(date);
  d.setUTCDate(d.getUTCDate() - ((d.getUTCDay() + 6) % 7));
  return iso(d);
}

/** The first of the month a date falls in. */
export const monthStartOf = (date: string): string => `${date.slice(0, 7)}-01`;

/** The last day of the month a date falls in. */
export function monthEndOf(date: string): string {
  const d = at(monthStartOf(date));
  d.setUTCMonth(d.getUTCMonth() + 1);
  d.setUTCDate(0);
  return iso(d);
}

/** The month before the one a date falls in, as its first day. */
export function previousMonthOf(date: string): string {
  const d = at(monthStartOf(date));
  d.setUTCMonth(d.getUTCMonth() - 1);
  return iso(d);
}

/**
 * Every Monday whose week has any day inside the period.
 *
 * Any day, not every day: a month begins and ends mid-week five times a year,
 * and a month that only took whole weeks would lose up to twelve days of the
 * record. The straddling weeks are included and their lines are then taken by
 * date, which is why the content is dated lines rather than prose.
 */
export function weeksAcross(from: string, to: string): string[] {
  const weeks: string[] = [];
  for (let w = mondayOf(from); w <= to; w = addDays(w, 7)) weeks.push(w);
  return weeks;
}

/** The Wednesday after the week ends, which is when its report is wanted. */
export const weeklyDueOn = (weekStart: string): string => addDays(weekStart, 9);

/** The 5th of the month after the one reported on. Matches 0260's function. */
export function monthlyDueOn(month: string): string {
  const d = at(monthStartOf(month));
  d.setUTCMonth(d.getUTCMonth() + 1);
  d.setUTCDate(5);
  return iso(d);
}

/** The Monday of the week before the one this date falls in. */
export const lastWeekOf = (date: string): string => addDays(mondayOf(date), -7);
