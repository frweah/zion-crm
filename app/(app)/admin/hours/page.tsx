import Link from "next/link";
import { requireAdmin } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { today, PRACTICE_TZ } from "@/lib/constants";
import { PageHead } from "../../page-head";
import { DataTable } from "../../data-table";
import { HoursExport, type DayRow } from "./export";
import { Decide } from "./decide";

/**
 * Admin → Hours: everybody's clocked time, a period at a time.
 *
 * One table, one period, one line per person — not a line per session, because
 * the question this screen answers is "what did the practice work and what
 * does payroll owe", and a hundred sessions is the wrong altitude for that.
 * The sessions are on each person's own record.
 *
 * The week is its own column rather than something worked out here. The pay
 * period may be a fortnight and the over-forty rule is a week's rule, so a
 * screen that only knew the period could not answer it (0293).
 */
const PERIODS = [
  { key: "period", label: "This pay period" },
  { key: "week", label: "This week" },
  { key: "month", label: "This month" },
  { key: "all", label: "Everything" },
] as const;

type Week = {
  staff_id: string;
  staff_name: string;
  staff_role: string;
  employment_type: string;
  week_start: string;
  period_start: string;
  period_end: string;
  hours: number;
  break_seconds: number;
  sessions: number;
  over_forty: boolean;
};

