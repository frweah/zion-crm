import { money } from "@/lib/constants";
import { periodFrom, presets, readChart, requireBooks } from "@/lib/books";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { DataTable, type DataRow } from "../../data-table";
import { PageHead } from "../../page-head";
import { BudgetGrid } from "./budget-grid";

/**
 * Budget against actual (ERP brief, E2).
 *
 * The variance is signed so that positive is good either way: revenue above
 * budget and cost below it both read as a gain. The alternative - a column
 * that means "more" and leaves the reader to work out whether more is good -
 * is how a report gets misread every month by everybody.
 *
 * An account nobody budgeted is never over budget. A zero somebody never
 * typed is not a promise, and treating it as one would fill the screen with
 * accounts that are "over" by whatever they cost.
 */
export default async function Budget({
  searchParams,
}: {
  searchParams: Promise<{ from?: string; to?: string; year?: string }>;
}) {
  await requireBooks();
  const me = await requireStaff();
  const params = await searchParams;
  const period = periodFrom(params);
  const year = Number(params.year) || Number(period.to.slice(0, 4));

  const supabase = await createClient();
  const [{ data: variance }, { data: budgets }, chart] = await Promise.all([
    supabase.rpc("ledger_budget_variance", { p_from: period.from, p_to: period.to }),
    supabase
      .from("ledger_budgets")
      .select("account_id, month, amount")
      .gte("month", `${year}-01-01`)
      .lte("month", `${year}-12-01`),
    readChart(supabase),
  ]);

  const rows = (variance ?? []) as {
    account_id: string;
    code: string;
    name: string;
    kind: string;
    budget: number;
    actual: number;
    variance: number;
    over: boolean;
  }[];

  const total = (key: "budget" | "actual" | "variance") =>
    rows.reduce((sum, r) => sum + Number(r[key]), 0);

  return (
    <>
      <PageHead
        title="Budget"
        context={`${period.from} to ${period.to}`}
        actions={
          <a
            className="btn ghost"
            href={`/books/reports/export?report=profit-and-loss&from=${period.from}&to=${period.to}`}
          >
            Download CSV
          </a>
        }
      />

      <form className="row2 no-print" style={{ gap: 8, alignItems: "flex-end", marginBottom: 12 }}>
        <label>
          From
          <input type="date" name="from" defaultValue={period.from} />
        </label>
        <label>
          To
          <input type="date" name="to" defaultValue={period.to} />
        </label>
        <button className="btn" type="submit">
          Show
        </button>
      </form>

      <p className="sub no-print">
        {presets().map((p, i) => (
          <span key={p.label}>
            {i > 0 && " · "}
            <a href={`?from=${p.from}&to=${p.to}`}>{p.label}</a>
          </span>
        ))}
      </p>

      <DataTable
        label="accounts"
        columns={[
          { key: "code", label: "Code" },
          { key: "name", label: "Account" },
          { key: "kind", label: "Kind" },
          { key: "budget", label: "Budget", align: "right" },
          { key: "actual", label: "Actual", align: "right" },
          { key: "variance", label: "Variance", align: "right" },
          { key: "standing", label: "Standing" },
        ]}
        rows={rows.map((r): DataRow => ({
          key: r.account_id,
          cells: {
            code: r.code,
            name: r.name,
            kind: r.kind,
            budget: money(r.budget),
            actual: money(r.actual),
            variance: money(r.variance),
            standing: r.over ? "Over budget" : r.budget === 0 ? "No budget set" : "Within budget",
          },
          sort: { budget: r.budget, actual: r.actual, variance: r.variance },
        }))}
        pageSize={100}
        empty="Nothing budgeted and nothing posted in this period."
      />

      {rows.length > 0 && (
        <p className="sub">
          Budget {money(total("budget"))} · actual {money(total("actual"))} · variance{" "}
          {money(total("variance"))}
        </p>
      )}

      {me.role === "Admin" && (
        <BudgetGrid
          year={year}
          accounts={chart.filter((a) => a.active && (a.kind === "Revenue" || a.kind === "Expense"))}
          budgets={(budgets ?? []) as { account_id: string; month: string; amount: number }[]}
        />
      )}
    </>
  );
}
