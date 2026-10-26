import Link from "next/link";
import { authorizationNumberLabel } from "@/lib/billing";
import { money, today } from "@/lib/constants";
import { type DataRow } from "../data-table";
import { WorklistTable } from "./worklist-table";

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
 * Paid and Closed are not on it at all, because a paid authorization needs
 * nothing from anybody and a list that shows it anyway buries the four that
 * do (§§9, 11). The client’s own record groups them instead - Past,
 * Current and Upcoming, from `client_authorizations` (0256).
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
  /** Past the grace: it can no longer be submitted, only closed (0221). */
  blocked: boolean;
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
          {authorizationNumberLabel(w)}
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
  canClear = false,
}: {
  rows: WorklistRow[];
  withClient: boolean;
  empty: string;
  /**
   * Whether this reader may clear rows in bulk (owner, 14 Oct 2026).
   *
   * Off by default, so a screen that shows the list without thinking about it
   * shows a list and not a set of controls. Billing passes it on; the
   * client's record passes it on too, because a person looking at one client
   * has the same right to clear that client's settled rows.
   */
  canClear?: boolean;
}) {
  return (
    <div className="card" style={{ padding: 0, marginBottom: 14 }}>
      <WorklistTable
        columns={worklistColumns(withClient)}
        rows={worklistRows(rows, withClient)}
        empty={empty}
        canClear={canClear}
        today={today()}
      />
    </div>
  );
}
