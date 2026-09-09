import Link from "next/link";

export type PaperworkRow = {
  auth_number: string | null;
  service_type: string | null;
  usor: string | null;
  form_name: string | null;
  month: string | null;
  state: string;
  form_id: string | null;
  hours_logged: number | null;
};

const TONE: Record<string, string> = {
  Complete: "ok",
  "In progress": "warn",
  Missing: "bad",
  "Not started": "",
};

/**
 * What USOR still wants for this client's open authorizations.
 *
 * Missing is the only one that means somebody is late: hours are logged and
 * the form that gates the invoice is not done. Not started is the same form
 * before any hours exist, which is not a problem and should not look like one
 * — showing them the same colour is how a strip like this stops being read.
 */
export function PaperworkStrip({
  clientId,
  rows,
}: {
  clientId: string;
  rows: PaperworkRow[];
}) {
  if (rows.length === 0) {
    return (
      <div className="card" style={{ marginTop: 14 }}>
        <h3 style={{ margin: 0 }}>Paperwork</h3>
        <p className="sub" style={{ margin: "4px 0 0" }}>
          No open authorization needs a USOR form yet.
        </p>
      </div>
    );
  }

  const missing = rows.filter((r) => r.state === "Missing").length;
  const complete = rows.filter((r) => r.state === "Complete").length;

  return (
    <div className="card" style={{ marginTop: 14, padding: 0 }}>
      <div style={{ padding: "16px 16px 0" }}>
        <h3 style={{ margin: 0 }}>Paperwork</h3>
        <p className="sub" style={{ margin: "4px 0 0" }}>
          {missing > 0 ? (
            <b style={{ color: "var(--bad)" }}>
              {missing} blocking billing
            </b>
          ) : (
            "Nothing blocking billing"
          )}
          {" · "}
          {complete} of {rows.length} complete
        </p>
      </div>

      <table className="t">
        <tbody>
          {rows.map((r, i) => (
            <tr key={`${r.usor}-${r.month}-${i}`}>
              <td>
                <b>{r.usor}</b>
                {r.month && <span className="lock"> {r.month}</span>}
                <div style={{ fontSize: 12, color: "var(--muted)" }}>
                  {r.form_name}
                </div>
                <div className="lock">
                  {r.service_type}
                  {r.auth_number && ` · authorization ${r.auth_number}`}
                  {Number(r.hours_logged) > 0 && ` · ${r.hours_logged} hours logged`}
                </div>
              </td>
              <td style={{ textAlign: "right", whiteSpace: "nowrap" }}>
                <span className={"chip " + (TONE[r.state] ?? "")}>{r.state}</span>
              </td>
            </tr>
          ))}
        </tbody>
      </table>

      <p className="lock" style={{ padding: "0 16px 16px" }}>
        Fill these in on the <Link href={`/clients/${clientId}?tab=forms`}>Forms tab</Link>. An
        invoice will not send while a form USOR requires is unfinished — that rule is in the
        database, so this strip is a reminder rather than the thing enforcing it.
      </p>
    </div>
  );
}
