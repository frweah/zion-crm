import { notFound } from "next/navigation";
import { money } from "@/lib/constants";
import { readChart, requireBooks } from "@/lib/books";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { RecordHeader } from "../../../record-header";
import { StatementLines } from "./statement-lines";

/**
 * One statement, line by line (ERP brief, E1).
 *
 * The ledger says what the practice believes happened; the statement says
 * what the bank did. Where they differ one of them is wrong, and the whole
 * point of this screen is to find out which before the year is closed - so
 * the difference is at the top, in words, and the button that marks the
 * statement reconciled refuses while it is not zero.
 */
export default async function Statement({ params }: { params: Promise<{ id: string }> }) {
  await requireBooks();
  const me = await requireStaff();
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();

  const supabase = await createClient();
  const [{ data: statement }, { data: lines }, { data: suggestions }, { data: standing }, chart] =
    await Promise.all([
      supabase
        .from("bank_statements")
        .select(
          "id, period_start, period_end, opening_balance, closing_balance, reconciled_at, note, bank_accounts(name, last4)",
        )
        .eq("id", id)
        .single(),
      supabase
        .from("bank_transactions")
        .select("id, posted_on, description, amount, status, ignored_reason, journal_id")
        .eq("statement_id", id)
        .order("posted_on"),
      supabase.rpc("bank_suggestions", { p_statement: id }),
      supabase.rpc("bank_reconciliation", { p_statement: id }),
      readChart(supabase),
    ]);

  if (!statement) notFound();

  const s = statement as unknown as {
    id: string;
    period_start: string;
    period_end: string;
    opening_balance: number;
    closing_balance: number;
    reconciled_at: string | null;
    bank_accounts: { name: string; last4: string } | null;
  };
  const where = ((standing ?? []) as {
    statement_total: number;
    statement_closing: number;
    ledger_closing: number;
    unsettled: number;
    difference: number;
  }[])[0];

  return (
    <>
      <RecordHeader
        back={{ href: "/books/bank", label: "Bank statements" }}
        title={`${s.bank_accounts?.name ?? "Statement"} · ${s.period_start} to ${s.period_end}`}
        standing={
          s.reconciled_at
            ? `Reconciled ${s.reconciled_at.slice(0, 10)}`
            : where
              ? where.difference === 0 && where.unsettled === 0
                ? "The ledger and the bank agree"
                : `The ledger and the bank differ by ${money(where.difference)}`
              : undefined
        }
      />

      {where && (
        <div className="data-table" style={{ marginBottom: 16 }}>
          <div className="table-wrap">
            <table data-layout="where the statement and the ledger stand against each other">
              <tbody>
                <tr>
                  <th>On the statement</th>
                  <td className="num">{money(where.statement_closing)}</td>
                  <td className="sub">What the bank says it closed at</td>
                </tr>
                <tr>
                  <th>Its own lines</th>
                  <td className="num">{money(where.statement_total)}</td>
                  <td className="sub">The opening balance plus every line on it</td>
                </tr>
                <tr>
                  <th>In the ledger</th>
                  <td className="num">{money(where.ledger_closing)}</td>
                  <td className="sub">What the books say was in the account by {s.period_end}</td>
                </tr>
                <tr>
                  <th>Difference</th>
                  <td className="num">{money(where.difference)}</td>
                  <td className="sub">
                    {where.unsettled > 0
                      ? `${where.unsettled} line(s) still to settle`
                      : where.difference === 0
                        ? "Nothing outstanding"
                        : "Find it before reconciling"}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      )}

      <StatementLines
        statementId={s.id}
        reconciled={Boolean(s.reconciled_at)}
        canSettle={me.role === "Admin"}
        lines={(lines ?? []) as never}
        suggestions={(suggestions ?? []) as never}
        accounts={chart.filter((a) => a.active)}
      />
    </>
  );
}
