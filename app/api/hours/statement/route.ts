import { NextResponse, type NextRequest } from "next/server";
import { getCurrentStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { statementPdf, type StatementSession } from "@/lib/statement-pdf";
import { today } from "@/lib/constants";

/**
 * A statement of hours, as a PDF (Rei, Oct 2026).
 *
 *   /api/hours/statement?from=2026-09-01&to=2026-09-30
 *   /api/hours/statement?ids=<id>,<id>,...
 *   /api/hours/statement?staff=<id>&from=…&to=…      (Admin only)
 *
 * A route rather than a server action because what comes back is a file, and
 * because the person wants it in front of them rather than saved somewhere.
 *
 * Whose hours somebody may read is the database's answer, not this file's: it
 * asks with the signed-in person's own session, so a staff member gets their
 * own sessions whatever they put in the query string. The one thing checked
 * here is the Admin-only ability to ask for somebody else by name, so that a
 * refusal reads as "that is not yours" rather than as an empty statement.
 */
export const dynamic = "force-dynamic";

export async function GET(request: NextRequest) {
  const me = await getCurrentStaff();
  if (!me) return NextResponse.json({ error: "Not signed in." }, { status: 401 });

  const params = request.nextUrl.searchParams;
  const ids = (params.get("ids") ?? "").split(",").map((s) => s.trim()).filter(Boolean);
  const from = params.get("from") ?? "";
  const to = params.get("to") ?? "";
  const who = params.get("staff") ?? me.id;

  if (who !== me.id && me.role !== "Admin") {
    return NextResponse.json({ error: "Only an Admin draws up somebody else's statement." }, { status: 403 });
  }
  if (ids.length === 0 && !(from && to)) {
    return NextResponse.json({ error: "Give a date range, or pick some sessions." }, { status: 400 });
  }

  const supabase = await createClient();
  let query = supabase
    .from("work_sessions")
    .select("id, worked_on, hours, category, description, voided, client_id, staff_id")
    .eq("staff_id", who)
    .order("worked_on");

  query = ids.length > 0 ? query.in("id", ids) : query.gte("worked_on", from).lte("worked_on", to);

  const [{ data: rows, error }, { data: person }] = await Promise.all([
    query,
    supabase.from("staff").select("name").eq("id", who).maybeSingle(),
  ]);
  if (error) return NextResponse.json({ error: error.message }, { status: 500 });
  if (!rows || rows.length === 0) {
    return NextResponse.json({ error: "There are no sessions in that range." }, { status: 404 });
  }

  // The names of the clients and categories, so the statement reads as a
  // record of work rather than as a table of identifiers.
  const clientIds = [...new Set(rows.map((r) => r.client_id).filter((v): v is string => Boolean(v)))];
  const [{ data: clients }, { data: categories }] = await Promise.all([
    clientIds.length
      ? supabase.from("clients").select("id, name").in("id", clientIds)
      : Promise.resolve({ data: [] as { id: string; name: string }[] }),
    supabase.from("work_categories").select("key, label"),
  ]);
  const clientName = new Map((clients ?? []).map((c) => [c.id, c.name]));
  const categoryLabel = new Map((categories ?? []).map((c) => [c.key, c.label]));

  const sessions: StatementSession[] = rows.map((r) => ({
    worked_on: r.worked_on,
    hours: Number(r.hours),
    category: r.category ? (categoryLabel.get(r.category) ?? r.category) : null,
    client_name: r.client_id ? (clientName.get(r.client_id) ?? null) : null,
    description: r.description,
    voided: Boolean(r.voided),
  }));

  const bytes = await statementPdf({
    staffName: person?.name ?? "Staff member",
    from: ids.length > 0 ? sessions[0].worked_on : from,
    to: ids.length > 0 ? sessions[sessions.length - 1].worked_on : to,
    sessions,
    preparedOn: today(),
  });

  const name = `Hours ${(person?.name ?? "statement").replace(/[^A-Za-z0-9 ]/g, "")} ${sessions[0].worked_on} to ${sessions[sessions.length - 1].worked_on}.pdf`;
  return new NextResponse(Buffer.from(bytes), {
    headers: {
      "content-type": "application/pdf",
      "content-disposition": `inline; filename="${name}"`,
      "cache-control": "no-store",
    },
  });
}
