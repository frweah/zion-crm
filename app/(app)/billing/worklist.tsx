import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { money } from "@/lib/constants";
import { DataTable, type DataRow } from "../data-table";

/**
 * The working list, in one place (Billing Simplification Brief §§9, 12.2, 12.6).
 *
 * Billing shows it for the whole practice and the client's record shows it for
 * one client. §12.6 asks for one component rather than two that drift, and §11
 * says if two screens show the same records, one of them goes.
 *
 * One list, not a Due section and then a list (§12.2): Due is one of the
 * things a row can say about itself, and splitting by status makes a person
 * look in two places for the same job. Ordered by what is most pressing, then
 * by the day it was meant to be billed.
 *
 * Paid and Closed are not on it at all. They are History, below, collapsed -
 * because a paid authorization needs nothing from anybody, and a list that
 * shows it anyway buries the four that do (§§9, 11).
 */

export type WorklistRow = {
  id: string;
  client_id: string;
  client_name: string;
  number: string;
  service_type: string;
  period: string | null;
  status: string;
  bill_by: string | null;
  amount: number | null;
  attention: string | null;
  urgency: number;
};

const monthOf = (period: string | null, long = false) =>
  period
    ? new Date(`${period}T00:00:00`).toLocaleDateString("en-US", {
        month: long ? "long" : "short",
        year: long ? undefined : "numeric",
      })
    : null;

/** One row of the working list, the same wherever it is shown. */
export function worklistRows(rows: WorklistRow[], withClient: boolean): DataRow[] {
  return rows.map((w) => ({
    key: w.id,
    cells: {
      number: (
        <Link
          href={`/billing/authorizations/${w.id}`}
          style={{ color: "var(--teal)", fontWeight: 600 }}
        >
          {w.number || "no number"}
        </Link>
      ),
      ...(withClient
        ? {
            client: (
              <Link href={`/clients/${w.client_id}?tab=billing`} style={{ color: "var(--teal)" }}>
                {w.client_name}
              </Link>
            ),
          }
        : {}),
      service: (
        <>
          {w.service_type}
          {w.period ? <span className="lock"> · {monthOf(w.period, true)}</span> : null}
        </>
      ),
      billBy: w.bill_by ?? <span className="lock">—</span>,
      amount: money(Number(w.amount ?? 0)),
      status: <span className="chip">{w.status}</span>,
      // §13.11: one line about this record, never four alerts.
      attention: w.attention ? (
        <span className={w.urgency <= 3 ? "chip bad" : w.urgency <= 6 ? "chip warn" : "chip"}>
          {w.attention}
        </span>
      ) : (
        <span className="lock">nothing waiting</span>
      ),
    },
    sort: {
      number: w.number,
      client: w.client_name,
      billBy: w.bill_by,
      amount: Number(w.amount ?? 0),
      status: w.status,
      attention: w.urgency,
    },
    text: [w.number, w.client_name, w.service_type, w.status, w.attention].filter(Boolean).join(" "),
  }));
}

export function worklistColumns(withClient: boolean) {
  return [
    { key: "number", label: "Auth #" },
    ...(withClient ? [{ key: "client", label: "Client" }] : []),
    { key: "service", label: "Service" },
    { key: "billBy", label: "Bill by" },
    { key: "amount", label: "Amount", align: "right" as const },
    { key: "status", label: "Status" },
    { key: "attention", label: "Waiting on" },
  ];
}

export function Worklist({
  rows,
  withClient,
  empty,
}: {
  rows: WorklistRow[];
  withClient: boolean;
  empty: string;
}) {
  return (
    <div className="card" style={{ padding: 0, marginBottom: 14 }}>
      <DataTable
        label="authorizations being worked"
        sortBy
        pageSize={50}
        columns={worklistColumns(withClient)}
        rows={worklistRows(rows, withClient)}
        empty={empty}
      />
    </div>
  );
}

/**
 * History: what has been paid or closed for one client.
 *
 * Collapsed, because this is the answer to a question somebody asks
 * occasionally and never the thing they came to the record to do. The totals
 * are not here - they are Admin's (§13.16); each row says what it was paid and
 * when, which is what the person looking at a client's record actually needs.
 */
export async function ClientBillingHistory({ clientId }: { clientId: string }) {
  const supabase = await createClient();
  const { data } = await supabase
    .from("authorization_record")
    .select("id, number, service_type, period, status, amount, paid_on, paid_amount, warrant, closed_reason, is_placeholder")
    .eq("client_id", clientId)
    .in("status", ["Paid", "Closed"])
    .order("paid_on", { ascending: false, nullsFirst: false });

  const rows = data ?? [];
  if (rows.length === 0) return null;

  return (
    <details className="card" style={{ marginBottom: 14 }}>
      <summary>History ({rows.length} paid or closed)</summary>
      <div className="card" style={{ padding: 0, marginTop: 8 }}>
        <DataTable
          label="paid and closed authorizations"
          sortBy
          columns={[
            { key: "number", label: "Auth #" },
            { key: "service", label: "Service" },
            { key: "status", label: "Status" },
            { key: "paid", label: "Paid", align: "right" },
            { key: "when", label: "When" },
            { key: "warrant", label: "Warrant" },
          ]}
          rows={rows.map((r) => ({
            key: r.id as string,
            cells: {
              number: (
                <Link href={`/billing/authorizations/${r.id}`} style={{ color: "var(--teal)" }}>
                  {r.number || (r.is_placeholder ? "no USOR number" : "—")}
                </Link>
              ),
              service: (
                <>
                  {r.service_type}
                  {r.period ? <span className="lock"> · {monthOf(r.period as string, true)}</span> : null}
                </>
              ),
              status:
                r.status === "Closed" ? (
                  <>
                    Closed<span className="lock"> · {r.closed_reason ?? "no reason recorded"}</span>
                  </>
                ) : (
                  <span className="chip ok">Paid</span>
                ),
              paid: r.status === "Paid" ? money(Number(r.paid_amount ?? r.amount ?? 0)) : "",
              when: r.paid_on ?? "",
              warrant: r.warrant ?? "",
            },
            sort: {
              number: (r.number as string) ?? "",
              paid: Number(r.paid_amount ?? r.amount ?? 0),
              when: (r.paid_on as string) ?? "",
              status: r.status as string,
            },
            text: [r.number, r.service_type, r.status, r.warrant].filter(Boolean).join(" "),
          }))}
          empty="Nothing settled yet."
        />
      </div>
    </details>
  );
}
