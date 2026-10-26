"use client";

import Link from "next/link";
import { useState } from "react";
import { authorizationNumberLabel } from "@/lib/billing";
import { money, today } from "@/lib/constants";
import { DataTable } from "../data-table";
import { CloseIt, CorrectPaidDate, EditEverything, RecordPayment } from "./authorizations/[id]/panel";

/**
 * Every authorization a client has, in three groups (owner, 26 Oct 2026).
 *
 * What was here was the working list and, folded under it, "History (N paid
 * or closed)" - so the question "what has this client got coming" had no
 * answer at all, and the question "what did they get paid in July" meant
 * opening a fold. An authorization that had not started yet appeared in
 * neither list.
 *
 * Now: Past, Current and Upcoming, two of them on to begin with, and the
 * groups are the database's (0256) rather than three filters written here
 * that would drift from the ones Money and the verification suite use.
 *
 * Record payment, Close and Edit are on every row of every group, because the
 * reason somebody opens a client's Billing tab is usually to do one of those
 * three and the record was two clicks away. They are the same forms the
 * authorization's own page shows, imported rather than rewritten: a second
 * shorter edit form is how the two stop agreeing about what may be changed.
 */

export type ClientAuthRow = {
  id: string;
  number: string | null;
  has_usor_number: boolean | null;
  service_type: string;
  status: string;
  bucket: string;
  period: string | null;
  start_date: string | null;
  end_date: string | null;
  received_on: string | null;
  paid_on: string | null;
  paid_amount: number | null;
  warrant: string | null;
  closed_reason: string | null;
  rate_type: string;
  rate: number | null;
  total_hours: number | null;
  funding_source: string | null;
  bill_by: string | null;
  service_start: string | null;
  service_end: string | null;
  recipient: string | null;
  note: string | null;
  amount: number | null;
  /** The one line the working list says about what this row waits on (§13.11). */
  attention?: string | null;
  urgency?: number | null;
};

const GROUPS = ["Past", "Current", "Upcoming"] as const;
type Group = (typeof GROUPS)[number];

const day = (d: string | null | undefined) =>
  d
    ? new Date(`${d}T00:00:00`).toLocaleDateString("en-US", {
        month: "short",
        day: "numeric",
        year: "numeric",
      })
    : null;

const monthOf = (period: string | null) =>
  period
    ? new Date(`${period}T00:00:00`).toLocaleDateString("en-US", { month: "long" })
    : null;

/** What a row is worth: what arrived, where something did, else what it comes to. */
const worth = (r: ClientAuthRow) =>
  r.status === "Paid" ? Number(r.paid_amount ?? r.amount ?? 0) : Number(r.amount ?? 0);

