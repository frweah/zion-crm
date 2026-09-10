"use client";

import { useActionState, useState } from "react";
import { addExpense, removeExpense, setMileageRate, type HoursState } from "./actions";
import { money } from "@/lib/constants";

const initial: HoursState = { error: null, ok: null };

export type ExpenseCategory = {
  key: string;
  label: string;
  detail: string;
  is_mileage: boolean;
  needs_receipt: boolean;
};

export type ExpenseRow = {
  id: string;
  incurred_on: string;
  category: string;
  category_label: string;
  is_mileage: boolean;
  description: string;
  client_id: string | null;
  miles: number | null;
  from_place: string;
  to_place: string;
  amount: number | null;
  rate_used: number | null;
  unpriced: boolean;
  statement_id: string | null;
};

/**
 * What somebody is out of pocket for the period.
 *
 * Mileage asks for miles and never for an amount. What it comes to is the
 * rate on the day it was driven, worked out by the database — a contractor
 * multiplying it themselves is a contractor getting it wrong in January when
 * the rate changes and nobody has told them.
 */
export function Expenses({
  rows,
  categories,
  clients,
  today,
  locked,
  currentRate,
}: {
  rows: ExpenseRow[];
  categories: ExpenseCategory[];
  clients: { id: string; name: string }[];
  today: string;
  locked: boolean;
  currentRate: number | null;
}) {
  const [state, action, pending] = useActionState(addExpense, initial);
  const [removeState, removeAction] = useActionState(removeExpense, initial);
  const [category, setCategory] = useState("mileage");

  const chosen = categories.find((c) => c.key === category);
  const total = rows.reduce((t, r) => t + Number(r.amount ?? 0), 0);
  const unpriced = rows.filter((r) => r.unpriced);
  const miles = rows.reduce((t, r) => t + Number(r.miles ?? 0), 0);

  return (
    <div className="card" style={{ marginBottom: 14 }}>
      <div className="row2" style={{ justifyContent: "space-between", alignItems: "flex-start" }}>
        <div>
          <h3 style={{ margin: 0 }}>Expenses and mileage</h3>
          <p className="sub" style={{ margin: "4px 0 0" }}>
            {rows.length === 0
              ? "Nothing claimed for this period."
              : `${money(total)} claimed${miles > 0 ? `, including ${miles} miles` : ""}. Submitted with your hours, as one payment.`}
          </p>
        </div>
      </div>

      {state.error && <div className="alert bad" style={{ marginTop: 10 }}>{state.error}</div>}
      {state.ok && <div className="alert ok" style={{ marginTop: 10 }}>{state.ok}</div>}
      {removeState.error && (
        <div className="alert bad" style={{ marginTop: 10 }}>{removeState.error}</div>
      )}

      {unpriced.length > 0 && (
        <div className="alert" style={{ marginTop: 10 }}>
          <b>
            {unpriced.reduce((t, r) => t + Number(r.miles ?? 0), 0)} miles have no rate for the day
            they were driven.
          </b>{" "}
          They are recorded and will be paid — the administrator sets the rate for that period and
          the amount appears. Nothing has been assumed.
        </div>
      )}

      {!locked && (
        <form action={action} style={{ marginTop: 10 }}>
          <div className="row2">
            <label className="field" style={{ maxWidth: 160 }}>
              What
              <select
                name="category"
                value={category}
                onChange={(e) => setCategory(e.target.value)}
              >
                {categories.map((c) => (
                  <option key={c.key} value={c.key}>
                    {c.label}
                  </option>
                ))}
              </select>
            </label>

            <label className="field" style={{ maxWidth: 150 }}>
              When
              <input type="date" name="incurred_on" max={today} defaultValue={today} required />
            </label>

            {chosen?.is_mileage ? (
              <>
                <label className="field" style={{ maxWidth: 110 }}>
                  Miles
                  <input type="number" name="miles" step="0.1" min="0.1" required />
                  <span className="lock">
                    {currentRate ? `${currentRate}c a mile today` : "no rate set yet"}
                  </span>
                </label>
                <label className="field" style={{ maxWidth: 160 }}>
                  From
                  <input name="from_place" placeholder="Office" />
                </label>
                <label className="field" style={{ maxWidth: 160 }}>
                  To
                  <input name="to_place" placeholder="Employer, Tooele" />
                </label>
              </>
            ) : (
              <label className="field" style={{ maxWidth: 120 }}>
                Amount
                <input type="number" name="amount" step="0.01" min="0.01" required />
              </label>
            )}

            <label className="field" style={{ maxWidth: 180 }}>
              Client, if it was for one
              <select name="client_id" defaultValue="">
                <option value="">Not for one client</option>
                {clients.map((c) => (
                  <option key={c.id} value={c.id}>
                    {c.name}
                  </option>
                ))}
              </select>
            </label>

            <label className="field" style={{ flex: 2 }}>
              What it was for
              <input name="description" required={!chosen?.is_mileage} />
            </label>

            <button className="btn gold" type="submit" disabled={pending}>
              {pending ? "Saving…" : "Claim"}
            </button>
          </div>
          {chosen?.needs_receipt && (
            <p className="lock" style={{ margin: "8px 0 0" }}>
              Keep the receipt — add it to your documents on the Paperwork screen and say here what
              it was.
            </p>
          )}
        </form>
      )}

      {rows.length > 0 && (
        <table className="t" style={{ marginTop: 12 }}>
          <tbody>
            {rows.map((r) => (
              <tr key={r.id}>
                <td style={{ width: 110, whiteSpace: "nowrap" }}>{r.incurred_on}</td>
                <td style={{ width: 120 }}>{r.category_label}</td>
                <td>
                  {r.is_mileage ? (
                    <>
                      {Number(r.miles)} miles
                      {(r.from_place || r.to_place) && (
                        <span className="lock">
                          {" "}
                          {r.from_place} → {r.to_place}
                        </span>
                      )}
                      {r.rate_used && <div className="lock">at {Number(r.rate_used)}c a mile</div>}
                    </>
                  ) : (
                    r.description
                  )}
                  {r.is_mileage && r.description && (
                    <div className="lock">{r.description}</div>
                  )}
                </td>
                <td style={{ textAlign: "right", width: 110, whiteSpace: "nowrap" }}>
                  {r.unpriced ? (
                    <span className="chip warn">no rate yet</span>
                  ) : (
                    <b>{money(Number(r.amount ?? 0))}</b>
                  )}
                </td>
                <td style={{ textAlign: "right", width: 90 }}>
                  {r.statement_id ? (
                    <span className="lock">claimed</span>
                  ) : (
                    !locked && (
                      <form action={removeAction} style={{ display: "inline" }}>
                        <input type="hidden" name="expense_id" value={r.id} />
                        <button
                          className="btn ghost"
                          type="submit"
                          style={{ padding: "2px 10px" }}
                        >
                          Remove
                        </button>
                      </form>
                    )
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
}

/**
 * The rate itself, which only Admin sets.
 *
 * Dated, so a claim keeps the rate that applied when the driving happened.
 * The IRS publishes a new one each January and nothing here guesses it.
 */
export function MileageRateForm({
  rates,
  today,
}: {
  rates: { effective_from: string; cents_per_mile: number; note: string }[];
  today: string;
}) {
  const [state, action, pending] = useActionState(setMileageRate, initial);

  return (
    <div className="card" style={{ marginTop: 14 }}>
      <h3 style={{ marginTop: 0 }}>Mileage rate</h3>
      <p className="sub" style={{ marginTop: 0 }}>
        Cents per mile, from a date. A claim is priced at the rate that applied on the day it was
        driven, so setting this year&apos;s rate does not change last year&apos;s claims.
      </p>

      {state.error && <div className="alert bad">{state.error}</div>}
      {state.ok && <div className="alert ok">{state.ok}</div>}

      {rates.length === 0 && (
        <div className="alert bad">
          No rate has ever been set, so mileage claims are recorded as miles with no amount. Put
          the IRS figure for the year in below.
        </div>
      )}

      <form action={action}>
        <div className="row2">
          <label className="field" style={{ maxWidth: 170 }}>
            From
            <input type="date" name="effective_from" defaultValue={today} required />
          </label>
          <label className="field" style={{ maxWidth: 150 }}>
            Cents per mile
            <input type="number" name="cents_per_mile" step="0.1" min="1" max="200" required />
          </label>
          <label className="field" style={{ flex: 2 }}>
            Note
            <input name="note" placeholder="IRS standard rate for 2026" />
          </label>
          <button className="btn gold" type="submit" disabled={pending}>
            {pending ? "Saving…" : "Set it"}
          </button>
        </div>
      </form>

      {rates.length > 0 && (
        <table className="t" style={{ marginTop: 10 }}>
          <tbody>
            {rates.map((r) => (
              <tr key={r.effective_from}>
                <td style={{ width: 140 }}>from {r.effective_from}</td>
                <td>
                  <b>{Number(r.cents_per_mile)}c</b> a mile
                </td>
                <td className="lock">{r.note}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
}
