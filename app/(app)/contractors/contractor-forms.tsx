"use client";

import { useActionState, useState } from "react";
import {
  saveContractorProfile,
  recordContractorPayment,
  deleteContractorPayment,
  saveTaxYear,
  type ContractorState,
} from "./actions";

const initial: ContractorState = { error: null, ok: null };

const usd = (n: number) =>
  n.toLocaleString("en-US", { style: "currency", currency: "USD" });

export type ProfileRow = {
  staff_id: string;
  name: string;
  legal_name: string;
  business_name: string;
  address_line1: string;
  address_line2: string;
  city: string;
  state: string;
  postal_code: string;
  tax_status: string;
  tin_type: string | null;
  tin_last4: string | null;
  w9_received_on: string | null;
  w8ben_received_on: string | null;
  w8ben_expires_on: string | null;
  notes: string;
};

/**
 * One contractor's details, as they will appear on a 1099.
 *
 * The taxpayer number is write-only: the row shows the last four and nothing
 * more, and typing a new one replaces it. There is nothing to gain from
 * displaying it back, and it is exactly the field that must not end up in a
 * screenshot.
 */
export function ProfileEditor({ row }: { row: ProfileRow }) {
  const [state, action, pending] = useActionState(saveContractorProfile, initial);
  const [taxStatus, setTaxStatus] = useState(row.tax_status || "US person");
  const foreign = taxStatus === "Foreign person";

  return (
    <details className="card" style={{ marginBottom: 12 }}>
      <summary style={{ cursor: "pointer" }}>
        <b>{row.name}</b>
        <span className="chip" style={{ marginLeft: 8 }}>
          {row.tax_status || "US person"}
        </span>
        {row.tin_last4 && (
          <span className="lock" style={{ marginLeft: 8 }}>
            {row.tin_type} ending {row.tin_last4}
          </span>
        )}
        {row.w9_received_on && (
          <span className="chip ok" style={{ marginLeft: 8 }}>
            W-9 {row.w9_received_on}
          </span>
        )}
        {row.w8ben_received_on && (
          <span className="chip ok" style={{ marginLeft: 8 }}>
            W-8BEN to {row.w8ben_expires_on}
          </span>
        )}
      </summary>

      {state.error && <div className="alert bad">{state.error}</div>}
      {state.ok && <div className="alert ok">{state.ok}</div>}

      <form action={action} style={{ marginTop: 12 }}>
        <input type="hidden" name="staff_id" value={row.staff_id} />

        <div className="row2">
          <label className="field" style={{ flex: 2 }}>
            Legal name
            <input name="legal_name" defaultValue={row.legal_name} placeholder={row.name} />
            <span className="lock">As it appears on their tax return</span>
          </label>
          <label className="field" style={{ flex: 2 }}>
            Business name, if different
            <input name="business_name" defaultValue={row.business_name} />
          </label>
          <label className="field">
            Tax status
            <select
              name="tax_status"
              value={taxStatus}
              onChange={(e) => setTaxStatus(e.target.value)}
            >
              <option value="US person">US person</option>
              <option value="Foreign person">Foreign person</option>
            </select>
          </label>
        </div>

        <label className="field">
          Address
          <input name="address_line1" defaultValue={row.address_line1} />
        </label>
        <label className="field">
          Address, second line
          <input name="address_line2" defaultValue={row.address_line2} />
        </label>
        <div className="row2">
          <label className="field" style={{ flex: 2 }}>
            City
            <input name="city" defaultValue={row.city} />
          </label>
          <label className="field">
            State or province
            <input name="state" defaultValue={row.state} />
          </label>
          <label className="field">
            Postal code
            <input name="postal_code" defaultValue={row.postal_code} />
          </label>
        </div>

        {foreign ? (
          <p className="lock">
            A foreign person files a W-8BEN and is excluded from every 1099 run. No US taxpayer
            number is recorded here — the one on their W-8BEN, if they have one, stays on the form.
          </p>
        ) : (
          <div className="row2" style={{ alignItems: "flex-end" }}>
            <label className="field">
              Number type
              <select name="tin_type" defaultValue={row.tin_type ?? "SSN"}>
                <option value="SSN">SSN</option>
                <option value="EIN">EIN</option>
              </select>
            </label>
            <label className="field" style={{ flex: 2 }}>
              Taxpayer identification number
              <input
                name="tin"
                inputMode="numeric"
                autoComplete="off"
                placeholder={
                  row.tin_last4
                    ? `On file, ending ${row.tin_last4} — type a new one to replace it`
                    : "Nine digits"
                }
              />
              <span className="lock">
                {row.tin_last4
                  ? "Leave blank to keep the number on file."
                  : "Usually arrives with a signed W-9 instead of being typed here."}
              </span>
            </label>
          </div>
        )}

        <label className="field">
          Notes
          <input name="notes" defaultValue={row.notes} />
        </label>

        <button className="btn" type="submit" disabled={pending}>
          {pending ? "Saving…" : "Save"}
        </button>
      </form>
    </details>
  );
}