export function ClientAuthorizations({
  rows,
  canBill,
}: {
  rows: ClientAuthRow[];
  canBill: boolean;
}) {
  /**
   * Current and Upcoming to begin with: what is being worked and what is
   * coming. Past is a hundred and fifty rows for some clients and nobody
   * opens a record to read them, but it is one click rather than a fold.
   */
  const [on, setOn] = useState<Record<Group, boolean>>({
    Past: false,
    Current: true,
    Upcoming: true,
  });
  const [open, setOpen] = useState<{ id: string; which: string } | null>(null);

  const counts = Object.fromEntries(
    GROUPS.map((g) => [g, rows.filter((r) => r.bucket === g).length]),
  ) as Record<Group, number>;
  const showing = rows.filter((r) => on[r.bucket as Group]);
  const chose = GROUPS.filter((g) => on[g]);
  const acting = open ? (showing.find((r) => r.id === open.id) ?? null) : null;

  return (
    <>
      <div className="segmented" style={{ marginBottom: 10 }}>
        {GROUPS.map((g) => (
          <button
            key={g}
            type="button"
            className={on[g] ? "on" : undefined}
            aria-pressed={on[g]}
            onClick={() => setOn((was) => ({ ...was, [g]: !was[g] }))}
          >
            {g} <span className="lock">{counts[g]}</span>
          </button>
        ))}
      </div>

      <div className="card" style={{ padding: 0, marginBottom: 14 }}>
        <DataTable
          label="authorizations"
          sortBy
          pageSize={50}
          columns={[
            { key: "number", label: "Auth #" },
            { key: "service", label: "Service" },
            { key: "when", label: "Dates" },
            { key: "amount", label: "Amount", align: "right" },
            { key: "status", label: "Status" },
            { key: "attention", label: "Waiting on" },
            ...(canBill ? [{ key: "do", label: "Do", sortable: false }] : []),
          ]}
          rows={showing.map((r) => ({
            key: r.id,
            cells: {
              number: (
                <Link
                  href={`/billing/authorizations/${r.id}`}
                  style={{ color: "var(--teal)", fontWeight: 600 }}
                >
                  {authorizationNumberLabel(r)}
                </Link>
              ),
              service: (
                <>
                  {r.service_type}
                  {r.period ? <span className="lock"> · {monthOf(r.period)}</span> : null}
                </>
              ),
              when:
                r.bucket === "Upcoming" ? (
                  <>starts {day(r.start_date)}</>
                ) : r.status === "Paid" ? (
                  <>paid {day(r.paid_on) ?? "— no date"}</>
                ) : (
                  <span className="lock">
                    {day(r.start_date) ?? "—"}
                    {r.end_date ? ` to ${day(r.end_date)}` : ""}
                  </span>
                ),
              amount: money(worth(r)),
              status:
                r.status === "Closed" ? (
                  <>
                    Closed
                    <span className="lock"> · {r.closed_reason ?? "no reason recorded"}</span>
                  </>
                ) : r.status === "Paid" ? (
                  <>
                    <span className="chip ok">Paid</span>
                    {r.warrant ? <span className="lock"> · {r.warrant}</span> : null}
                  </>
                ) : (
                  <span className="chip">{r.status}</span>
                ),
              attention: r.attention ? (
                <span
                  className={
                    (r.urgency ?? 9) <= 3 ? "chip bad" : (r.urgency ?? 9) <= 6 ? "chip warn" : "chip"
                  }
                >
                  {r.attention}
                </span>
              ) : (
                <span className="lock">nothing waiting</span>
              ),
              ...(canBill
                ? {
                    do: (
                      <span className="record-actions">
                        {r.status === "Paid" ? (
                          <Pick row={r} which="date" open={open} setOpen={setOpen}>
                            Correct the date
                          </Pick>
                        ) : (
                          <Pick row={r} which="pay" open={open} setOpen={setOpen}>
                            Record payment
                          </Pick>
                        )}
                        {r.status === "Closed" ? null : (
                          <Pick row={r} which="close" open={open} setOpen={setOpen}>
                            Close
                          </Pick>
                        )}
                        <Pick row={r} which="edit" open={open} setOpen={setOpen}>
                          Edit
                        </Pick>
                      </span>
                    ),
                  }
                : {}),
            },
            sort: {
              number: r.number ?? "",
              service: r.service_type,
              when: r.paid_on ?? r.start_date ?? "",
              amount: worth(r),
              status: r.status,
              attention: r.urgency ?? 99,
            },
            text: [r.number, r.service_type, r.status, r.warrant, r.attention]
              .filter(Boolean)
              .join(" "),
          }))}
          empty={
            chose.length === 0
              ? "Nothing chosen — turn one of the three groups on."
              : `Nothing ${chose.join(" or ").toLowerCase()} for this client — an authorization is added above, and a coaching month opens itself.`
          }
        />
      </div>

      {acting ? (
        <section className="page-section">
          <div className="record-actions" style={{ marginBottom: 8 }}>
            <h3 className="h2" style={{ margin: 0, flex: 1 }}>
              {authorizationNumberLabel(acting)}
            </h3>
            <button type="button" className="btn ghost" onClick={() => setOpen(null)}>
              Done
            </button>
          </div>
          {open?.which === "pay" ? (
            <RecordPayment
              authId={acting.id}
              amount={Number(acting.amount ?? 0)}
              priced={Number(acting.amount ?? 0) > 0}
              today={today()}
            />
          ) : null}
          {open?.which === "date" ? (
            <CorrectPaidDate authId={acting.id} paidOn={acting.paid_on} today={today()} />
          ) : null}
          {open?.which === "close" ? <CloseIt authId={acting.id} /> : null}
          {open?.which === "edit" ? (
            <EditEverything
              authId={acting.id}
              rec={{
                number: acting.number ?? "",
                service_type: acting.service_type,
                funding_source: acting.funding_source ?? "Utah VR",
                total_hours: acting.total_hours == null ? null : Number(acting.total_hours),
                rate_type: acting.rate_type,
                rate: Number(acting.rate ?? 0),
                start_date: acting.start_date,
                end_date: acting.end_date,
                received_on: acting.received_on,
                bill_by: acting.bill_by,
                service_start: acting.service_start,
                service_end: acting.service_end,
                recipient: acting.recipient,
                paid_on: acting.paid_on,
                paid_amount: acting.paid_amount == null ? null : Number(acting.paid_amount),
                warrant: acting.warrant,
                note: acting.note ?? "",
              }}
            />
          ) : null}
        </section>
      ) : null}
    </>
  );
}

/** One row's button, which opens its form below and closes it again. */
function Pick({
  row,
  which,
  open,
  setOpen,
  children,
}: {
  row: ClientAuthRow;
  which: string;
  open: { id: string; which: string } | null;
  setOpen: (v: { id: string; which: string } | null) => void;
  children: React.ReactNode;
}) {
  const here = open?.id === row.id && open.which === which;
  return (
    <button
      type="button"
      className={here ? "btn" : "btn ghost"}
      onClick={() => setOpen(here ? null : { id: row.id, which })}
    >
      {children}
    </button>
  );
}
