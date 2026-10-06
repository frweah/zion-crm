import { NextResponse } from "next/server";
import { canReach } from "@/lib/roles";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { REPORTS, readSettings, runReport, toCsv } from "@/lib/books";
import { zip, type ZipEntry } from "@/lib/zip";

/**
 * The year-end package (ERP brief, E1).
 *
 * Every report for the year, as a CSV, in one zip, plus a note saying what
 * was in it and when it was made - because a folder of CSVs with no covering
 * page is a folder somebody has to ring up about.
 *
 * The general ledger is left out on purpose: it is one file per account and
 * the CPA asks for the accounts they care about. Everything else is here.
 */
export async function GET(request: Request) {
  const me = await requireStaff();
  if (!canReach(me, "/books")) {
    return new NextResponse("Not yours to read", { status: 404 });
  }

  const url = new URL(request.url);
  const year = Number(url.searchParams.get("year"));
  if (!Number.isInteger(year) || year < 2000 || year > 2100) {
    return new NextResponse("Which year?", { status: 400 });
  }

  const period = { from: `${year}-01-01`, to: `${year}-12-31`, label: String(year) };
  const supabase = await createClient();
  const settings = await readSettings(supabase);

  const entries: ZipEntry[] = [];
  const included: string[] = [];
  const missing: string[] = [];

  for (const report of REPORTS) {
    if (report.key === "general-ledger") continue;
    try {
      const rows = await runReport(supabase, report, period, {
        basis: settings?.basis ?? "Cash",
        year,
      });
      entries.push({ name: `${year}/${report.key}.csv`, text: toCsv(report.columns, rows) });
      included.push(`${report.label} (${rows.length} rows)`);
    } catch (e) {
      missing.push(`${report.label}: ${e instanceof Error ? e.message : "could not be run"}`);
    }
  }

  // Both bases, since which one the CPA reads is their decision and the
  // practice's default is only a default.
  for (const basis of ["Cash", "Accrual"] as const) {
    try {
      const rows = await runReport(supabase, REPORTS[0], period, { basis });
      entries.push({
        name: `${year}/profit-and-loss-${basis.toLowerCase()}.csv`,
        text: toCsv(REPORTS[0].columns, rows),
      });
    } catch {
      missing.push(`Profit & Loss on a ${basis.toLowerCase()} basis could not be run`);
    }
  }

  const { data: closed } = await supabase
    .from("ledger_periods")
    .select("month")
    .gte("month", period.from)
    .lte("month", period.to)
    .order("month");

  entries.push({
    name: `${year}/what-is-in-here.txt`,
    text: [
      `Zion Voc Rehab - books for ${year}`,
      `Made ${new Date().toISOString().slice(0, 10)} by ${me.name}`,
      `The practice keeps its books on a ${(settings?.basis ?? "Cash").toLowerCase()} basis;`,
      `Profit & Loss is here on both.`,
      "",
      "Reports",
      ...included.map((line) => `  ${line}`),
      "",
      `Months closed in ${year}: ${
        (closed ?? []).length > 0 ? (closed ?? []).map((c) => c.month).join(", ") : "none"
      }`,
      "",
      "The 1099 tie-out is the one to read first: what was recorded paid, what",
      "the ledger posted, and what the 1099 said, per contractor. They have to",
      "be the same.",
      ...(missing.length > 0 ? ["", "Could not be included:", ...missing.map((m) => `  ${m}`)] : []),
      "",
      "Every figure is a sum of postings in the CRM. Nothing here is typed in",
      "or cached, so any number can be traced to the billing item, statement or",
      "statement line that caused it.",
      "",
    ].join("\n"),
  });

  const body = zip(entries);
  return new NextResponse(body as unknown as BodyInit, {
    headers: {
      "content-type": "application/zip",
      "content-disposition": `attachment; filename="zion-books-${year}.zip"`,
      "cache-control": "no-store",
    },
  });
}
