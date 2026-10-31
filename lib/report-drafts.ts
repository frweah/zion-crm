import "server-only";
import type { Database } from "@/lib/database.types";
import type { SupabaseClient } from "@supabase/supabase-js";
import {
  GENERAL,
  REPORT_ROLES,
  buildPeriodContent,
  type PeriodContent,
  FAMILY_OF,
  type ReportSection,
} from "@/lib/report-period";
import {
  reportPeriodUnit,
  sectionIsIn,
  type ReportTemplate,
} from "@/lib/report-shape";
import {
  addDays,
  lastWeekOf,
  monthEndOf,
  monthStartOf,
  monthlyDueOn,
  weeklyDueOn,
  weeksAcross,
} from "@/lib/report-weeks";

/**
 * Making the drafts.
 *
 * Monday morning a week's report is drafted for every client the practice is
 * working with, and the first of the month a month's report is assembled out
 * of those weeks. Both run on the scheduler, which means both run with no
 * person behind them - so both run as the service role, which is the one
 * exception to what `createAdminClient` is for. There is nobody whose
 * row-level security could be applied, and the alternative is a report drafted
 * as whoever happens to be signed in at six in the morning, which is nobody.
 *
 * What makes that safe is not the client used to read but what is written:
 * every row carries `visible_roles`, so reading the report back is governed
 * even though building it was not, and `REPORT_ROLES` keeps a note that is not
 * for everybody from having its words copied in. See lib/report-period.ts.
 *
 * Both are idempotent and both refuse to overwrite a person's work:
 *
 *   a draft is replaced, because a draft is the machine's opinion and a newer
 *   one is better;
 *   a week somebody has confirmed keeps its lines;
 *   a month that has been signed is frozen in the database (0260) and is not
 *   offered a new draft at all.
 *
 * So the Monday job can be run twice, or late, or by hand after a fix, and
 * the worst it does is redraft what nobody has looked at yet.
 */

type Supabase = SupabaseClient<Database>;

/** A client the practice is working with, and whose week it is. */
type Caseload = { id: string; name: string; assigned_staff_id: string | null };

/**
 * The clients a report is owed for.
 *
 * Active or On hold, which is the brief's wording. Read as the status now
 * rather than the status then: `clients.status` has no history table, so a
 * client closed on the 3rd of November has no October report generated on the
 * 1st... which is why the catch-up exists and why this is said out loud here
 * rather than discovered later.
 */
export async function caseloadForReports(admin: Supabase): Promise<Caseload[]> {
  const { data, error } = await admin
    .from("clients")
    .select("id, name, assigned_staff_id")
    .in("status", ["Active", "On hold"])
    .is("merged_into", null)
    .order("name");
  if (error) throw new Error(error.message);
  return (data ?? []) as Caseload[];
}

export type DraftOutcome = {
  client_id: string;
  client: string;
  /** "made" a new draft, "redrafted" an existing one, or why nothing happened. */
  did: "made" | "redrafted" | "left alone" | "frozen";
};

// ── the week ──────────────────────────────────────────────────

export { lastWeekOf, monthlyDueOn, weeklyDueOn };

export async function draftWeek(
  admin: Supabase,
  weekStart: string,
  only?: string[],
): Promise<DraftOutcome[]> {
  const from = weekStart;
  const to = addDays(weekStart, 6);
  const caseload = (await caseloadForReports(admin)).filter(
    (c) => !only || only.includes(c.id),
  );

  const { data: existing } = await admin
    .from("client_weekly_reports")
    .select("id, client_id, status")
    .eq("week_start", weekStart);
  const already = new Map((existing ?? []).map((r) => [r.client_id, r]));

  const out: DraftOutcome[] = [];
  for (const client of caseload) {
    const row = already.get(client.id);
    if (row && row.status !== "Draft") {
      out.push({ client_id: client.id, client: client.name, did: "left alone" });
      continue;
    }

    const content = await buildPeriodContent(admin, client.id, from, to);

    if (row) {
      // The staff member's own words are left exactly where they are: this
      // replaces what was read off the record, not what somebody wrote.
      const { error } = await admin
        .from("client_weekly_reports")
        .update({
          content: content as never,
          owner_id: client.assigned_staff_id,
          generated_at: new Date().toISOString(),
        })
        .eq("id", row.id);
      out.push({
        client_id: client.id,
        client: client.name,
        did: error ? "frozen" : "redrafted",
      });
      continue;
    }

    const { error } = await admin.from("client_weekly_reports").insert({
      client_id: client.id,
      week_start: weekStart,
      owner_id: client.assigned_staff_id,
      status: "Draft",
      content: content as never,
      visible_roles: [...REPORT_ROLES],
      due_on: weeklyDueOn(weekStart),
    });
    if (error) throw new Error(error.message);
    out.push({ client_id: client.id, client: client.name, did: "made" });
  }

  return out;
}

