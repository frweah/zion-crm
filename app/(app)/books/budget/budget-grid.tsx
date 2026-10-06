"use client";

import { useActionState, useState } from "react";
import { setBudget, type BooksState } from "../actions";

const initial: BooksState = { error: null, ok: null };

const MONTHS = [
  "Jan", "Feb", "Mar", "Apr", "May", "Jun",
  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
];

/**
 * Setting a year's budget, one account at a time.
 *
 * A twelve-by-thirty grid of inputs would be the obvious shape and the wrong
 * one: six hundred fields, one save button, and no way to tell what changed.
 * This is one account and its twelve months, with "the same every month" for
 * the rent-shaped ones - which is most of them, and is the bit somebody would
 * otherwise do by typing the same number twelve times.
 */
export function BudgetGrid({
  year,
  accounts,
  budgets,
}: {
  year: number;
  accounts: { id: string; code: string; name: string; kind: string }[];
  budgets: { account_id: string; month: string; amount: number }[];
}) {
  const [state, action, pending] = useActionState(setBudget, initial);
  const [account, setAccount] = useState(accounts[0]?.id ?? "");
  const [even, setEven] = useState("");

  const existing = new Map(budgets.filter((b) => b.account_id === account).map((b) => [b.month.slice(0, 7), b.amount]));
  const chosen = accounts.find((a) => a.id === account);
  const yearTotal = budgets
    .filter((b) => b.account_id === account)
    .reduce((sum, b) => sum + Number(b.amount), 0);

  return (
    <form action={action} className="card no-print" style={{ marginTop: 24 }}>
      <h3 style={{ marginTop: 0 }}>Set the {year} budget</h3>
      {state.error && <div className="alert bad">{state.error}</div>}
      {state.ok && <div className="alert ok">{state.ok}</div>}

      <input type="hidden" name="year" value={year} />
      <div className="row2" style={{ gap: 8, flexWrap: "wrap", alignItems: "flex-end" }}>
        <label style={{ minWidth: 260 }}>
          Account
          <select name="account_id" value={account} onChange={(e) => setAccount(e.target.value)}>
            {accounts.map((a) => (
              <option key={a.id} value={a.id}>
                {a.code} {a.name}
              </option>
            ))}
          </select>
        </label>
        <label>
          The same every month
          <input
            name="even"
            inputMode="decimal"
            value={even}
            onChange={(e) => setEven(e.target.value)}
            placeholder="1500"
          />
        </label>
      </div>

      <div className="row2" style={{ gap: 8, flexWrap: "wrap", marginTop: 12 }}>
        {MONTHS.map((label, i) => {
          const key = `${year}-${String(i + 1).padStart(2, "0")}`;
          return (
            <label key={key} style={{ width: 92 }}>
              {label}
              <input
                name={`month_${i + 1}`}
                inputMode="decimal"
                defaultValue={existing.get(key)?.toString() ?? ""}
                disabled={even !== ""}
                placeholder={even !== "" ? even : ""}
              />
            </label>
          );
        })}
      </div>

      <p className="sub">
        {even !== "" ? "Every month will be set to that figure. " : ""}
        {chosen ? `${chosen.name} is budgeted ` : ""}
        {yearTotal > 0 ? `${yearTotal.toFixed(2)} for ${year} so far.` : `nothing for ${year} yet.`}
        {" An empty month is no budget, which is not the same as a budget of zero."}
      </p>

      <button className="btn" type="submit" disabled={pending || !account}>
        Save this account
      </button>
    </form>
  );
}
