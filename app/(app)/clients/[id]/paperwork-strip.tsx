import Link from "next/link";
import { DataTable } from "../../data-table";

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
  const missing = rows.filter((r) => r.state === "Missing").length;
  const complete = rows.filter((r) => r.state === "Complete").length;

  return (
    <section style={{ marginTop: 22 }}>
      <h2 className="h2">Paperwork</h2>
      <p className="sub" style={{ margin: "4px 0 8px" }}>
        {rows.length === 0 ? (
          "No open authorization needs a USOR form yet."
        ) : (
          <>
            {missing > 0 ? (
              <b style={{ color: "var(--bad)" }}>{missing} blocking billing</b>
            ) : (
              "Nothing blocking billing"
            )}
            {" · "}
            {complete} of {rows.length} complete
          </>
        )}
      </p>

      {rows.length > 0 && (
        <>
          <div className="card" style={{ padding: 0 }}>
            <DataTable
              label="forms"
              columns={[
                { key: "form", label: "Form" },
                { key: "authorization", label: "Authorization" },
                { key: "state", label: "State" },
              ]}
              rows={rows.map((r, i) => ({
                key: `${r.usor}-${r.month}-${i}`,
                sort: {
                  form: `${r.usor ?? ""} ${r.month ?? ""}`,
                  authorization: r.auth_number,
                  state: r.state,
                },
                text: [r.usor, r.month, r.form_name, r.service_type, r.auth_number, r.state]
                  .filter(Boolean)
                  .join(" "),
                cells: {
                  form: (
                    <>
                      <b>{r.usor}</b>
                      {r.month && <span className="lock"> {r.month}</span>}
                      <div style={{ fontSize: 12, color: "var(--muted)" }}>{r.form_name}</div>
                    </>
                  ),
                  authorization: (
                    <span className="lock">
                      {r.service_type}
                      {r.auth_number && ` · ${r.auth_number}`}
                      {Number(r.hours_logged) > 0 && ` · ${r.hours_logged} hours logged`}
                    </span>
                  ),
                  state: <span className={"chip " + (TONE[r.state] ?? "")}>{r.state}</span>,
                },
              }))}
              empty="No open authorization needs a USOR form yet."
            />
          </div>

          <p className="lock" style={{ margin: "8px 0 0" }}>
            Fill these in on the <Link href={`/clients/${clientId}?tab=documents`}>Documents tab</Link>. An
            invoice will not send while a form USOR requires is unfinished — that rule is in the
            database, so this strip is a reminder rather than the thing enforcing it.
          </p>
        </>
      )}
    </section>
  );
}