// ── and the month it adds up to ───────────────────────────────

export type MonthlyContent = PeriodContent & {
  /** The weeks this month was assembled from, in order, with their words. */
  weeks: { week_start: string; status: string; note: string }[];
  /** Stretches of the month no weekly report covered, read off the record. */
  gaps: { from: string; to: string }[];
};

/**
 * One month's sections, out of its weeks.
 *
 * A week straddles the month boundary five times a year, so each week's lines
 * are taken by their own dates rather than by which month the week is filed
 * under. Nothing is counted twice and nothing falls down the gap, which is
 * the reason the content is dated lines instead of finished prose.
 */
function mergeSections(parts: ReportSection[][]): ReportSection[] {
  const merged = new Map<string, ReportSection>();
  for (const sections of parts) {
    for (const section of sections) {
      const held = merged.get(section.service);
      if (held) held.lines.push(...section.lines);
      else merged.set(section.service, { ...section, lines: [...section.lines] });
    }
  }
  // General last; everything else keeps the order the weeks gave it.
  const out = [...merged.values()].filter((s) => s.service !== GENERAL);
  const general = merged.get(GENERAL);
  if (general?.lines.length) out.push(general);
  for (const s of out) s.lines.sort((a, b) => (a.on < b.on ? -1 : a.on > b.on ? 1 : 0));
  return out;
}

export async function buildMonthContent(
  admin: Supabase,
  clientId: string,
  month: string,
): Promise<MonthlyContent> {
  const from = monthStartOf(month);
  const to = monthEndOf(month);

  const weekStarts = weeksAcross(from, to);
  const { data: weekRows } = await admin
    .from("client_weekly_reports")
    .select("week_start, status, note, content")
    .eq("client_id", clientId)
    .in("week_start", weekStarts)
    .order("week_start");

  const held = new Map((weekRows ?? []).map((r) => [r.week_start, r]));
  const parts: ReportSection[][] = [];
  const weeks: MonthlyContent["weeks"] = [];
  const gaps: MonthlyContent["gaps"] = [];
  let withheld = 0;

  // A run of days with no weekly report behind them, read off the record when
  // the run ends. Collected as a run rather than a day at a time so the month
  // says "4 to 10 November" instead of seven identical complaints.
  let gapFrom: string | null = null;
  const closeGap = async (gapTo: string) => {
    if (!gapFrom) return;
    const span = { from: gapFrom, to: gapTo };
    gaps.push(span);
    const content = await buildPeriodContent(admin, clientId, span.from, span.to);
    parts.push(content.sections);
    withheld += content.withheld;
    gapFrom = null;
  };

  for (const week of weekStarts) {
    // The days of this week that are inside the month.
    const sliceFrom = week < from ? from : week;
    const sliceTo = addDays(week, 6) > to ? to : addDays(week, 6);
    const row = held.get(week);

    if (!row) {
      gapFrom = gapFrom ?? sliceFrom;
      continue;
    }
    await closeGap(addDays(sliceFrom, -1));

    const content = (row.content ?? {}) as unknown as PeriodContent;
    parts.push(
      (content.sections ?? []).map((s) => ({
        ...s,
        lines: (s.lines ?? []).filter((l) => l.on >= sliceFrom && l.on <= sliceTo),
      })),
    );
    withheld += Number(content.withheld ?? 0);
    weeks.push({ week_start: week, status: row.status, note: row.note ?? "" });
  }
  await closeGap(to);

  const sections = mergeSections(parts);
  const hours = sections.reduce(
    (total, s) => total + s.lines.reduce((t, l) => t + (l.hours ?? 0), 0),
    0,
  );

  return {
    from,
    to,
    sections,
    withheld,
    hours: Math.round(hours * 100) / 100,
    weeks,
    gaps,
  };
}

