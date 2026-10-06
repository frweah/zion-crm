"use client";

import { useActionState, useState } from "react";
import { money } from "@/lib/constants";
import { DataTable, type DataRow } from "../data-table";
import { askToBuy, decideRequest, setPurchaseThreshold, type BooksState } from "../books/actions";

const initial: BooksState = { error: null, ok: null };

type Request = {
  id: string;
  what: string;
  why: string;
  amount: number;
  status: string;
  decision_note: string;
  created_at: string;
  decided_at: string | null;
  staff_id: string;
  staff: { name: string } | null;
};

export function RequestsView({
  over,
  approvalLimit,
  isAdmin,
  myId,
  requests,
}: {
  over: number | null;
  approvalLimit: number | null;
  isAdmin: boolean;
  myId: string;
  requests: Request[];
}) {
  const [asked, askAction, asking] = useActionState(askToBuy, initial);
  const [decided, decideAction] = useActionState(decideRequest, initial);
  const [saved, saveAction, savingThreshold] = useActionState(setPurchaseThreshold, initial);
  const [open, setOpen] = useState(false);
  const [deciding, setDeciding] = useState<string | null>(null);

  return (
    <>
      {decided.error && <div className="alert bad">{decided.error}</div>}
      {decided.ok && <div className="alert ok">{decided.ok}</div>}

      {over !== null && !open && (
        <div className="no-print" style={{ marginBottom: 16 }}>
          <button className="btn gold" type="button" onClick={() => setOpen(true)}>
            Ask to buy something
          </button>
          {asked.ok && <span className="sub"> {asked.ok}</span>}
        </div>
      )}

      {over !== null && open && (
        <form action={askAction} className="card no-print" style={{ marginBottom: 16 }}>
          <h3 style={{ marginTop: 0 }}>Ask to buy something</h3>
          {asked.error && <div className="alert bad">{asked.error}</div>}
          {asked.ok && <div className="alert ok">{asked.ok}</div>}
          <div className="row2" style={{ gap: 8, flexWrap: "wrap" }}>
            <label style={{ flex: 1, minWidth: 220 }}>
              What
              <input name="what" required />
            </label>
            <label>
              Roughly
              <input name="amount" inputMode="decimal" required />
            </label>
          </div>
          <label>
            Why
            <input name="why" />
          </label>
          <div className="row2" style={{ gap: 8, marginTop: 8 }}>
            <button className="btn" type="submit" disabled={asking}>
              Ask
            </button>
            <button className="btn ghost" type="button" onClick={() => setOpen(false)}>
              Cancel
            </button>
          </div>
        </form>
      )}

      {over === null && (
        <p className="empty">
          Nothing needs asking for — the practice has not set an amount to ask above.
        </p>
      )}

      <DataTable
        label="requests"
        columns={[
          { key: "who", label: "Who" },
          { key: "what", label: "What" },
          { key: "amount", label: "Roughly", align: "right" },
          { key: "asked", label: "Asked" },
          { key: "status", label: "Where it stands" },
          ...(isAdmin ? [{ key: "act", label: "", sortable: false }] : []),
        ]}
        rows={requests.map((r): DataRow => ({
          key: r.id,
          cells: {
            who: r.staff?.name ?? (r.staff_id === myId ? "You" : ""),
            what: [r.what, r.why].filter(Boolean).join(" — "),
            amount: money(r.amount),
            asked: r.created_at.slice(0, 10),
            status:
              r.status === "Requested"
                ? "Waiting"
                : `${r.status}${r.decision_note ? ` — ${r.decision_note}` : ""}`,
            ...(isAdmin
              ? {
                  act:
                    r.status === "Requested" ? (
                      <button
                        className="btn ghost"
                        type="button"
                        onClick={() => setDeciding(deciding === r.id ? null : r.id)}
                      >
                        {deciding === r.id ? "Close" : "Decide"}
                      </button>
                    ) : (
                      ""
                    ),
                }
              : {}),
          },
          sort: { amount: r.amount, asked: r.created_at },
        }))}
        empty="Nobody has asked for anything."
      />

      {isAdmin && deciding && (
        <div className="card no-print" style={{ marginTop: 16 }}>
          <h3 style={{ marginTop: 0 }}>{requests.find((r) => r.id === deciding)?.what}</h3>
          <form action={decideAction}>
            <input type="hidden" name="request_id" value={deciding} />
            <label>
              Note
              <input name="note" placeholder="Anything they should know" />
            </label>
            <div className="row2" style={{ gap: 8, marginTop: 8 }}>
              <button className="btn" type="submit" name="decision" value="Approved">
                Approve
              </button>
              <button className="btn ghost" type="submit" name="decision" value="Declined">
                Decline
              </button>
            </div>
          </form>
        </div>
      )}

      {isAdmin && (
        <form action={saveAction} className="card no-print" style={{ marginTop: 24 }}>
          <h3 style={{ marginTop: 0 }}>When people have to ask</h3>
          {saved.error && <div className="alert bad">{saved.error}</div>}
          {saved.ok && <div className="alert ok">{saved.ok}</div>}
          <div className="row2" style={{ gap: 8, flexWrap: "wrap", alignItems: "flex-end" }}>
            <label>
              Ask above
              <input
                name="purchase_request_over"
                inputMode="decimal"
                defaultValue={over === null ? "" : String(over)}
                placeholder="Empty switches it off"
              />
            </label>
            <label>
              Billing approves bills up to
              <input
                name="bill_approval_limit"
                inputMode="decimal"
                defaultValue={approvalLimit === null ? "" : String(approvalLimit)}
                placeholder="Empty means Admin only"
              />
            </label>
            <button className="btn" type="submit" disabled={savingThreshold}>
              Save
            </button>
          </div>
        </form>
      )}
    </>
  );
}
