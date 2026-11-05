import Link from "next/link";
import { requireAdmin } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { today } from "@/lib/constants";
import { PageHead } from "../../page-head";
import { DataTable } from "../../data-table";
import { HoursExport } from "./export";
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
  const [{ data: weeks }, { data: waiting }, { data: period }] = await Promise.all([
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

  const hhmm = (seconds: number) =>
    `${Math.floor(seconds / 3600)}h ${String(Math.floor((seconds % 3600) / 60)).padStart(2, "0")}m`;

  const total = [...people.values()].reduce((s, p) => s + p.hours, 0);
  const employees = [...people.values()].filter((p) => p.type === "Employee").length;

  return (
    <>
      <PageHead
        title="Hours"
        context="Everybody's clocked time, a period at a time"
        actions={<HoursExport rows={inScope} scope={show} />}
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
