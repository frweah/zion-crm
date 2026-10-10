import Link from "next/link";
import { money } from "@/lib/constants";
import { createClient } from "@/lib/supabase/server";
import {
  REPORTS,
  periodFrom,
  presets,
  readChart,
  readEntities,
  readSettings,
  reportFor,
  requireBooks,
  runReport,
  type Row,
} from "@/lib/books";
import { DataTable, type DataRow } from "../../data-table";
import { RecordHeader } from "../../record-header";

/**
 * The reports (ERP brief, E1).
 *
 * One screen: pick a report, pick a period. The brief lists seven and this
 * offers eleven, which is the same three controls either way - and a date
 * picker that exists once is a date picker that behaves the same everywhere.
 *
 * Profit & Loss is the only one with a choice to make, and it is the choice
 * the practice actually argues about: cash or accrual. The default is the
 * practice's own setting, cash until the CPA says otherwise, and the other
 * one is a link rather than a setting, because reading it the other way is a
 * question somebody asks once and not a decision about the books.
 */
export default async function BooksReports({
  searchParams,
}: {
  searchParams: Promise<{
    report?: string;
    from?: string;
    to?: string;
    basis?: string;
    account?: string;
    entity?: string;
  }>;
}) {
  await requireBooks();
  const params = await searchParams;
  const report = reportFor(params.report);
  const period = periodFrom(params);
  const supabase = await createClient();
  const settings = await readSettings(supabase);
  const basis = params.basis === "Accrual" || params.basis === "Cash" ? params.basis : settings?.basis ?? "Cash";

  const chart = report.key === "general-ledger" ? await readChart(supabase) : [];
  // One set of books today (E5). The picker is here for the day there are two.
  const entities = await readEntities(supabase);
  const entity = entities.some((e) => e.id === params.entity) ? params.entity : undefined;
  const account = params.account ?? chart.find((a) => a.role === "bank")?.id;

  let rows: Row[] = [];
  let failed: string | null = null;
  try {
    rows = await runReport(supabase, report, period, { basis, account, entity });
  } catch (e) {
    failed = e instanceof Error ? e.message : "The report could not be run.";
  }

  const query = (over: Record<string, string | undefined>) => {
    const next = new URLSearchParams();
    const all = { report: report.key, from: period.from, to: period.to, basis, account, entity, ...over };
    for (const [k, v] of Object.entries(all)) if (v) next.set(k, v);
    return `?${next.toString()}`;
  };

  // The one figure a reader checks first, by report.
  const total = rows.reduce((sum, r) => {
    const money = report.columns.filter((c) => c.money);
    const key = report.key === "trial-balance" ? "debits" : money[money.length - 1]?.key;
    return sum + (key ? Number(r[key] ?? 0) : 0);
  }, 0);

  return (
    <>
      <RecordHeader
        back={{ href: "/books", label: "Books" }}
        title="Reports"
        standing={report.note}
        actions={
          <a className="btn ghost" href={`/books/reports/export${query({})}`}>
            Download CSV
          </a>
        }
      />

      <div className="segmented no-print" role="group" aria-label="Reports">
        {REPORTS.map((r) => (
          <Link key={r.key} href={query({ report: r.key })} className={r.key === report.key ? "on" : ""}>
            {r.label}
          </Link>
        ))}
      </div>

      <form className="row2 no-print" style={{ gap: 8, alignItems: "flex-end", margin: "12px 0" }}>
        <input type="hidden" name="report" value={report.key} />
        {account && report.key === "general-ledger" && (
          <label>
            Account
            <select name="account" defaultValue={account}>
              {chart.map((a) => (
                <option key={a.id} value={a.id}>
                  {a.code} {a.name}
                </option>
              ))}
            </select>
          </label>
        )}
        <label>
          {report.asOf ? "Up to" : "From"}
          <input type="date" name="from" defaultValue={period.from} />
        </label>
        <label>
          {report.asOf ? "As of" : "To"}
          <input type="date" name="to" defaultValue={period.to} />
        </label>
        {entities.length > 1 && (
          <label>
            Books
            <select name="entity" defaultValue={entity ?? ""}>
              <option value="">All of them</option>
              {entities.map((e) => (
                <option key={e.id} value={e.id}>
                  {e.name}
                </option>
              ))}
            </select>
          </label>
        )}
        {report.key === "profit-and-loss" && (
          <label>
            Basis
            <select name="basis" defaultValue={basis}>
              <option value="Cash">Cash</option>
              <option value="Accrual">Accrual</option>
            </select>
          </label>
        )}
        <button className="btn" type="submit">
          Show
        </button>
      </form>

      <p className="sub no-print">
        {presets().map((p, i) => (
          <span key={p.label}>
            {i > 0 && " · "}
            <Link href={query({ from: p.from, to: p.to })}>{p.label}</Link>
          </span>
        ))}
      </p>

      {failed ? (
        <p className="alert">{failed}</p>
      ) : (
        <DataTable
          label={report.label.toLowerCase()}
          columns={report.columns.map((c) => ({
            key: c.key,
            label: c.label,
            ...(c.right ? { align: "right" as const } : {}),
          }))}
          rows={rows.map((row, i): DataRow => ({
            key: String(i),
            cells: Object.fromEntries(
              report.columns.map((c) => [
                c.key,
                c.money ? money(Number(row[c.key] ?? 0)) : String(row[c.key] ?? ""),
              ]),
            ),
            sort: Object.fromEntries(
              report.columns.map((c) => [c.key, c.money ? Number(row[c.key] ?? 0) : String(row[c.key] ?? "")]),
            ),
          }))}
          pageSize={200}
          empty={`Nothing posted ${report.asOf ? `by ${period.to}` : `between ${period.from} and ${period.to}`}.`}
        />
      )}

      {rows.length > 0 && (
        <p className="sub">
          {report.key === "trial-balance"
            ? `Debits ${money(rows.reduce((sum, r) => sum + Number(r.debits ?? 0), 0))} · credits ${money(
                rows.reduce((sum, r) => sum + Number(r.credits ?? 0), 0),
              )}`
            : `Total ${money(total)}`}
        </p>
      )}

      <p className="lock no-print">
        Every figure here is a sum of postings, so a report cannot disagree with the ledger. Use the
        browser&rsquo;s print for a PDF; the page is laid out for it.
      </p>
    </>
  );
}