export async function draftMonth(
  admin: Supabase,
  month: string,
  only?: string[],
): Promise<DraftOutcome[]> {
  const caseload = (await caseloadForReports(admin)).filter(
    (c) => !only || only.includes(c.id),
  );

  const { data: existing } = await admin
    .from("client_reports")
    .select("id, client_id, status")
    .eq("template", "Monthly client report")
    .eq("period", monthStartOf(month));
  const already = new Map((existing ?? []).map((r) => [r.client_id, r]));

  const out: DraftOutcome[] = [];
  for (const client of caseload) {
    const row = already.get(client.id);
    if (row && row.status !== "Draft") {
      out.push({ client_id: client.id, client: client.name, did: "left alone" });
      continue;
    }

    const content = await buildMonthContent(admin, client.id, month);

    if (row) {
      const { error } = await admin
        .from("client_reports")
        .update({
          content: content as never,
          owner_id: client.assigned_staff_id,
          generated_at: new Date().toISOString(),
        })
        .eq("id", row.id);
      out.push({
        client_id: client.id,
        client: client.name,
        did: error ? "frozen" : "redrafted",
      });
      continue;
    }

    const { error } = await admin.from("client_reports").insert({
      client_id: client.id,
      template: "Monthly client report",
      period: monthStartOf(month),
      owner_id: client.assigned_staff_id,
      status: "Draft",
      content: content as never,
      visible_roles: [...REPORT_ROLES],
      due_on: monthlyDueOn(month),
    });
    if (error) throw new Error(error.message);
    out.push({ client_id: client.id, client: client.name, did: "made" });
  }

  return out;
}

/**
 * Drafting one of the five (0276).
 *
 * The four that are not the monthly report are the monthly report with some
 * sections left out - the same content, built the same way, filtered. Not a
 * renderer each: a Job Coaching Update that could say something the monthly
 * report would not have said would be a second account of the same month, and
 * the counselor would have two documents to reconcile.
 *
 * `draftMonth` above is left alone. It is the nightly run over the whole
 * caseload and it makes monthly reports; this is one report for one client,
 * which is what a person pressing a button wants.
 */
export async function draftReport(
  admin: Supabase,
  template: ReportTemplate,
  period: string,
  clientId: string,
): Promise<{ did: "made" | "redrafted" | "left alone" | "frozen"; id?: string }> {
  const caseload = (await caseloadForReports(admin)).filter((c) => c.id === clientId);
  const client = caseload[0];
  if (!client) return { did: "left alone" };

  const { data: row } = await admin
    .from("client_reports")
    .select("id, status")
    .eq("client_id", clientId)
    .eq("template", template)
    .eq("period", period)
    .maybeSingle();

  if (row && row.status !== "Draft") return { did: "left alone", id: row.id };

  const unit = reportPeriodUnit(template);
  // A week is the seven days from its Monday; a month is the month. The dates
  // are the content's own, so the renderer and the PDF both read them from
  // the content rather than working them out again.
  const from = period;
  const to =
    unit === "week"
      ? new Date(Date.UTC(
          Number(period.slice(0, 4)),
          Number(period.slice(5, 7)) - 1,
          Number(period.slice(8, 10)) + 6,
        )).toISOString().slice(0, 10)
      : lastDayOf(period);

  const whole =
    unit === "month"
      ? await buildMonthContent(admin, clientId, period)
      : ((await buildPeriodContent(admin, clientId, from, to)) as unknown as MonthlyContent);

  // Only the sections this template carries. The withheld count and the hours
  // are the period's, not the section's, so they stay as they are: a report
  // that said "no notes were withheld" because the withheld one was in a
  // section this template leaves out would be saying something untrue.
  const content: MonthlyContent = {
    ...whole,
    sections: whole.sections.filter((s) =>
      sectionIsIn(template, s.service === GENERAL ? null : (FAMILY_OF[s.service] ?? null)),
    ),
  };

  if (row) {
    const { error } = await admin
      .from("client_reports")
      .update({
        content: content as never,
        owner_id: client.assigned_staff_id,
        generated_at: new Date().toISOString(),
      })
      .eq("id", row.id);
    return { did: error ? "frozen" : "redrafted", id: row.id };
  }

  const { data: made, error } = await admin
    .from("client_reports")
    .insert({
      client_id: clientId,
      template,
      period,
      owner_id: client.assigned_staff_id,
      status: "Draft",
      content: content as never,
      visible_roles: [...REPORT_ROLES],
      due_on: unit === "week" ? weeklyDueOn(period) : monthlyDueOn(period),
    })
    .select("id")
    .single();
  if (error) throw new Error(error.message);
  return { did: "made", id: made.id };
}

/** The last day of the month a date starts. */
function lastDayOf(monthStart: string): string {
  const d = new Date(`${monthStart}T00:00:00Z`);
  return new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + 1, 0))
    .toISOString()
    .slice(0, 10);
}
