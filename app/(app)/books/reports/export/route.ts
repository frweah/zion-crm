import { NextResponse } from "next/server";
import { canReach } from "@/lib/roles";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { periodFrom, readSettings, reportFor, runReport, toCsv } from "@/lib/books";

/**
 * A report as a CSV (ERP brief, E1).
 *
 * The same function the screen calls, with the same arguments, so the file
 * and the page cannot answer the question differently. An export that
 * disagrees with the screen is the thing that makes somebody stop trusting
 * both.
 */
export async function GET(request: Request) {
  const me = await requireStaff();
  if (!canReach(me, "/books")) {
    return new NextResponse("Not yours to read", { status: 404 });
  }

  const url = new URL(request.url);
  const report = reportFor(url.searchParams.get("report") ?? undefined);
  const period = periodFrom({
    from: url.searchParams.get("from") ?? undefined,
    to: url.searchParams.get("to") ?? undefined,
  });

  const supabase = await createClient();
  const settings = await readSettings(supabase);
  const asked = url.searchParams.get("basis");
  const basis = asked === "Accrual" || asked === "Cash" ? asked : settings?.basis ?? "Cash";

  let rows;
  try {
    rows = await runReport(supabase, report, period, {
      basis,
      account: url.searchParams.get("account") ?? undefined,
    });
  } catch (e) {
    return new NextResponse(e instanceof Error ? e.message : "The report could not be run", {
      status: 400,
    });
  }

  const name = `${report.key}-${period.from}-to-${period.to}.csv`;
  return new NextResponse(toCsv(report.columns, rows), {
    headers: {
      "content-type": "text/csv; charset=utf-8",
      "content-disposition": `attachment; filename="${name}"`,
      "cache-control": "no-store",
    },
  });
}
