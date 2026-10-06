"use client";

import { useActionState, useState } from "react";
import { addBankAccount, importStatement, type BooksState } from "../actions";

const initial: BooksState = { error: null, ok: null };

/**
 * Importing a statement, and adding the account it came from.
 *
 * The closing balance is typed in even when the file states it, because the
 * whole reconciliation hangs off that one number: a figure read out of a file
 * nobody checked is a figure that can be wrong twice over.
 */
export function BankForms({
  accounts,
  assets,
}: {
  accounts: { id: string; name: string }[];
  assets: { id: string; code: string; name: string }[];
}) {
  const [imported, importAction, importing] = useActionState(importStatement, initial);
  const [added, addAction, adding] = useActionState(addBankAccount, initial);
  const [showAccount, setShowAccount] = useState(false);

  return (
    <>
      <form action={importAction} className="card no-print" style={{ marginBottom: 16 }}>
        <h3 style={{ marginTop: 0 }}>Import a statement</h3>
        {imported.error && <div className="alert bad">{imported.error}</div>}
        {imported.ok && <div className="alert ok">{imported.ok}</div>}

        {accounts.length === 0 ? (
          <p className="sub">Add the bank account first.</p>
        ) : (
          <>
            <div className="row2" style={{ gap: 8, flexWrap: "wrap" }}>
              <label>
                Account
                <select name="bank_account_id" defaultValue={accounts[0].id}>
                  {accounts.map((a) => (
                    <option key={a.id} value={a.id}>
                      {a.name}
                    </option>
                  ))}
                </select>
              </label>
              <label>
                From
                <input type="date" name="period_start" required />
              </label>
              <label>
                To
                <input type="date" name="period_end" required />
              </label>
            </div>
            <div className="row2" style={{ gap: 8, flexWrap: "wrap" }}>
              <label>
                Opening balance
                <input name="opening" inputMode="decimal" defaultValue="0" />
              </label>
              <label>
                Closing balance
                <input name="closing" inputMode="decimal" required />
              </label>
              <label style={{ flex: 1, minWidth: 220 }}>
                The file
                <input type="file" name="file" accept=".csv,.ofx,.qfx,text/csv" required />
              </label>
            </div>
            <p className="sub">CSV or OFX, as the bank gives it.</p>
            <button className="btn" type="submit" disabled={importing} style={{ marginTop: 8 }}>
              Import
            </button>
          </>
        )}
      </form>

      {!showAccount ? (
        <div className="no-print" style={{ marginBottom: 16 }}>
          <button className="btn ghost" type="button" onClick={() => setShowAccount(true)}>
            Add a bank account
          </button>
        </div>
      ) : (
        <form action={addAction} className="card no-print" style={{ marginBottom: 16 }}>
          <h3 style={{ marginTop: 0 }}>Add a bank account</h3>
          {added.error && <div className="alert bad">{added.error}</div>}
          {added.ok && <div className="alert ok">{added.ok}</div>}
          <div className="row2" style={{ gap: 8, flexWrap: "wrap" }}>
            <label style={{ flex: 1, minWidth: 200 }}>
              Name
              <input name="name" required placeholder="Operating account" />
            </label>
            <label>
              Last four digits
              <input name="last4" inputMode="numeric" maxLength={4} />
            </label>
            <label>
              Ledger account
              <select name="account_id" defaultValue={assets[0]?.id ?? ""}>
                {assets.map((a) => (
                  <option key={a.id} value={a.id}>
                    {a.code} {a.name}
                  </option>
                ))}
              </select>
            </label>
          </div>
          <p className="sub">The number itself is never needed to read a statement.</p>
          <div className="row2" style={{ gap: 8, marginTop: 8 }}>
            <button className="btn" type="submit" disabled={adding}>
              Add
            </button>
            <button className="btn ghost" type="button" onClick={() => setShowAccount(false)}>
              Cancel
            </button>
          </div>
        </form>
      )}
    </>
  );
}
