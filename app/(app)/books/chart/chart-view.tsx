"use client";

import { useActionState, useState } from "react";
import { DataTable, type DataRow } from "../../data-table";
import { addAccount, mapAccount, setAccountActive, type BooksState } from "../actions";

const initial: BooksState = { error: null, ok: null };

type Account = {
  id: string;
  code: string;
  name: string;
  kind: string;
  role: string | null;
  active: boolean;
  note: string;
};

/** What a role means, said once, where somebody reading the chart will see it. */
const ROLE_LABEL: Record<string, string> = {
  bank: "Statements import here",
  undeposited: "Warrants in hand",
  ar: "Billed and unpaid",
  ap: "Vendor bills owed",
  contractor_payable: "Owed to contractors",
  equity: "Owner equity",
  owner_draw: "Owner draw",
  contractor_cost: "Contractor cost",
  payroll: "Payroll",
  revenue_other: "Any service with no account of its own",
  expense_other: "Any claim with no account of its own",
};

export function ChartView({
  accounts,
  services,
  categories,
  revenueMap,
  expenseMap,
  isAdmin,
}: {
  accounts: Account[];
  services: string[];
  categories: { key: string; label: string }[];
  revenueMap: { service: string; account_id: string }[];
  expenseMap: { category: string; account_id: string }[];
  isAdmin: boolean;
}) {
  const [state, action, pending] = useActionState(addAccount, initial);
  const [adding, setAdding] = useState(false);

  const byService = new Map(revenueMap.map((m) => [m.service, m.account_id]));
  const byCategory = new Map(expenseMap.map((m) => [m.category, m.account_id]));
  const revenue = accounts.filter((a) => a.kind === "Revenue");
  const expense = accounts.filter((a) => a.kind === "Expense");

  return (
    <>
      {isAdmin && !adding && (
        <div className="no-print" style={{ marginBottom: 16 }}>
          <button className="btn gold" type="button" onClick={() => setAdding(true)}>
            Add an account
          </button>
        </div>
      )}

      {isAdmin && adding && (
        <form action={action} className="card no-print" style={{ marginBottom: 16 }}>
          <h3 style={{ marginTop: 0 }}>Add an account</h3>
          {state.error && <div className="alert bad">{state.error}</div>}
          {state.ok && <div className="alert ok">{state.ok}</div>}
          <div className="row2" style={{ gap: 8, flexWrap: "wrap" }}>
            <label>
              Code
              <input name="code" inputMode="numeric" placeholder="5800" required />
            </label>
            <label style={{ flex: 1, minWidth: 200 }}>
              Name
              <input name="name" required />
            </label>
            <label>
              Kind
              <select name="kind" defaultValue="Expense">
                <option>Asset</option>
                <option>Liability</option>
                <option>Equity</option>
                <option>Revenue</option>
                <option>Expense</option>
              </select>
            </label>
          </div>
          <label>
            Note
            <input name="note" placeholder="What belongs here" />
          </label>
          <div className="row2" style={{ gap: 8, marginTop: 8 }}>
            <button className="btn" type="submit" disabled={pending}>
              Add
            </button>
            <button className="btn ghost" type="button" onClick={() => setAdding(false)}>
              Cancel
            </button>
          </div>
        </form>
      )}

      <DataTable
        label="accounts"
        columns={[
          { key: "code", label: "Code" },
          { key: "name", label: "Account" },
          { key: "kind", label: "Kind" },
          { key: "posts", label: "What the CRM posts here" },
          { key: "standing", label: "Standing" },
          ...(isAdmin ? [{ key: "act", label: "", sortable: false }] : []),
        ]}
        rows={accounts.map((a): DataRow => ({
          key: a.id,
          cells: {
            code: a.code,
            name: a.name,
            kind: a.kind,
            posts: a.role ? ROLE_LABEL[a.role] ?? a.role : a.note,
            standing: a.active ? "In use" : "Retired",
            ...(isAdmin
              ? {
                  act: (
                    <form action={setAccountActive}>
                      <input type="hidden" name="id" value={a.id} />
                      <input type="hidden" name="active" value={a.active ? "false" : "true"} />
                      <button className="btn ghost" type="submit">
                        {a.active ? "Retire" : "Use again"}
                      </button>
                    </form>
                  ),
                }
              : {}),
          },
        }))}
        pageSize={100}
        empty="The chart is empty, which cannot happen once the ledger is installed."
      />

      <h2 className="h2" style={{ marginTop: 24 }}>
        Which account each service bills to
      </h2>
      <DataTable
        label="services"
        filter={false}
        columns={[
          { key: "service", label: "Service" },
          { key: "account", label: "Revenue account", sortable: false },
        ]}
        rows={services.map((service): DataRow => ({
          key: service,
          cells: {
            service,
            account: isAdmin ? (
              <form action={mapAccount} className="row2" style={{ gap: 6 }}>
                <input type="hidden" name="service" value={service} />
                <select name="account_id" defaultValue={byService.get(service) ?? ""}>
                  <option value="">Other service revenue</option>
                  {revenue.map((a) => (
                    <option key={a.id} value={a.id}>
                      {a.code} {a.name}
                    </option>
                  ))}
                </select>
                <button className="btn ghost" type="submit">
                  Set
                </button>
              </form>
            ) : (
              (() => {
                const a = revenue.find((x) => x.id === byService.get(service));
                return a ? `${a.code} ${a.name}` : "Other service revenue";
              })()
            ),
          },
        }))}
        empty="No service is set up to bill."
      />

      <h2 className="h2" style={{ marginTop: 24 }}>
        Which account each claim lands in
      </h2>
      <DataTable
        label="claims"
        filter={false}
        columns={[
          { key: "claim", label: "Claim" },
          { key: "account", label: "Expense account", sortable: false },
        ]}
        rows={categories.map((c): DataRow => ({
          key: c.key,
          cells: {
            claim: c.label,
            account: isAdmin ? (
              <form action={mapAccount} className="row2" style={{ gap: 6 }}>
                <input type="hidden" name="category" value={c.key} />
                <select name="account_id" defaultValue={byCategory.get(c.key) ?? ""}>
                  <option value="">Other</option>
                  {expense.map((a) => (
                    <option key={a.id} value={a.id}>
                      {a.code} {a.name}
                    </option>
                  ))}
                </select>
                <button className="btn ghost" type="submit">
                  Set
                </button>
              </form>
            ) : (
              (() => {
                const a = expense.find((x) => x.id === byCategory.get(c.key));
                return a ? `${a.code} ${a.name}` : "Other";
              })()
            ),
          },
        }))}
        empty="No claim category is set up."
      />
    </>
  );
}
