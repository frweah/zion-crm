import { readChart, requireBooks } from "@/lib/books";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { RecordHeader } from "../../record-header";
import { ChartView } from "./chart-view";

/**
 * The chart of accounts (ERP brief, E1).
 *
 * Rows, not code, because the practice and its CPA will change these and
 * neither of them should need a deploy. What the CRM posts to automatically
 * is shown as a role on the account - "the one Accounts receivable goes to" -
 * so renaming an account cannot quietly break a posting.
 */
export default async function Chart() {
  await requireBooks();
  const me = await requireStaff();
  const supabase = await createClient();

  const accounts = await readChart(supabase);
  const [{ data: services }, { data: categories }, { data: revenueMap }, { data: expenseMap }] =
    await Promise.all([
      supabase.from("billing_service_rules").select("service").eq("active", true).order("service"),
      supabase.from("expense_categories").select("key, label").order("sort_order"),
      supabase.from("ledger_revenue_map").select("service, account_id"),
      supabase.from("ledger_expense_map").select("category, account_id"),
    ]);

  return (
    <>
      <RecordHeader
        back={{ href: "/books", label: "Books" }}
        title="Chart of accounts"
        standing={`${accounts.filter((a) => a.active).length} in use`}
      />
      <ChartView
        accounts={accounts}
        services={(services ?? []).map((s) => s.service as string)}
        categories={(categories ?? []) as { key: string; label: string }[]}
        revenueMap={(revenueMap ?? []) as { service: string; account_id: string }[]}
        expenseMap={(expenseMap ?? []) as { category: string; account_id: string }[]}
        isAdmin={me.role === "Admin"}
      />
    </>
  );
}
