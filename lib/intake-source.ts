/**
 * Where intake reads from, and whose mail it will act on.
 *
 * Two facts, in one place, because both are load-bearing and both are the kind
 * of thing that gets loosened by accident. The mailbox is service@ and not
 * anybody's personal inbox; the sender must be utah.gov and nothing else, and
 * everything that is not gets left alone with no record and no notification.
 *
 * Here rather than in the route so that scripts/check-intake.mjs can try the
 * cases against the same expression the route uses, instead of a copy of it
 * that could drift into being right about a rule the route no longer has.
 */
export const INTAKE_MAILBOX = "service@zionvocrehab.com";

/**
 * A Utah state address: utah.gov, or any sub-domain of it.
 *
 * Anchored at both ends. Without the anchor "dana@utah.gov.example.com" would
 * pass, and a referral is the one document that creates a client - so the
 * cheapest possible way in is the one worth closing.
 */
const UTAH_GOV = /^[^@\s]+@([a-z0-9-]+\.)*utah\.gov$/i;

export function isFromUtahGov(address: string | null | undefined): boolean {
  return UTAH_GOV.test((address ?? "").trim());
}

/**
 * An end-of-day report, sent the old way.
 *
 * Until everybody is in the habit of filling the day in on the CRM, a report
 * that arrives at service@ is filed against that person's day record and they
 * are reminded to put it in properly. The owner reviews this on 1 November
 * 2026 (18 Oct 2026).
 *
 * "EOD" as a word, not as three letters inside another one: a subject
 * mentioning a "period" or a "method" is not somebody's day. The separators
 * people actually type around it - a hyphen, a slash, a colon, an underscore
 * - count as boundaries, so "EOD-report", "EOD: Tuesday" and "MAE_EOD_JUNE 1"
 * all read.
 *
 * Here beside the utah.gov rule, and for the same reason: so the check can
 * try the cases against the expression the cron uses rather than a copy of it.
 */
const END_OF_DAY = /(^|[^a-z0-9])eod([^a-z0-9]|$)/i;

export function looksLikeEndOfDay(subject: string | null | undefined): boolean {
  return END_OF_DAY.test((subject ?? "").trim());
}

const MONTHS = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];

/**
 * A day, if the three numbers make one. Null rather than a guess.
 *
 * The calendar is asked, not just the ranges: 31 February passes a check that
 * only knows days run to 31, and a report filed on a day that does not exist
 * is worse than one filed on the day it arrived.
 */
function asDay(year: number, month: number, dayOfMonth: number): string | null {
  const full = year < 100 ? year + 2000 : year;
  if (month < 1 || month > 12 || dayOfMonth < 1 || dayOfMonth > 31) return null;
  if (full < 2000 || full > 2100) return null;
  const iso = `${full}-${String(month).padStart(2, "0")}-${String(dayOfMonth).padStart(2, "0")}`;
  const parsed = new Date(`${iso}T00:00:00Z`);
  return parsed.getUTCMonth() + 1 === month && parsed.getUTCDate() === dayOfMonth ? iso : null;
}

/**
 * The day a subject line is about.
 *
 * "Thomas EOD Report 5.13.26", "MAE_EOD_JUNE 1, 2026", "EOD 5/13" - the shapes
 * the practice's own filenames already use. A two-digit year is this century;
 * a missing year is this one. Null when there is no date in it at all, and
 * then the day it was sent is used instead.
 */
export function dayFromSubject(subject: string | null | undefined): string | null {
  const text = (subject ?? "").trim();
  if (!text) return null;
  const thisYear = new Date().getUTCFullYear();

  // The boundaries are written out rather than left to \b, because \b counts
  // an underscore as part of a word and the practice's own filenames are full
  // of them: in "MAE_EOD_JUNE 1, 2026" there is no \b before JUNE.

  // 2026-10-18, written out in full.
  for (const m of text.matchAll(/(?<![0-9])(\d{4})-(\d{1,2})-(\d{1,2})(?![0-9])/g)) {
    const day = asDay(Number(m[1]), Number(m[2]), Number(m[3]));
    if (day) return day;
  }

  // 5/13/26, 5.13.2026, 5-13. Every match is tried rather than only the
  // first: a subject can carry a time or a version before the date it means,
  // and stopping at the first thing shaped like a date would take that.
  for (const m of text.matchAll(
    /(?<![0-9])(\d{1,2})[./-](\d{1,2})(?:[./-](\d{2,4}))?(?![0-9])/g,
  )) {
    const day = asDay(m[3] ? Number(m[3]) : thisYear, Number(m[1]), Number(m[2]));
    if (day) return day;
  }

  // JUNE 1, 2026
  for (const m of text.matchAll(
    /(?<![a-z0-9])(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+(\d{1,2})(?:\s*,?\s*(\d{4}))?(?![0-9])/gi,
  )) {
    const day = asDay(
      m[3] ? Number(m[3]) : thisYear,
      MONTHS.indexOf(m[1].toLowerCase()) + 1,
      Number(m[2]),
    );
    if (day) return day;
  }

  return null;
}