export default async function AdminHoursPage({
  searchParams,
}: {
  searchParams: Promise<{ show?: string }>;
}) {
  await requireAdmin();
  const asked = (await searchParams).show;
  const show = PERIODS.some((p) => p.key === asked) ? asked! : "period";

  const supabase = await createClient();
  const [{ data: weeks }, { data: waiting }, { data: period }, { data: dayRows }, { data: segmentRows }] =
    await Promise.all([
    supabase.from("hours_by_week").select("*").order("week_start", { ascending: false }),
    // Corrections somebody has to decide. Here rather than on a screen of
    // their own: an Admin looking at the hours is the person who can settle
    // them, and a separate queue is a queue nobody opens.
    supabase
      .from("work_sessions")
      .select("id, staff_id, worked_on, hours, correction_reason, corrects_id, approver_id, created_at")
      .eq("approval", "Waiting")
      .order("created_at", { ascending: false }),
    supabase.from("work_session_totals").select("period_start, period_end").limit(1).maybeSingle(),
    /*
     * The day as a row, which is what the owner asked the export to be
     * (14 Nov 2026). Everything, filtered below to whichever period is on
     * screen - the same filtering the weeks already get, so the table and
     * the export cannot end up describing different stretches of time.
     */
    supabase
      .from("work_days")
      .select(
        "staff_id, staff_name, employment_type, day, segments, worked_hours, break_seconds, first_in, last_out, accounted_for, needs_an_account",
      )
      .order("day", { ascending: false }),
    // And the segments themselves, for the day rows to open into.
    supabase
      .from("work_sessions")
      .select("id, staff_id, worked_on, hours, break_seconds, started_at, ended_at, description, category, auto_closed")
      .eq("voided", false)
      .order("started_at", { ascending: true, nullsFirst: false }),
  ]);

  const rows = (weeks ?? []) as unknown as Week[];
  const day = today();
  const monday = (() => {
    const d = new Date(`${day}T00:00:00Z`);
    const iso = d.getUTCDay() === 0 ? 7 : d.getUTCDay();
    d.setUTCDate(d.getUTCDate() - (iso - 1));
    return d.toISOString().slice(0, 10);
  })();
  const monthStart = `${day.slice(0, 7)}-01`;

  const inScope = rows.filter((r) => {
    if (show === "all") return true;
    if (show === "week") return r.week_start === monday;
    if (show === "month") return r.week_start >= monthStart;
    return day >= r.period_start && day <= r.period_end;
  });

  // One line per person, from the weeks in scope.
  const people = new Map<
    string,
    { name: string; role: string; type: string; hours: number; breaks: number; sessions: number; over: number }
  >();
  for (const r of inScope) {
    const p =
      people.get(r.staff_id) ??
      { name: r.staff_name, role: r.staff_role, type: r.employment_type, hours: 0, breaks: 0, sessions: 0, over: 0 };
    p.hours += Number(r.hours);
    p.breaks += Number(r.break_seconds);
    p.sessions += Number(r.sessions);
    if (r.over_forty) p.over += 1;
    people.set(r.staff_id, p);
  }

  /*
   * The days in the same stretch of time as the weeks above.
   *
   * The week a day falls in is worked out here rather than asked of the
   * database, because it is the same arithmetic the screen already does for
   * "this week" and two answers to "which week is this" is how a payroll
   * export and a payroll screen come to disagree.
   */
  const weekOf = (d: string) => {
    const at = new Date(`${d}T00:00:00Z`);
    const iso = at.getUTCDay() === 0 ? 7 : at.getUTCDay();
    at.setUTCDate(at.getUTCDate() - (iso - 1));
    return at.toISOString().slice(0, 10);
  };
  const allDays = ((dayRows ?? []) as {
    staff_id: string;
    staff_name: string;
    employment_type: string;
    day: string;
    segments: number | string;
    worked_hours: number | string;
    break_seconds: number | string;
    first_in: string | null;
    last_out: string | null;
    accounted_for: boolean;
    needs_an_account: boolean;
  }[]).filter((d) => {
    if (show === "all") return true;
    if (show === "week") return weekOf(d.day) === monday;
    if (show === "month") return d.day >= monthStart;
    return (
      period?.period_start !== undefined &&
      d.day >= String(period.period_start) &&
      d.day <= String(period.period_end)
    );
  });

  const days: (DayRow & { staff_id: string; needs_an_account: boolean })[] = allDays.map((d) => ({
    staff_id: d.staff_id,
    staff_name: d.staff_name,
    employment_type: d.employment_type,
    day: d.day,
    week_start: weekOf(d.day),
    worked_hours: Number(d.worked_hours),
    break_seconds: Number(d.break_seconds),
    segments: Number(d.segments),
    first_in: d.first_in,
    last_out: d.last_out,
    accounted_for: d.accounted_for,
    needs_an_account: d.needs_an_account,
  }));

  const segmentsOf = new Map<string, {
    id: string;
    hours: number;
    break_seconds: number;
    started_at: string | null;
    ended_at: string | null;
    description: string;
    auto_closed: boolean;
  }[]>();
  for (const seg of (segmentRows ?? []) as {
    id: string;
    staff_id: string;
    worked_on: string;
    hours: number | string;
    break_seconds: number | string;
    started_at: string | null;
    ended_at: string | null;
    description: string | null;
    auto_closed: boolean;
  }[]) {
    const key = `${seg.staff_id}:${seg.worked_on}`;
    const list = segmentsOf.get(key) ?? [];
    list.push({
      id: seg.id,
      hours: Number(seg.hours),
      break_seconds: Number(seg.break_seconds ?? 0),
      started_at: seg.started_at,
      ended_at: seg.ended_at,
      description: seg.description ?? "",
      auto_closed: seg.auto_closed,
    });
    segmentsOf.set(key, list);
  }

  const clockTime = (at: string | null) =>
    at
      ? new Date(at).toLocaleTimeString("en-US", {
          timeZone: PRACTICE_TZ,
          hour: "numeric",
          minute: "2-digit",
        })
      : "—";

  const hhmm = (seconds: number) =>
    `${Math.floor(seconds / 3600)}h ${String(Math.floor((seconds % 3600) / 60)).padStart(2, "0")}m`;

  const total = [...people.values()].reduce((s, p) => s + p.hours, 0);
  const employees = [...people.values()].filter((p) => p.type === "Employee").length;

  return (
    <>
      <PageHead
        title="Hours"
        context="Everybody's clocked time, a period at a time"
        actions={<HoursExport rows={days} scope={show} />}
      />

      <div className="row2 no-print" style={{ marginBottom: 12 }}>
        <div className="segmented" role="group" aria-label="Which period">
          {PERIODS.map((p) => (
            <Link key={p.key} href={`/admin/hours?show=${p.key}`} className={p.key === show ? "on" : undefined}>
              {p.label}
            </Link>
          ))}
        </div>
      </div>

      {(waiting ?? []).length > 0 && (
        <section className="card" style={{ marginBottom: 14 }} aria-label="Corrections waiting">
          <h2 className="h2">Corrections waiting</h2>
          <ul className="day-list">
            {(waiting ?? []).map((c) => (
              <li key={c.id}>
                <span className="day-main">
                  <b>{people.get(c.staff_id)?.name ?? "Somebody"}</b>{" "}
                  <span className="lock">
                    {c.worked_on} · {Number(c.hours).toFixed(2)}h · {c.correction_reason}
                  </span>
                </span>
                <Decide correctionId={c.id} />
              </li>
            ))}
          </ul>
        </section>
      )}

      <div className="card" style={{ padding: 0 }}>
        <DataTable
          label="people"
          sortBy
          columns={[
            { key: "who", label: "Who" },
            { key: "type", label: "Engagement" },
            { key: "hours", label: "Hours", align: "right" },
            { key: "breaks", label: "Break", align: "right" },
            { key: "sessions", label: "Sessions", align: "right" },
          ]}
          rows={[...people].map(([id, p]) => ({
            key: id,
            cells: {
              who: (
                <>
                  <Link href={`/admin/people/${id}`} style={{ color: "var(--teal)" }}>
                    <b>{p.name}</b>
                  </Link>
                  {p.over > 0 && (
                    <div>
                      <span className="chip warn">
                        over 40 in {p.over} {p.over === 1 ? "week" : "weeks"}
                      </span>
                    </div>
                  )}
                </>
              ),
              type: <span className="lock">{p.type}</span>,
              hours: p.hours.toFixed(2),
              breaks: <span className="lock">{hhmm(p.breaks)}</span>,
              sessions: <span className="lock">{p.sessions}</span>,
            },
            sort: { who: p.name, type: p.type, hours: p.hours, breaks: p.breaks, sessions: p.sessions },
            text: `${p.name} ${p.role} ${p.type}`,
          }))}
          empty="Nobody has clocked any time in this period."
        />
      </div>

      <section className="page-section">
        <h2 className="h2">Days</h2>
        {days.length === 0 ? (
          <p className="empty">Nobody has clocked a day in this period.</p>
        ) : (
          <div className="card" style={{ padding: 0 }}>
            <table className="t" data-layout="one line per person per day, opening into the segments it was worked in">
              <thead>
                <tr>
                  <th>Who</th>
                  <th>Day</th>
                  <th style={{ textAlign: "right" }}>Worked</th>
                  <th style={{ textAlign: "right" }}>Break</th>
                  <th style={{ textAlign: "right" }}>Segments</th>
                  <th>Said what it was</th>
                </tr>
              </thead>
              <tbody>
                {days.map((d) => {
                  const segs = segmentsOf.get(`${d.staff_id}:${d.day}`) ?? [];
                  return (
                    <tr key={`${d.staff_id}:${d.day}`}>
                      <td>
                        <Link href={`/admin/people/${d.staff_id}`} style={{ color: "var(--teal)" }}>
                          {d.staff_name}
                        </Link>
                      </td>
                      <td>
                        <Link href={`/end-of-day?who=${d.staff_id}&day=${d.day}`}>{d.day}</Link>
                        {segs.length > 1 && (
                          <details style={{ marginTop: 4 }}>
                            <summary className="lock">
                              {clockTime(d.first_in)} to {clockTime(d.last_out)}
                            </summary>
                            <ul className="day-list" style={{ marginTop: 4 }}>
                              {segs.map((seg) => (
                                <li key={seg.id}>
                                  <span className="lock">
                                    {clockTime(seg.started_at)}–{clockTime(seg.ended_at)} ·{" "}
                                    {seg.hours.toFixed(2)}h
                                    {seg.break_seconds > 0
                                      ? ` · ${Math.round(seg.break_seconds / 60)} min break`
                                      : ""}
                                    {seg.auto_closed ? " · closed for them" : ""}
                                  </span>{" "}
                                  {seg.description || <span className="lock">nothing said</span>}
                                </li>
                              ))}
                            </ul>
                          </details>
                        )}
                        {segs.length === 1 && (
                          <div className="lock">
                            {clockTime(d.first_in)} to {clockTime(d.last_out)}
                          </div>
                        )}
                      </td>
                      <td style={{ textAlign: "right" }}>{d.worked_hours.toFixed(2)}</td>
                      <td style={{ textAlign: "right" }} className="lock">
                        {d.break_seconds > 0 ? hhmm(d.break_seconds) : "—"}
                      </td>
                      <td style={{ textAlign: "right" }}>{d.segments}</td>
                      <td>
                        {d.accounted_for ? (
                          <span className="chip ok">Yes</span>
                        ) : d.needs_an_account ? (
                          <span className="chip warn">Waiting</span>
                        ) : (
                          <span className="lock">—</span>
                        )}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </section>

      <p className="lock" style={{ marginTop: 12 }}>
        {total.toFixed(2)} hours across {people.size} {people.size === 1 ? "person" : "people"}
        {employees > 0 ? `, ${employees} on payroll` : ""}. Over 40 is flagged for employees.
      </p>
      {period && (
        <p className="lock" style={{ marginTop: 4 }}>
          This pay period runs {period.period_start} to {period.period_end}.
        </p>
      )}
    </>
  );
}