export function PaymentForm({
  contractors,
  statements,
  defaultDate,
}: {
  contractors: { id: string; name: string }[];
  statements: { id: string; staff_id: string; label: string }[];
  defaultDate: string;
}) {
  const [state, action, pending] = useActionState(recordContractorPayment, initial);
  const [staffId, setStaffId] = useState(contractors[0]?.id ?? "");

  const theirs = statements.filter((s) => s.staff_id === staffId);

  return (
    <div className="card">
      <h3>Record a payment</h3>
      <p className="sub" style={{ marginTop: 0 }}>
        What was actually paid, and when. These are the figures a 1099 reports, so a payment
        belongs to the calendar year it was paid in rather than the period it covers.
      </p>

      {state.error && <div className="alert bad">{state.error}</div>}
      {state.ok && <div className="alert ok">{state.ok}</div>}

      <form action={action}>
        <div className="row2">
          <label className="field" style={{ flex: 2 }}>
            Who was paid
            <select name="staff_id" value={staffId} onChange={(e) => setStaffId(e.target.value)}>
              {contractors.map((c) => (
                <option key={c.id} value={c.id}>
                  {c.name}
                </option>
              ))}
            </select>
          </label>
          <label className="field">
            Date paid
            <input type="date" name="paid_on" defaultValue={defaultDate} required />
          </label>
          <label className="field">
            Amount
            <input type="number" name="amount" min="0.01" step="0.01" required />
          </label>
        </div>

        <div className="row2">
          <label className="field">
            Method
            <select name="method" defaultValue="Check">
              <option>Check</option>
              <option>ACH</option>
              <option>Cash</option>
              <option>Zelle</option>
              <option>Other</option>
            </select>
          </label>
          <label className="field">
            Reference
            <input name="reference" placeholder="Check number, transfer id" />
          </label>
          <label className="field" style={{ flex: 2 }}>
            Against a statement
            <select name="statement_id" defaultValue="">
              <option value="">Not tied to one</option>
              {theirs.map((s) => (
                <option key={s.id} value={s.id}>
                  {s.label}
                </option>
              ))}
            </select>
          </label>
        </div>

        <label className="field">
          Note
          <input name="note" />
        </label>

        <button className="btn gold" type="submit" disabled={pending}>
          {pending ? "Recording…" : "Record payment"}
        </button>
      </form>
    </div>
  );
}

export function DeletePayment({ id, amount }: { id: string; amount: number }) {
  const [state, action, pending] = useActionState(deleteContractorPayment, initial);

  return (
    <form action={action} style={{ display: "inline" }}>
      <input type="hidden" name="payment_id" value={id} />
      <button
        className="btn ghost"
        type="submit"
        disabled={pending}
        title={`Remove the ${usd(amount)} payment`}
      >
        {pending ? "…" : "Remove"}
      </button>
      {state.error && <div style={{ color: "var(--bad)", fontSize: 12 }}>{state.error}</div>}
    </form>
  );
}

export type TaxYearRow = {
  year: number;
  federal_threshold: number | null;
  utah_state_copy: boolean;
  confirmed_on: string | null;
  confirmed_by_name: string | null;
  notes: string;
};

/**
 * The figures a 1099 run depends on, which are the CPA's to give.
 *
 * Until the threshold is confirmed the run produces nothing at all. That is
 * deliberate: a filing built on a number nobody stood behind is worse than no
 * filing, because it looks finished.
 */
export function TaxYearEditor({ row }: { row: TaxYearRow }) {
  const [state, action, pending] = useActionState(saveTaxYear, initial);

  return (
    <div className="card" style={{ marginBottom: 12 }}>
      <h3>
        {row.year}{" "}
        {row.confirmed_on ? (
          <span className="chip ok">
            confirmed {row.confirmed_on}
            {row.confirmed_by_name ? ` by ${row.confirmed_by_name}` : ""}
          </span>
        ) : (
          <span className="chip warn">not confirmed</span>
        )}
      </h3>

      {state.error && <div className="alert bad">{state.error}</div>}
      {state.ok && <div className="alert ok">{state.ok}</div>}

      <form action={action}>
        <input type="hidden" name="year" value={row.year} />
        <div className="row2">
          <label className="field">
            Federal threshold
            <input
              type="number"
              name="federal_threshold"
              min="0.01"
              step="0.01"
              defaultValue={row.federal_threshold ?? ""}
              placeholder="Ask the CPA"
            />
            <span className="lock">
              Contractors paid this much or more in {row.year} get a 1099.
            </span>
          </label>
          <label className="field" style={{ flex: 2 }}>
            Notes
            <input name="notes" defaultValue={row.notes} placeholder="What the CPA said, and when" />
          </label>
        </div>

        <label style={{ fontSize: 13, display: "block", marginBottom: 8 }}>
          <input
            type="checkbox"
            name="utah_state_copy"
            defaultChecked={row.utah_state_copy}
            style={{ width: "auto", marginRight: 8 }}
          />
          Utah wants its own copy for {row.year}
        </label>

        <label style={{ fontSize: 13, display: "block", marginBottom: 12 }}>
          <input
            type="checkbox"
            name="confirm"
            defaultChecked={Boolean(row.confirmed_on)}
            style={{ width: "auto", marginRight: 8 }}
          />
          Confirmed with the CPA — the run may use this figure
        </label>

        <button className="btn" type="submit" disabled={pending}>
          {pending ? "Saving…" : "Save"}
        </button>
      </form>
    </div>
  );
}
