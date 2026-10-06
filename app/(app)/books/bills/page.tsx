import { readChart, readSettings, requireBooks } from "@/lib/books";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { PageHead } from "../../page-head";
import { BillList } from "./bill-list";

/**
 * Bills (ERP brief, E3).
 *
 * A bill has a life: it arrives, somebody approves it, it is scheduled, it is
 * paid. Each of those posts to the ledger on its own, so what the books say
 * the practice owes is what the bills say, always, without anybody
 * reconciling the two.
 *
 * Approval is a threshold rather than a role: under the number the owner
 * sets, whoever does the billing approves; over it, an Admin. A rule that
 * says "Billing may approve small things" is a rule somebody has to look up.
 */
export default async function Bills({
  searchParams,
}: {
  searchParams: Promise<{ show?: string }>;
}) {
  await requireBooks();
  const me = await requireStaff();
  const show = (await searchParams).show ?? "open";
  const supabase = await createClient();

  let bills = supabase
    .from("vendor_bills")
    .select(
      "id, number, bill_date, due_date, amount, status, description, scheduled_for, paid_on, " +
        "method, reference, void_reason, account_id, vendor_id, vendors(name), ledger_accounts(code, name)",
    )
    .order("due_date", { ascending: true, nullsFirst: false })
    .limit(300);
  if (show === "open") bills = bills.in("status", ["Awaiting approval", "Approved", "Scheduled"]);
  else if (show === "paid") bills = bills.eq("status", "Paid");

  const [{ data: rows }, { data: vendors }, { data: schedules }, chart, settings] = await Promise.all([
    bills,
    supabase.from("vendors").select("id, name, expense_account_id, terms_days").eq("active", true).order("name"),
    supabase
      .from("vendor_bill_schedules")
      .select("id, amount, description, every_months, next_due, active, vendors(name), ledger_accounts(code, name)")
      .order("next_due"),
    readChart(supabase),
    readSettings(supabase),
  ]);

  return (
    <>
      <PageHead
        title="Bills"
        context={
          settings?.bill_approval_limit
            ? `Billing approves up to ${settings.bill_approval_limit}; above that, an Admin`
            : "An Admin approves every bill until a limit is set"
        }
      />
      <BillList
        show={show}
        bills={(rows ?? []) as never}
        vendors={(vendors ?? []) as never}
        schedules={(schedules ?? []) as never}
        accounts={chart.filter((a) => a.kind === "Expense" && a.active)}
        isAdmin={me.role === "Admin"}
        approvalLimit={settings?.bill_approval_limit ?? null}
      />
    </>
  );
}
