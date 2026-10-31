import { NextResponse, type NextRequest } from "next/server";
import { today } from "@/lib/constants";
import { createAdminClient } from "@/lib/supabase/admin";
import {
  caseloadForReports,
  draftMonth,
  draftWeek,
  lastWeekOf,
  monthlyDueOn,
  weeklyDueOn,
} from "@/lib/report-drafts";
import { addDays, mondayOf, monthStartOf, previousMonthOf } from "@/lib/report-period";

/**
 * Drafting the reports.
 *
 * Monday morning, a week for every client the practice is working with. The
 * first of the month, a month assembled out of those weeks. The brief asked
 * for the month; the owner's amendment asked for the week first and the month
 * made of weeks, which is why one route does both — they are the same act at
 * two sizes and splitting them would mean two things to keep in step.
 *
 * **Run daily, and let the route decide.** pg_cron schedules in UTC and the
 * practice lives in Mountain time, so a job set for the 1st at 06:00 Mountain
 * is really 13:00 UTC in summer and 12:00 in winter, and the two days a year
 * the clock moves are exactly the days a month could be skipped or drafted
 * twice. So the schedule is every day and the question "is it the 1st in
 * Utah" is asked here, where there is a timezone library. The unique key on
 * client and month (0260) is the other half: a second run drafts nothing new.
 *
 *   curl -H "Authorization: Bearer $CRON_SECRET" https://APP/api/cron/reports
 *   ...?dry=1              what today would do, writing nothing
 *   ...?week=2026-10-20    that week, whatever day it is
 *   ...?month=2026-10      that month, whatever day it is
 */
export const dynamic = "force-dynamic";
export const maxDuration = 300;

export async function POST(request: NextRequest) {
  return handle(request);
}

export async function GET(request: NextRequest) {
  return handle(request);
}

async function handle(request: NextRequest) {
  const secret = process.env.CRON_SECRET;
  const provided =
    request.headers.get("authorization")?.replace(/^Bearer\s+/i, "") ??
    request.nextUrl.searchParams.get("secret");
  if (!secret || provided !== secret) {
    return NextResponse.json({ error: "Not authorised." }, { status: 401 });
  }

  const dry = request.nextUrl.searchParams.get("dry") === "1";
  const askedWeek = request.nextUrl.searchParams.get("week");
  const askedMonth = request.nextUrl.searchParams.get("month");

  const now = today();
  // Monday in Utah, read off the practice date rather than the server clock.
  const isMonday = new Date(`${now}T00:00:00Z`).getUTCDay() === 1;
  const isFirst = now.endsWith("-01");

  const week = askedWeek ? mondayOf(askedWeek) : isMonday && !askedMonth ? lastWeekOf(now) : null;
  const month = askedMonth
    ? monthStartOf(askedMonth.length === 7 ? `${askedMonth}-01` : askedMonth)
    : isFirst && !askedWeek
      ? previousMonthOf(now)
      : null;

  const admin = createAdminClient();

  if (dry) {
    const caseload = await caseloadForReports(admin);
    const [weekRows, monthRows] = await Promise.all([
      week
        ? admin.from("client_weekly_reports").select("client_id, status").eq("week_start", week)
        : Promise.resolve({ data: [] as { client_id: string; status: string }[] }),
      month
        ? admin.from("client_reports").select("client_id, status").eq("template", "Monthly client report").eq("period", month)
        : Promise.resolve({ data: [] as { client_id: string; status: string }[] }),
    ]);
    return NextResponse.json({
      dry: true,
      today: now,
      caseload: caseload.length,
      week: week && {
        week_start: week,
        covers: `${week} to ${addDays(week, 6)}`,
        due_on: weeklyDueOn(week),
        held: (weekRows.data ?? []).length,
        would_leave_alone: (weekRows.data ?? []).filter((r) => r.status !== "Draft").length,
      },
      month: month && {
        month,
        due_on: monthlyDueOn(month),
        held: (monthRows.data ?? []).length,
        would_leave_alone: (monthRows.data ?? []).filter((r) => r.status !== "Draft").length,
      },
      clients: caseload.map((c) => c.name),
    });
  }

  const weekly = week ? await draftWeek(admin, week) : [];
  const monthly = month ? await draftMonth(admin, month) : [];

  const tally = (rows: { did: string }[]) => ({
    made: rows.filter((r) => r.did === "made").length,
    redrafted: rows.filter((r) => r.did === "redrafted").length,
    left_alone: rows.filter((r) => r.did === "left alone").length,
    frozen: rows.filter((r) => r.did === "frozen").length,
  });

  return NextResponse.json({
    today: now,
    week: week && { week_start: week, ...tally(weekly), reports: weekly },
    month: month && { month, ...tally(monthly), reports: monthly },
  });
}
