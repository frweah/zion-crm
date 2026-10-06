import "server-only";
import { notFound } from "next/navigation";
import { canReach } from "@/lib/roles";
import { requireStaff } from "@/lib/session";
import type { createClient } from "@/lib/supabase/server";

type Supabase = Awaited<ReturnType<typeof createClient>>;

/**
 * The books, read (ERP brief, E1).
 *
 * Every figure here is a sum of postings, asked for when somebody opens the
 * screen. Nothing is stored and nothing is cached, so a report cannot drift
 * away from the ledger and there is no totals table to rebuild. The practice
 * has hundreds of clients rather than millions of rows, which is what makes
 * that the cheap answer rather than the expensive one.
 */

/**
 * Who may open a books screen: whoever the sidebar offers it to.
 *
 * Asking the navigation rather than repeating its rule means the screen and
 * the sidebar cannot disagree - and the database has the last word anyway,
 * since every table here is readable only to Admin, Billing and an Insights
 * grant.
 */
export async function requireBooks() {
  const me = await requireStaff();
  if (!canReach(me, "/books")) notFound();
  return me;
}

export type Period = { from: string; to: string; label: string };

/** A column of a report, and how it is read. */
export type Column = { key: string; label: string; money?: boolean; right?: boolean };

export type Report = {
  key: string;
  label: string;
  /** One line saying what question it answers. */
  note: string;
  /** As of a day, rather than over a period. */
  asOf?: boolean;
  columns: Column[];
};

export const REPORTS: Report[] = [
  {
    key: "profit-and-loss",
    label: "Profit & Loss",
    note: "What came in and what it cost.",
    columns: [
      { key: "code", label: "Code" },
      { key: "name", label: "Account" },
      { key: "kind", label: "Kind" },
      { key: "amount", label: "Amount", money: true, right: true },
    ],
  },
  {
    key: "balance-sheet",
    label: "Balance sheet",
    note: "What the practice has, owes and is worth.",
    asOf: true,
    columns: [
      { key: "code", label: "Code" },
      { key: "name", label: "Account" },
      { key: "kind", label: "Kind" },
      { key: "balance", label: "Balance", money: true, right: true },
    ],
  },
  {
    key: "cash-flow",
    label: "Cash flow",
    note: "Money in, out and left, month by month.",
    columns: [
      { key: "month", label: "Month" },
      { key: "money_in", label: "In", money: true, right: true },
      { key: "money_out", label: "Out", money: true, right: true },
      { key: "net", label: "Net", money: true, right: true },
      { key: "closing", label: "Left", money: true, right: true },
    ],
  },
  {
    key: "trial-balance",
    label: "Trial balance",
    note: "Every account with a posting, and the two columns that must agree.",
    asOf: true,
    columns: [
      { key: "code", label: "Code" },
      { key: "name", label: "Account" },
      { key: "debits", label: "Debits", money: true, right: true },
      { key: "credits", label: "Credits", money: true, right: true },
      { key: "balance", label: "Balance", money: true, right: true },
    ],
  },
  {
    key: "payables",
    label: "Payables aging",
    note: "What is still owed to each contractor, and for how long.",
    asOf: true,
    columns: [
      { key: "person", label: "Person" },
      { key: "bucket", label: "How old" },
      { key: "amount", label: "Owed", money: true, right: true },
    ],
  },
  {
    key: "revenue-by-service",
    label: "Revenue by service",
    note: "Which services earned the year.",
    columns: [
      { key: "label", label: "Service" },
      { key: "amount", label: "Revenue", money: true, right: true },
    ],
  },
  {
    key: "revenue-by-office",
    label: "Revenue by office",
    note: "Which USOR offices the work came from.",
    columns: [
      { key: "label", label: "Office" },
      { key: "amount", label: "Revenue", money: true, right: true },
    ],
  },
  {
    key: "revenue-by-counselor",
    label: "Revenue by counselor",
    note: "Which counselors the work came from.",
    columns: [
      { key: "label", label: "Counselor" },
      { key: "amount", label: "Revenue", money: true, right: true },
    ],
  },
  {
    key: "contractor-cost",
    label: "Contractor cost",
    note: "What each contractor cost the practice.",
    columns: [
      { key: "person", label: "Person" },
      { key: "amount", label: "Cost", money: true, right: true },
    ],
  },
  {
    key: "general-ledger",
    label: "General ledger",
    note: "One account, posting by posting, with the balance running through it.",
    columns: [
      { key: "entry_date", label: "Date" },
      { key: "memo", label: "What it was" },
      { key: "source_kind", label: "From" },
      { key: "client", label: "Client" },
      { key: "person", label: "Person" },
      { key: "debit", label: "Debit", money: true, right: true },
      { key: "credit", label: "Credit", money: true, right: true },
      { key: "running", label: "Balance", money: true, right: true },
    ],
  },
  {
    key: "1099-tie-out",
    label: "1099 tie-out",
    note: "What was recorded paid, what the ledger posted, and what the 1099 said.",
    columns: [
      { key: "person", label: "Person" },
      { key: "recorded", label: "Recorded", money: true, right: true },
      { key: "posted", label: "Posted", money: true, right: true },
      { key: "on_the_1099", label: "On the 1099", money: true, right: true },
      { key: "difference", label: "Difference", money: true, right: true },
    ],
  },
];

export const reportFor = (key: string | undefined): Report =>
  REPORTS.find((r) => r.key === key) ?? REPORTS[0];

