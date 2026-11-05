"use client";

/**
 * The hours, as a file payroll can read.
 *
 * Built in the browser from the rows already on the screen rather than fetched
 * again: what somebody exports should be what they are looking at, and a
 * second query is a second chance for the two to differ.
 *
 * One line per person per week, because the week is what the over-forty rule
 * is about and a payroll clerk adding weeks together can, while one who is
 * given a fortnight's total cannot take it apart.
 */
type Row = {
  staff_name: string;
  employment_type: string;
  week_start: string;
  period_start: string;
  period_end: string;
  hours: number;
  break_seconds: number;
  sessions: number;
  over_forty: boolean;
};

function toCsv(rows: Row[]): string {
  const head = [
    "Name",
    "Engagement",
    "Week starting",
    "Pay period start",
    "Pay period end",
    "Hours",
    "Break hours",
    "Sessions",
    "Over 40",
  ];
  // A field is quoted and its quotes doubled, which is the whole of CSV that
  // matters — a name with a comma in it is the usual way an export arrives
  // one column short.
  const cell = (v: string | number | boolean) => {
    const s = String(v);
    return /[",\n]/.test(s) ? `"${s.split('"').join('""')}"` : s;
  };
  return [head, ...rows.map((r) => [
    r.staff_name,
    r.employment_type,
    r.week_start,
    r.period_start,
    r.period_end,
    Number(r.hours).toFixed(2),
    (Number(r.break_seconds) / 3600).toFixed(2),
    r.sessions,
    r.over_forty ? "yes" : "",
  ])]
    .map((line) => line.map(cell).join(","))
    .join("\n");
}

export function HoursExport({ rows, scope }: { rows: Row[]; scope: string }) {
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
