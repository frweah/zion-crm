import { CeForm, type StatusRow } from "../admin/staff/credentials";

const TONE: Record<string, string> = {
  Expired: "bad",
  Missing: "bad",
  Expiring: "warn",
  Outstanding: "warn",
  Valid: "ok",
  Met: "ok",
};

export type CeRow = {
  id: string;
  on_date: string;
  hours: number;
  topic: string;
  provider: string;
};

/**
 * Your own certifications.
 *
 * Read-only apart from the hours, and that split is the point: a certificate
 * is recorded by whoever checked it, so seeing your own here and being unable
 * to change it is correct. Continuing education is the opposite — you were
 * the one in the room.
 */
export function MyCredentials({
  staffId,
  rows,
  ce,
  today,
}: {
  staffId: string;
  rows: StatusRow[];
  ce: CeRow[];
  today: string;
}) {
  if (rows.length === 0) return null;

  const problems = rows.filter((r) =>
    ["Expired", "Missing", "Expiring", "Outstanding"].includes(r.state),
  );
  const hoursRow = rows.find((r) => r.kind === "hours");

  return (
    <>
      <div className="card" style={{ marginTop: 14, padding: 0 }}>
        <div style={{ padding: "16px 16px 0" }}>
          <h3 style={{ margin: 0 }}>Your certifications</h3>
          <p className="sub" style={{ margin: "4px 0 0" }}>
            {problems.length === 0 ? (
              "Everything you need is on file and current."
            ) : (
              <>
                <b style={{ color: "var(--bad)" }}>
                  {problems.length} {problems.length === 1 ? "needs" : "need"} attention
                </b>{" "}
                — the administrator records these once they have seen the card, so send it to them
                rather than waiting to be asked.
              </>
            )}
          </p>
        </div>

        <table className="t">
          <tbody>
            {rows.map((r) => (
              <tr key={r.type_key}>
                <td style={{ width: 210 }}>
                  {r.label}
                  {!r.required && <div className="lock">not required of you</div>}
                </td>
                <td style={{ width: 130 }}>
                  <span className={"chip " + (TONE[r.state] ?? "")}>{r.state}</span>
                </td>
                <td>
                  {r.kind === "hours" ? (
                    <>
                      {Number(r.hours_this_year)} of {Number(r.hours_target ?? 0)} hours this year
                    </>
                  ) : r.expires_on ? (
                    <>
                      {r.state === "Expired" ? "ran out" : "until"} {r.expires_on}
                      {r.days_left !== null && r.days_left >= 0 && (
                        <span className="lock"> · {r.days_left} days</span>
                      )}
                    </>
                  ) : r.issued_on ? (
                    <>issued {r.issued_on}</>
                  ) : (
                    <span className="lock">nothing on file</span>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {hoursRow && (
        <div className="card" style={{ marginTop: 14 }}>
          <h3 style={{ marginTop: 0 }}>Log training you have done</h3>
          <p className="sub" style={{ marginTop: 0 }}>
            {Number(hoursRow.hours_this_year)} of {Number(hoursRow.hours_target ?? 0)} hours so far
            this year. Log it as you do it — a year-end scramble to remember what you attended is
            how hours go missing.
          </p>

          <CeForm staffId={staffId} today={today} />

          {ce.length > 0 && (
            <table className="t" style={{ marginTop: 12 }}>
              <tbody>
                {ce.map((e) => (
                  <tr key={e.id}>
                    <td style={{ width: 110, whiteSpace: "nowrap" }}>{e.on_date}</td>
                    <td style={{ width: 70 }}>{Number(e.hours)} hrs</td>
                    <td>
                      {e.topic}
                      {e.provider && <div className="lock">{e.provider}</div>}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </div>
      )}
    </>
  );
}