/**
 * The period a report covers.
 *
 * The year so far by default, because that is the question the owner asks
 * most and the one the CPA asks at the end. A month or a quarter is the same
 * two dates, which is why there is no third kind of control for them.
 */
export function periodFrom(params: { from?: string; to?: string }): Period {
  const day = (s: string | undefined) => (/^\d{4}-\d{2}-\d{2}$/.test(s ?? "") ? (s as string) : null);
  const now = new Date();
  const year = now.getUTCFullYear();
  const from = day(params.from) ?? `${year}-01-01`;
  const to = day(params.to) ?? now.toISOString().slice(0, 10);
  return { from, to, label: `${from} to ${to}` };
}

/** The months and quarters somebody is likely to want, as two dates each. */
export function presets(): { label: string; from: string; to: string }[] {
  const now = new Date();
  const y = now.getUTCFullYear();
  const m = now.getUTCMonth();
  const iso = (d: Date) => d.toISOString().slice(0, 10);
  const monthStart = (year: number, month: number) => iso(new Date(Date.UTC(year, month, 1)));
  const monthEnd = (year: number, month: number) => iso(new Date(Date.UTC(year, month + 1, 0)));
  const quarter = Math.floor(m / 3);
  return [
    { label: "This month", from: monthStart(y, m), to: monthEnd(y, m) },
    { label: "Last month", from: monthStart(y, m - 1), to: monthEnd(y, m - 1) },
    { label: "This quarter", from: monthStart(y, quarter * 3), to: monthEnd(y, quarter * 3 + 2) },
    { label: "This year", from: `${y}-01-01`, to: `${y}-12-31` },
    { label: "Last year", from: `${y - 1}-01-01`, to: `${y - 1}-12-31` },
  ];
}

export type Row = Record<string, string | number | null>;

/**
 * Runs a report and gives back its rows.
 *
 * One place that knows which database function each report is, so the screen
 * and the CSV cannot answer the same question differently - which is the bug
 * that makes somebody stop trusting an export.
 */
export async function runReport(
  supabase: Supabase,
  report: Report,
  period: Period,
  options: { basis?: string; account?: string; year?: number } = {},
): Promise<Row[]> {
  const asOf = period.to;
  const call = async (fn: Parameters<Supabase["rpc"]>[0], args: Record<string, unknown>) => {
    // The arguments differ per report and the names are a union; one cast
    // here is better than eleven near-identical branches that each repeat it.
    const { data, error } = await supabase.rpc(fn, args as never);
    if (error) throw new Error(error.message);
    return (data ?? []) as Row[];
  };

  switch (report.key) {
    case "profit-and-loss":
      return call("ledger_profit_and_loss", {
        p_from: period.from,
        p_to: period.to,
        p_basis: options.basis ?? null,
      });
    case "balance-sheet":
      return call("ledger_balance_sheet", { p_as_of: asOf });
    case "cash-flow":
      return call("ledger_cash_flow", { p_from: period.from, p_to: period.to });
    case "trial-balance":
      return call("ledger_trial_balance", { p_as_of: asOf });
    case "payables":
      return call("ledger_ap_aging", { p_as_of: asOf });
    case "revenue-by-service":
      return call("ledger_revenue_by", { p_from: period.from, p_to: period.to, p_dimension: "service" });
    case "revenue-by-office":
      return call("ledger_revenue_by", { p_from: period.from, p_to: period.to, p_dimension: "office" });
    case "revenue-by-counselor":
      return call("ledger_revenue_by", { p_from: period.from, p_to: period.to, p_dimension: "counselor" });
    case "contractor-cost":
      return call("ledger_contractor_cost", { p_from: period.from, p_to: period.to });
    case "general-ledger":
      if (!options.account) return [];
      return call("ledger_general_ledger", {
        p_account: options.account,
        p_from: period.from,
        p_to: period.to,
      });
    case "1099-tie-out":
      return call("ledger_1099_tie_out", {
        p_year: options.year ?? Number(period.to.slice(0, 4)),
      });
    default:
      return [];
  }
}

/** The chart, for a picker and for the chart screen itself. */
export async function readChart(supabase: Supabase) {
  const { data } = await supabase
    .from("ledger_accounts")
    .select("id, code, name, kind, role, active, note")
    .order("code");
  return (data ?? []) as {
    id: string;
    code: string;
    name: string;
    kind: string;
    role: string | null;
    active: boolean;
    note: string;
  }[];
}

/** How the books are kept, and when the owner wants to be warned. */
export async function readSettings(supabase: Supabase) {
  const { data } = await supabase
    .from("ledger_settings")
    .select("books_start, basis, cash_floor, budget_tolerance, bill_approval_limit, purchase_request_over")
    .limit(1)
    .single();
  return (data ?? null) as {
    books_start: string;
    basis: string;
    cash_floor: number | null;
    budget_tolerance: number;
    bill_approval_limit: number | null;
    purchase_request_over: number | null;
  } | null;
}

/** One row per line, quoted the way a spreadsheet expects. */
export function toCsv(columns: Column[], rows: Row[]): string {
  const cell = (v: string | number | null) => {
    const s = v === null || v === undefined ? "" : String(v);
    return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };
  const lines = [columns.map((c) => cell(c.label)).join(",")];
  for (const row of rows) lines.push(columns.map((c) => cell(row[c.key] ?? "")).join(","));
  return lines.join("\r\n") + "\r\n";
}
