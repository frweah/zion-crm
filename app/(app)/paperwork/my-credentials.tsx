import { CeForm, type StatusRow } from "../admin/staff/credentials";
import { DataTable } from "../data-table";

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
      <section style={{ marginTop: 24 }}>
        <h2 className="h2">Your certifications</h2>
        <p className="sub" style={{ margin: "0 0 10px" }}>
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

        <div className="card" style={{ padding: 0 }}>
          <DataTable
            label="certifications"
            columns={[
              { key: "label", label: "Certification", width: 210 },
              { key: "state", label: "State", width: 130 },
              { key: "detail", label: "Detail" },
            ]}
            rows={rows.map((r) => ({
              key: r.type_key,
              cells: {
                label: (
                  <>
                    {r.label}
                    {!r.required && <div className="lock">not required of you</div>}
                  </>
                ),
                state: <span className={"chip " + (TONE[r.state] ?? "")}>{r.state}</span>,
                detail:
                  r.kind === "hours" ? (
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
                  ),
              },
              sort: {
                label: r.label,
                state: r.state,
                detail: r.expires_on ?? r.issued_on ?? null,
              },
            }))}
            empty="No certifications are asked of you."
          />
        </div>
      </section>

      {hoursRow && (
        <div className="card" style={{ marginTop: 14 }}>
          <h3 style={{ marginTop: 0 }}>Log training you have done</h3>
          <p className="sub" style={{ marginTop: 0 }}>
            {Number(hoursRow.hours_this_year)} of {Number(hoursRow.hours_target ?? 0)} hours so far
            this year. Log it as you do it — a year-end scramble to remember what you attended is
            how hours go missing.
          </p>

          <CeForm staffId={staffId} today={today} />

          {/* The line above already gives the year's total, so the list only appears once there is training in it. */}
          {ce.length > 0 && (
            <div style={{ marginTop: 12 }}>
              <DataTable
                label="training"
                columns={[
                  { key: "date", label: "Date", width: 110 },
                  { key: "hours", label: "Hours", align: "right", width: 70 },
                  { key: "topic", label: "Topic" },
                ]}
                rows={ce.map((e) => ({
                  key: e.id,
                  cells: {
                    date: <span style={{ whiteSpace: "nowrap" }}>{e.on_date}</span>,
                    hours: `${Number(e.hours)} hrs`,
                    topic: (
                      <>
                        {e.topic}
                        {e.provider && <div className="lock">{e.provider}</div>}
                      </>
                    ),
                  },
                  sort: { date: e.on_date, hours: Number(e.hours), topic: e.topic },
                  text: `${e.on_date} ${e.topic} ${e.provider}`,
                }))}
                empty="No training has been logged this year."
              />
            </div>
          )}
        </div>
      )}
    </>
  );
}
