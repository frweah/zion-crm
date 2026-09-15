/**
 * One section of a gathered record.
 *
 * Rendered from whatever shape the database returned rather than from a fixed
 * list of columns, on purpose: a records request has to include everything,
 * and a hand-written column list is a promise to forget the next column
 * somebody adds. The cost is that the labels are the database's names tidied
 * up, which is a fair trade for a document whose whole claim is completeness.
 */

const HIDE = new Set([
  "client_id",
  "staff_id",
  "auth_id",
  "created_by",
  "updated_at",
  "created_at",
  "id",
]);

const label = (k: string) => k.replace(/_/g, " ").replace(/^./, (c) => c.toUpperCase());

function show(value: unknown): string {
  if (value === null || value === undefined || value === "") return "—";
  if (typeof value === "boolean") return value ? "Yes" : "No";
  if (Array.isArray(value)) return value.length ? value.join(", ") : "—";
  if (typeof value === "object") {
    return Object.entries(value as Record<string, unknown>)
      .map(([k, v]) => `${label(k)}: ${show(v)}`)
      .join(" · ");
  }
  const s = String(value);
  // ISO timestamps read badly in a document somebody is handing over.
  if (/^\d{4}-\d{2}-\d{2}T/.test(s)) return new Date(s).toLocaleString();
  return s;
}

export function Section({
  title,
  data,
  rows,
  highlight,
}: {
  title: string;
  /** A single record — the client, the intake. */
  data?: unknown;
  /** Many records. */
  rows?: Record<string, unknown>[];
  /**
   * A column whose value marks an entry as written for a narrower audience.
   * Shown as a warning rather than a cell, because it is the thing the person
   * reviewing this has to notice.
   */
  highlight?: string;
}) {
  if (data) {
    const entries = Object.entries(data as Record<string, unknown>).filter(
      ([k]) => !HIDE.has(k),
    );
    return (
      <div className="card" style={{ marginTop: 14 }}>
        <h3 style={{ marginTop: 0 }}>{title}</h3>
        <table className="t">
          <tbody>
            {entries.map(([k, v]) => (
              <tr key={k}>
                <td style={{ width: 220 }}>{label(k)}</td>
                <td>{show(v)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    );
  }

  const list = rows ?? [];

  return (
    <div className="card" style={{ marginTop: 14 }}>
      <h3 style={{ marginTop: 0 }}>
        {title}{" "}
        <span className="lock" style={{ fontWeight: 400 }}>
          {list.length === 0 ? "none" : `${list.length} entr${list.length === 1 ? "y" : "ies"}`}
        </span>
      </h3>

      {list.map((row, i) => {
        const restricted =
          highlight && Array.isArray(row[highlight]) && (row[highlight] as string[]).length < 4;
        return (
          <div key={i} className="noteitem" style={{ breakInside: "avoid" }}>
            {restricted && (
              <div className="meta">
                <b style={{ color: "var(--ink)" }}>
                  Written for {(row[highlight!] as string[]).join(", ")} only — check before
                  disclosing
                </b>
              </div>
            )}
            <table className="t">
              <tbody>
                {Object.entries(row)
                  .filter(([k]) => !HIDE.has(k))
                  .map(([k, v]) => (
                    <tr key={k}>
                      <td style={{ width: 220 }}>{label(k)}</td>
                      <td>{show(v)}</td>
                    </tr>
                  ))}
              </tbody>
            </table>
          </div>
        );
      })}
    </div>
  );
}
