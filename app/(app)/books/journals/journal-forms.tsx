"use client";

import Link from "next/link";
import { useActionState, useState } from "react";
import { reverseEntry, writeJournal, type BooksState } from "../actions";

const initial: BooksState = { error: null, ok: null };

const LINES = 4;

/**
 * An entry written by hand.
 *
 * Four lines, because almost every hand-written entry has two and the fourth
 * is there for the one that does not. The form adds up as you type: an entry
 * that does not balance is refused by the database whatever this says, and
 * being told before pressing the button is better than being told after.
 */
export function WriteEntry({
  accounts,
}: {
  accounts: { id: string; code: string; name: string }[];
}) {
  const [state, action, pending] = useActionState(writeJournal, initial);
  const [open, setOpen] = useState(false);
  const [amounts, setAmounts] = useState<{ debit: string; credit: string }[]>(
    Array.from({ length: LINES }, () => ({ debit: "", credit: "" })),
  );

  const sum = (key: "debit" | "credit") =>
    amounts.reduce((s, a) => s + (Number(a[key].replace(/[$,\s]/g, "")) || 0), 0);
  const debits = sum("debit");
  const credits = sum("credit");
  const off = Math.round((debits - credits) * 100) / 100;

  if (!open) {
    return (
      <div className="no-print" style={{ marginBottom: 16 }}>
        <button className="btn gold" type="button" onClick={() => setOpen(true)}>
          Write an entry
        </button>
        {state.ok && <span className="sub"> {state.ok}</span>}
      </div>
    );
  }

  return (
    <form action={action} className="card no-print" style={{ marginBottom: 16 }}>
      <h3 style={{ marginTop: 0 }}>Write an entry</h3>
      {state.error && <div className="alert bad">{state.error}</div>}
      {state.ok && <div className="alert ok">{state.ok}</div>}

      <div className="row2" style={{ gap: 8, flexWrap: "wrap" }}>
        <label>
          Date
          <input type="date" name="entry_date" required />
        </label>
        <label style={{ flex: 1, minWidth: 220 }}>
          What it is
          <input name="memo" required />
        </label>
      </div>
      <label>
        Why
        <input name="reason" required placeholder="Somebody will read this who was not here" />
      </label>

      <div className="data-table" style={{ marginTop: 12 }}>
        <div className="table-wrap">
          <table data-layout="the two sides of an entry, as somebody types them">
            <thead>
              <tr>
                <th>Account</th>
                <th>Debit</th>
                <th>Credit</th>
                <th>Note</th>
              </tr>
            </thead>
            <tbody>
              {amounts.map((row, i) => (
                <tr key={i}>
                  <td>
                    <select name={`account_${i}`} defaultValue="">
                      <option value="">—</option>
                      {accounts.map((a) => (
                        <option key={a.id} value={a.id}>
                          {a.code} {a.name}
                        </option>
                      ))}
                    </select>
                  </td>
                  <td>
                    <input
                      name={`debit_${i}`}
                      inputMode="decimal"
                      value={row.debit}
                      onChange={(e) =>
                        setAmounts((prev) =>
                          prev.map((p, j) => (j === i ? { ...p, debit: e.target.value } : p)),
                        )
                      }
                    />
                  </td>
                  <td>
                    <input
                      name={`credit_${i}`}
                      inputMode="decimal"
                      value={row.credit}
                      onChange={(e) =>
                        setAmounts((prev) =>
                          prev.map((p, j) => (j === i ? { ...p, credit: e.target.value } : p)),
                        )
                      }
                    />
                  </td>
                  <td>
                    <input name={`memo_${i}`} />
                  </td>
                </tr>
              ))}
            </tbody>
            <tfoot>
              <tr>
                <th>{off === 0 ? "Balanced" : `Out by ${Math.abs(off).toFixed(2)}`}</th>
                <th>{debits.toFixed(2)}</th>
                <th>{credits.toFixed(2)}</th>
                <th />
              </tr>
            </tfoot>
          </table>
        </div>
      </div>

      <div className="row2" style={{ gap: 8, marginTop: 8 }}>
        <button className="btn" type="submit" disabled={pending || off !== 0 || debits === 0}>
          Post
        </button>
        <button className="btn ghost" type="button" onClick={() => setOpen(false)}>
          Cancel
        </button>
      </div>
    </form>
  );
}

/** A correction to one entry, reached from its row so nobody retypes an id. */
export function CorrectEntry({ id, memo }: { id: string; memo: string }) {
  const [state, action, pending] = useActionState(reverseEntry, initial);

  return (
    <form action={action} className="card no-print" style={{ marginBottom: 16 }}>
      <h3 style={{ marginTop: 0 }}>Correct &ldquo;{memo}&rdquo;</h3>
      {state.error && <div className="alert bad">{state.error}</div>}
      {state.ok && <div className="alert ok">{state.ok}</div>}
      <p className="sub">Reversing posts the mirror of the entry and leaves the original where it is.</p>
      <input type="hidden" name="journal_id" value={id} />
      <label>
        Why
        <input name="reason" required autoFocus />
      </label>
      <div className="row2" style={{ gap: 8, marginTop: 8 }}>
        <button className="btn" type="submit" disabled={pending}>
          Reverse
        </button>
        <Link className="btn ghost" href="/books/journals">
          Cancel
        </Link>
      </div>
    </form>
  );
}
