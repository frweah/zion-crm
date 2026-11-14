"use client";

/**
 * The hours, as a file payroll can read.
 *
 * Built in the browser from the rows already on the screen rather than fetched
 * again: what somebody exports should be what they are looking at, and a
 * second query is a second chance for the two to differ.
 *
 * **One line per person per day** (owner, 14 November 2026), with the number
 * of segments on it. A day is what somebody worked; the week is what the
 * over-forty rule is about, so the week each day falls in is a column rather
 * than a separate kind of line. A payroll clerk can add days into weeks and
 * weeks into a period; nobody given a fortnight's total can take it apart.
 */
export type DayRow = {
  staff_name: string;
  employment_type: string;
  day: string;
  week_start: string;
  worked_hours: number;
  break_seconds: number;
  segments: number;
  first_in: string | null;
  last_out: string | null;
  accounted_for: boolean;
};

const hm = (at: string | null) =>
  at
    ? new Date(at).toLocaleTimeString("en-US", {
        timeZone: "America/Denver",
        hour: "2-digit",
        minute: "2-digit",
        hour12: false,
      })
    : "";

function toCsv(rows: DayRow[]): string {
  const head = [
    "Name",
    "Engagement",
    "Day",
    "Week starting",
    "First in",
    "Last out",
    "Worked hours",
    "Break hours",
    "Segments",
    "Accounted for",
  ];
  // A field is quoted and its quotes doubled, which is the whole of CSV that
  // matters — a name with a comma in it is the usual way an export arrives
  // one column short.
  const cell = (v: string | number | boolean) => {
    const s = String(v);
    return /[",\n]/.test(s) ? `"${s.split('"').join('""')}"` : s;
  };
  return [
    head,
    ...rows.map((r) => [
      r.staff_name,
      r.employment_type,
      r.day,
      r.week_start,
      hm(r.first_in),
      hm(r.last_out),
      Number(r.worked_hours).toFixed(2),
      (Number(r.break_seconds) / 3600).toFixed(2),
      r.segments,
      r.accounted_for ? "yes" : "no",
    ]),
  ]
    .map((line) => line.map(cell).join(","))
    .join("\n");
}

export function HoursExport({ rows, scope }: { rows: DayRow[]; scope: string }) {
  if (rows.length === 0) return null;

  const download = () => {
    const blob = new Blob([toCsv(rows)], { type: "text/csv;charset=utf-8" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `hours-${scope}-${new Date().toISOString().slice(0, 10)}.csv`;
    a.click();
    URL.revokeObjectURL(url);
  };

  return (
    <button className="btn ghost" type="button" onClick={download}>
      Export this period
    </button>
  );
}
