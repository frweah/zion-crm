"use client";

import Link from "next/link";
import { useActionState, useState } from "react";
import { money } from "@/lib/constants";
import { DataTable, type DataRow } from "../../data-table";
import { addBill, addSchedule, settleBill, type BooksState } from "../actions";

const initial: BooksState = { error: null, ok: null };

type Bill = {
  id: string;
  number: string;
  bill_date: string;
  due_date: string | null;
  amount: number;
  status: string;
  description: string;
  scheduled_for: string | null;
  paid_on: string | null;
  method: string | null;
  reference: string;
  void_reason: string;
  vendors: { name: string } | null;
  ledger_accounts: { code: string; name: string } | null;
};

type Schedule = {
  id: string;
  amount: number;
  description: string;
  every_months: number;
  next_due: string;
  active: boolean;
  vendors: { name: string } | null;
  ledger_accounts: { code: string; name: string } | null;
};

const SHOW = [
  { key: "open", label: "To deal with" },
  { key: "paid", label: "Paid" },
  { key: "all", label: "All" },
];

export function BillList({
  show,
  bills,
  vendors,
  schedules,
  accounts,
  isAdmin,
  approvalLimit,
}: {
  show: string;
  bills: Bill[];
  vendors: { id: string; name: string; expense_account_id: string | null; terms_days: number | null }[];
  schedules: Schedule[];
  accounts: { id: string; code: string; name: string }[];
  isAdmin: boolean;
  approvalLimit: number | null;
}) {
  const [added, addAction, adding] = useActionState(addBill, initial);
  const [settled, settleAction] = useActionState(settleBill, initial);
  const [scheduled, scheduleAction, scheduling] = useActionState(addSchedule, initial);
  const [adding_, setAdding] = useState(false);
  const [recurring, setRecurring] = useState(false);
  const [open, setOpen] = useState<string | null>(null);

  const today = new Date().toISOString().slice(0, 10);

  return (
    <>
      {settled.error && <div className="alert bad">{settled.error}</div>}
      {settled.ok && <div className="alert ok">{settled.ok}</div>}

      <div className="row2 no-print" style={{ gap: 8, marginBottom: 12 }}>
        {!adding_ && (
          <button className="btn gold" type="button" onClick={() => setAdding(true)}>
            Enter a bill
          </button>
        )}
        {isAdmin && !recurring && (
          <button className="btn ghost" type="button" onClick={() => setRecurring(true)}>
            Add a recurring bill
          </button>
        )}
      </div>

      {adding_ && (
        <form action={addAction} className="card no-print" style={{ marginBottom: 16 }}>
          <h3 style={{ marginTop: 0 }}>Enter a bill</h3>
          {added.error && <div className="alert bad">{added.error}</div>}
          {added.ok && <div className="alert ok">{added.ok}</div>}
          <div className="row2" style={{ gap: 8, flexWrap: "wrap" }}>
            <label style={{ minWidth: 200 }}>
              Vendor
              <select name="vendor_id" defaultValue={vendors[0]?.id ?? ""} required>
                {vendors.map((v) => (
                  <option key={v.id} value={v.id}>
                    {v.name}
                  </option>
                ))}
              </select>
            </label>
            <label>
              Their number
              <input name="number" />
            </label>
            <label>
              Dated
              <input type="date" name="bill_date" defaultValue={today} required />
            </label>
            <label>
              Due
              <input type="date" name="due_date" />
            </label>
            <label>
              Amount
              <input name="amount" inputMode="decimal" required />
            </label>
            <label style={{ minWidth: 200 }}>
              Posts to
              <select name="account_id" defaultValue="">
                <option value="">The vendor&rsquo;s usual account</option>
                {accounts.map((a) => (
                  <option key={a.id} value={a.id}>
                    {a.code} {a.name}
                  </option>
                ))}
              </select>
            </label>
          </div>
          <label>
            What it is for
            <input name="description" />
          </label>
          <div className="row2" style={{ gap: 8, marginTop: 8 }}>
            <button className="btn" type="submit" disabled={adding}>
              Enter
            </button>
            <button className="btn ghost" type="button" onClick={() => setAdding(false)}>
              Cancel
            </button>
          </div>
        </form>
      )}

      {isAdmin && recurring && (
        <form action={scheduleAction} className="card no-print" style={{ marginBottom: 16 }}>
          <h3 style={{ marginTop: 0 }}>A bill that comes every month</h3>
          {scheduled.error && <div className="alert bad">{scheduled.error}</div>}
          {scheduled.ok && <div className="alert ok">{scheduled.ok}</div>}
          <div className="row2" style={{ gap: 8, flexWrap: "wrap" }}>
            <label style={{ minWidth: 200 }}>
              Vendor
              <select name="vendor_id" defaultValue={vendors[0]?.id ?? ""} required>
                {vendors.map((v) => (
                  <option key={v.id} value={v.id}>
                    {v.name}
                  </option>
                ))}
              </select>
            </label>
            <label>
              Amount
              <input name="amount" inputMode="decimal" required />
            </label>
            <label style={{ minWidth: 200 }}>
              Posts to
              <select name="account_id" defaultValue={accounts[0]?.id ?? ""} required>
                {accounts.map((a) => (
                  <option key={a.id} value={a.id}>
                    {a.code} {a.name}
                  </option>
                ))}
              </select>
            </label>
            <label>
              Every
              <select name="every_months" defaultValue="1">
                <option value="1">month</option>
                <option value="3">three months</option>
                <option value="6">six months</option>
                <option value="12">year</option>
              </select>
            </label>
            <label>
              First one due
              <input type="date" name="next_due" defaultValue={today} required />
            </label>
          </div>
          <label>
            What it is for
            <input name="description" placeholder="Rent" />
          </label>
          <p className="sub">
            Each one arrives awaiting approval, so the month the rent changes is a month somebody
            sees.
          </p>
          <div className="row2" style={{ gap: 8, marginTop: 8 }}>
            <button className="btn" type="submit" disabled={scheduling}>
              Add
            </button>
            <button className="btn ghost" type="button" onClick={() => setRecurring(false)}>
              Cancel
            </button>
          </div>
        </form>
      )}

      <div className="segmented no-print" role="group" aria-label="Which bills">
        {SHOW.map((s) => (
          <Link key={s.key} href={`?show=${s.key}`} className={s.key === show ? "on" : ""}>
            {s.label}
          </Link>
        ))}
      </div>

      <DataTable
        label="bills"
        columns={[
          { key: "vendor", label: "Vendor" },
          { key: "what", label: "What for" },
          { key: "due", label: "Due" },
          { key: "amount", label: "Amount", align: "right" },
          { key: "status", label: "Where it stands" },
          { key: "act", label: "", sortable: false },
        ]}
        rows={bills.map((b): DataRow => {
          const late = b.due_date !== null && b.due_date < today && b.status !== "Paid";
          return {
            key: b.id,
            cells: {
              vendor: b.vendors?.name ?? "",
              what: [b.description, b.number].filter(Boolean).join(" · "),
              due: b.due_date ?? "",
              amount: money(b.amount),
              status:
                b.status === "Paid"
                  ? `Paid ${b.paid_on ?? ""}${b.method ? `, ${b.method}` : ""}`
                  : b.status === "Void"
                    ? `Void — ${b.void_reason}`
                    : late
                      ? `${b.status}, late`
                      : b.status,
              act:
                b.status === "Paid" || b.status === "Void" ? (
                  ""
                ) : (
                  <button
                    className="btn ghost"
                    type="button"
                    onClick={() => setOpen(open === b.id ? null : b.id)}
                  >
                    {open === b.id ? "Close" : "Deal with"}
                  </button>
                ),
            },
            sort: { due: b.due_date ?? "9999", amount: b.amount },
          };
        })}
        pageSize={60}
        empty="No bill to deal with."
      />

      {open &&
        (() => {
          const bill = bills.find((b) => b.id === open);
          if (!bill) return null;
          const needsAdmin =
            approvalLimit === null || Number(bill.amount) > Number(approvalLimit);
          return (
            <div className="card no-print" style={{ marginTop: 16 }}>
              <h3 style={{ marginTop: 0 }}>
                {bill.vendors?.name} · {money(bill.amount)} · {bill.description || bill.number}
              </h3>

              {bill.status === "Awaiting approval" && (
                <form action={settleAction} style={{ marginBottom: 12 }}>
                  <input type="hidden" name="bill_id" value={bill.id} />
                  <input type="hidden" name="how" value="approve" />
                  <button className="btn gold" type="submit" disabled={needsAdmin && !isAdmin}>
                    Approve
                  </button>
                  {needsAdmin && !isAdmin && (
                    <p className="sub">This one is over the limit; an Admin approves it.</p>
                  )}
                </form>
              )}

              {(bill.status === "Approved" || bill.status === "Scheduled") && (
                <>
                  <form action={settleAction} style={{ marginBottom: 12 }}>
                    <input type="hidden" name="bill_id" value={bill.id} />
                    <input type="hidden" name="how" value="schedule" />
                    <div className="row2" style={{ gap: 8, alignItems: "flex-end" }}>
                      <label>
                        Pay on
                        <input
                          type="date"
                          name="scheduled_for"
                          defaultValue={bill.scheduled_for ?? bill.due_date ?? today}
                        />
                      </label>
                      <button className="btn ghost" type="submit">
                        Schedule
                      </button>
                    </div>
                  </form>

                  <form action={settleAction} style={{ marginBottom: 12 }}>
                    <input type="hidden" name="bill_id" value={bill.id} />
                    <input type="hidden" name="how" value="pay" />
                    <div className="row2" style={{ gap: 8, flexWrap: "wrap", alignItems: "flex-end" }}>
                      <label>
                        Paid on
                        <input type="date" name="paid_on" defaultValue={today} required />
                      </label>
                      <label>
                        How
                        <select name="method" defaultValue="ACH">
                          <option>Check</option>
                          <option>ACH</option>
                          <option>Card</option>
                          <option>Cash</option>
                          <option>Other</option>
                        </select>
                      </label>
                      <label>
                        Reference
                        <input name="reference" />
                      </label>
                      <button className="btn" type="submit">
                        Mark paid
                      </button>
                    </div>
                  </form>
                </>
              )}

              <form action={settleAction}>
                <input type="hidden" name="bill_id" value={bill.id} />
                <input type="hidden" name="how" value="void" />
                <div className="row2" style={{ gap: 8, flexWrap: "wrap", alignItems: "flex-end" }}>
                  <label style={{ flex: 1, minWidth: 220 }}>
                    Or void it, because
                    <input name="void_reason" required />
                  </label>
                  <button className="btn ghost" type="submit">
                    Void
                  </button>
                </div>
                <p className="sub">
                  Voiding reverses whatever was posted; it does not remove it.
                </p>
              </form>
            </div>
          );
        })()}

      {schedules.length > 0 && (
        <>
          <h2 className="h2" style={{ marginTop: 24 }}>
            Bills that come round again
          </h2>
          <DataTable
            label="schedules"
            filter={false}
            columns={[
              { key: "vendor", label: "Vendor" },
              { key: "what", label: "What for" },
              { key: "amount", label: "Amount", align: "right" },
              { key: "every", label: "How often" },
              { key: "next", label: "Next one" },
              { key: "standing", label: "Standing" },
            ]}
            rows={schedules.map((s): DataRow => ({
              key: s.id,
              cells: {
                vendor: s.vendors?.name ?? "",
                what: s.description,
                amount: money(s.amount),
                every: s.every_months === 1 ? "Monthly" : `Every ${s.every_months} months`,
                next: s.next_due,
                standing: s.active ? "On" : "Stopped",
              },
              sort: { amount: s.amount, next: s.next_due },
            }))}
            empty="None."
          />
        </>
      )}
    </>
  );
}
