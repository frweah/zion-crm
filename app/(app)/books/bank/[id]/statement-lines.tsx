"use client";

import { useActionState, useState } from "react";
import { money } from "@/lib/constants";
import { DataTable, type DataRow } from "../../../data-table";
import { reconcileStatement, settleLine, type BooksState } from "../../actions";

const initial: BooksState = { error: null, ok: null };

type Line = {
  id: string;
  posted_on: string;
  description: string;
  amount: number;
  status: string;
  ignored_reason: string;
  journal_id: string | null;
};

type Suggestion = {
  transaction_id: string;
  kind: string;
  why: string;
  account_id: string | null;
  journal_id: string | null;
};

/**
 * The lines, and what to do with each.
 *
 * The suggestion is shown as a sentence, not pre-applied. A ledger that
 * guesses and is usually right is worse than one that asks: the wrong guess
 * is invisible and the question is not.
 */
export function StatementLines({
  statementId,
  reconciled,
  canSettle,
  lines,
  suggestions,
  accounts,
}: {
  statementId: string;
  reconciled: boolean;
  canSettle: boolean;
  lines: Line[];
  suggestions: Suggestion[];
  accounts: { id: string; code: string; name: string; kind: string }[];
}) {
  const [settled, settleAction] = useActionState(settleLine, initial);
  const [done, reconcileAction, reconciling] = useActionState(reconcileStatement, initial);
  const [open, setOpen] = useState<string | null>(null);

  const suggestion = new Map(suggestions.map((s) => [s.transaction_id, s]));
  const unsettled = lines.filter((l) => l.status === "Unmatched").length;

  return (
    <>
      {settled.error && <div className="alert bad">{settled.error}</div>}
      {done.error && <div className="alert bad">{done.error}</div>}
      {done.ok && <div className="alert ok">{done.ok}</div>}

      <DataTable
        label="lines"
        columns={[
          { key: "posted_on", label: "Date" },
          { key: "description", label: "What the bank called it" },
          { key: "amount", label: "Amount", align: "right" },
          { key: "standing", label: "Where it stands" },
          ...(canSettle && !reconciled ? [{ key: "act", label: "", sortable: false }] : []),
        ]}
        rows={lines.map((l): DataRow => {
          const s2 = suggestion.get(l.id);
          return {
            key: l.id,
            cells: {
              posted_on: l.posted_on,
              description: l.description,
              amount: money(l.amount),
              standing:
                l.status === "Matched"
                  ? "Matched to a posting"
                  : l.status === "Ignored"
                    ? `Set aside — ${l.ignored_reason}`
                    : (s2?.why ?? "Not settled"),
              ...(canSettle && !reconciled
                ? {
                    act:
                      l.status === "Unmatched" ? (
                        <button
                          className="btn ghost"
                          type="button"
                          onClick={() => setOpen(open === l.id ? null : l.id)}
                        >
                          {open === l.id ? "Close" : "Settle"}
                        </button>
                      ) : (
                        ""
                      ),
                  }
                : {}),
            },
            sort: { amount: l.amount },
          };
        })}
        empty="This statement has no lines on it."
      />

      {open &&
        (() => {
          const line = lines.find((l) => l.id === open);
          const s = suggestion.get(open);
          if (!line) return null;
          return (
            <div className="card no-print" style={{ marginTop: 16 }}>
              <h3 style={{ marginTop: 0 }}>
                {line.posted_on} · {line.description} · {money(line.amount)}
              </h3>
              <p className="sub">{s?.why ?? "Say what this was."}</p>

              {s?.journal_id && (
                <form action={settleAction} style={{ marginBottom: 12 }}>
                  <input type="hidden" name="transaction_id" value={line.id} />
                  <input type="hidden" name="statement_id" value={statementId} />
                  <input type="hidden" name="how" value="match" />
                  <input type="hidden" name="journal_id" value={s.journal_id} />
                  <button className="btn gold" type="submit">
                    This is that posting
                  </button>
                </form>
              )}

              <form action={settleAction} style={{ marginBottom: 12 }}>
                <input type="hidden" name="transaction_id" value={line.id} />
                <input type="hidden" name="statement_id" value={statementId} />
                <input type="hidden" name="how" value="post" />
                <div className="row2" style={{ gap: 8, flexWrap: "wrap", alignItems: "flex-end" }}>
                  <label>
                    Post it as
                    <select name="account_id" defaultValue={s?.account_id ?? ""}>
                      <option value="">—</option>
                      {accounts.map((a) => (
                        <option key={a.id} value={a.id}>
                          {a.code} {a.name}
                        </option>
                      ))}
                    </select>
                  </label>
                  <label style={{ flex: 1, minWidth: 200 }}>
                    Note
                    <input name="memo" defaultValue={line.description} />
                  </label>
                  <button className="btn" type="submit">
                    Post
                  </button>
                </div>
              </form>

              <form action={settleAction}>
                <input type="hidden" name="transaction_id" value={line.id} />
                <input type="hidden" name="statement_id" value={statementId} />
                <input type="hidden" name="how" value="ignore" />
                <div className="row2" style={{ gap: 8, flexWrap: "wrap", alignItems: "flex-end" }}>
                  <label style={{ flex: 1, minWidth: 220 }}>
                    Or set it aside, because
                    <input name="reason" required />
                  </label>
                  <button className="btn ghost" type="submit">
                    Set aside
                  </button>
                </div>
              </form>
            </div>
          );
        })()}

      {canSettle && !reconciled && (
        <form action={reconcileAction} style={{ marginTop: 16 }} className="no-print">
          <input type="hidden" name="statement_id" value={statementId} />
          <button className="btn gold" type="submit" disabled={reconciling || unsettled > 0}>
            Reconcile this statement
          </button>
          <p className="sub">
            {unsettled > 0
              ? `${unsettled} line(s) still to settle.`
              : "It will be refused if the ledger and the bank still differ."}
          </p>
        </form>
      )}
    </>
  );
}
