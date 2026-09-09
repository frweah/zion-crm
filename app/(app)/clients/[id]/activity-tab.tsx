import Link from "next/link";

export type ActivityRow = {
  at: string;
  kind: string;
  title: string;
  detail: string;
  who: string | null;
  tab: string;
  ref_id: string;
};

/** The kinds, in the order the chips are shown. */
export const ACTIVITY_KINDS = [
  "Note",
  "Job",
  "Interview",
  "Task",
  "Form",
  "Counselor",
  "Stage",
  "Placement",
  "Retention",
  "Appointment",
  "Mail",
  "Hours",
] as const;

const WINDOWS = [
  { days: 30, label: "Last 30 days" },
  { days: 90, label: "Last 90 days" },
  { days: 365, label: "Last year" },
  { days: 0, label: "Everything" },
];

/**
 * Where an item goes when you click it.
 *
 * Most things live on a tab of this client's record. Counselor contacts do
 * not — they are kept against the counselor, on their own screen — so that one
 * leaves the client record rather than pretending to a tab that does not
 * exist.
 */
function hrefFor(clientId: string, row: ActivityRow): string {
  if (row.tab === "counselors") return "/counselors";
  return `/clients/${clientId}?tab=${row.tab}`;
}

const dayOf = (iso: string) =>
  new Date(iso).toLocaleDateString("en-US", {
    weekday: "short",
    month: "short",
    day: "numeric",
    year: "numeric",
  });

export function ActivityTab({
  clientId,
  rows,
  days,
  kind,
  counts,
}: {
  clientId: string;
  rows: ActivityRow[];
  days: number;
  kind: string | null;
  counts: Map<string, number>;
}) {
  const base = `/clients/${clientId}?tab=activity`;
  const keep = (k: string | null, d: number) =>
    `${base}${k ? `&kind=${encodeURIComponent(k)}` : ""}${d ? `&days=${d}` : "&days=0"}`;

  // Grouped by day, so a week of activity reads as a few days rather than as
  // thirty separate lines each repeating its own date.
  const byDay = new Map<string, ActivityRow[]>();
  for (const row of rows) {
    const day = row.at.slice(0, 10);
    const list = byDay.get(day) ?? [];
    list.push(row);
    byDay.set(day, list);
  }

  return (
    <>
      <div className="card" style={{ marginBottom: 14 }}>
        <div style={{ display: "flex", flexWrap: "wrap", gap: 6, alignItems: "center" }}>
          {WINDOWS.map((w) => (
            <Link
              key={w.days}
              href={keep(kind, w.days)}
              className={"chip" + (w.days === days ? " gold" : "")}
              style={{ textDecoration: "none" }}
            >
              {w.label}
            </Link>
          ))}
        </div>

        <div style={{ display: "flex", flexWrap: "wrap", gap: 6, marginTop: 10 }}>
          <Link
            href={keep(null, days)}
            className={"chip" + (kind === null ? " gold" : "")}
            style={{ textDecoration: "none" }}
          >
            Everything
          </Link>
          {ACTIVITY_KINDS.filter((k) => (counts.get(k) ?? 0) > 0).map((k) => (
            <Link
              key={k}
              href={keep(k, days)}
              className={"chip" + (kind === k ? " gold" : "")}
              style={{ textDecoration: "none" }}
            >
              {k} {counts.get(k)}
            </Link>
          ))}
        </div>

        <p className="lock" style={{ marginTop: 10, marginBottom: 0 }}>
          Everything already recorded elsewhere, in one order. Nothing is entered here — each item
          opens where it lives.
        </p>
      </div>

      {rows.length === 0 ? (
        <div className="card">
          <p className="sub" style={{ margin: 0 }}>
            Nothing in this window.{" "}
            {days > 0 && (
              <Link href={keep(kind, 0)}>Look at everything instead</Link>
            )}
            {kind && (
              <>
                {" "}
                Or <Link href={keep(null, days)}>drop the {kind} filter</Link>.
              </>
            )}
          </p>
        </div>
      ) : (
        [...byDay.entries()].map(([day, items]) => (
          <div key={day} className="card" style={{ marginBottom: 10, padding: 0 }}>
            <h3 style={{ padding: "14px 16px 0", margin: 0, fontSize: 13 }}>
              {dayOf(items[0].at)}
            </h3>
            <table className="t">
              <tbody>
                {items.map((row) => (
                  <tr key={`${row.kind}-${row.ref_id}-${row.at}`}>
                    <td style={{ width: 110, verticalAlign: "top" }}>
                      <span className="chip">{row.kind}</span>
                    </td>
                    <td>
                      <Link href={hrefFor(clientId, row)} style={{ fontWeight: 600 }}>
                        {row.title}
                      </Link>
                      {row.detail && (
                        <div style={{ fontSize: 12, color: "var(--muted)", marginTop: 2 }}>
                          {row.detail.length > 240 ? row.detail.slice(0, 240) + "…" : row.detail}
                        </div>
                      )}
                      {row.who && <div className="lock">{row.who}</div>}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ))
      )}
    </>
  );
}
