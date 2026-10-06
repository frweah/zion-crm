import Link from "next/link";
import { money } from "@/lib/constants";
import { readChart, requireBooks } from "@/lib/books";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { DataTable, type DataRow } from "../../data-table";
import { PageHead } from "../../page-head";
import { BankForms } from "./bank-forms";

/**
 * Bank statements (ERP brief, E1).
 *
 * The one place an outside system touches the books, and deliberately the
 * smallest: the owner downloads a statement and uploads it. No live bank
 * link, no credentials in the CRM, nothing here that can move money.
 */
export default async function Bank() {
  await requireBooks();
  const me = await requireStaff();
  const supabase = await createClient();

  const [{ data: accounts }, { data: statements }, chart] = await Promise.all([
    supabase.from("bank_accounts").select("id, name, last4, active, account_id").order("name"),
    supabase
      .from("bank_statements")
      .select(
        "id, period_start, period_end, opening_balance, closing_balance, reconciled_at, " +
          "bank_accounts(name), bank_transactions(id, status)",
      )
      .order("period_end", { ascending: false })
      .limit(40),
    readChart(supabase),
  ]);

  const rows = (statements ?? []) as unknown as {
    id: string;
    period_start: string;
    period_end: string;
    opening_balance: number;
    closing_balance: number;
    reconciled_at: string | null;
    bank_accounts: { name: string } | null;
    bank_transactions: { id: string; status: string }[];
  }[];

  return (
    <>
      <PageHead title="Bank statements" context={`${(accounts ?? []).length} account(s)`} />

      {me.role === "Admin" && (
        <BankForms
          accounts={(accounts ?? []).filter((a) => a.active) as { id: string; name: string }[]}
          assets={chart.filter((a) => a.kind === "Asset" && a.active)}
        />
      )}

      <DataTable
        label="statements"
        columns={[
          { key: "account", label: "Account" },
          { key: "covers", label: "Covers" },
          { key: "opened", label: "Opened", align: "right" },
          { key: "closed", label: "Closed", align: "right" },
          { key: "lines", label: "Lines", align: "right" },
          { key: "standing", label: "Where it stands" },
        ]}
        rows={rows.map((st): DataRow => {
          const unmatched = st.bank_transactions.filter((t) => t.status === "Unmatched").length;
          return {
            key: st.id,
            cells: {
              account: st.bank_accounts?.name ?? "",
              covers: (
                <Link href={`/books/bank/${st.id}`}>
                  {st.period_start} to {st.period_end}
                </Link>
              ),
              opened: money(st.opening_balance),
              closed: money(st.closing_balance),
              lines: String(st.bank_transactions.length),
              standing: st.reconciled_at
                ? "Reconciled"
                : unmatched > 0
                  ? `${unmatched} to settle`
                  : "Ready to reconcile",
            },
            sort: {
              covers: st.period_end,
              opened: st.opening_balance,
              closed: st.closing_balance,
              lines: st.bank_transactions.length,
            },
          };
        })}
        empty="No statement imported yet — upload the one the bank gave you."
      />
    </>
  );
}
