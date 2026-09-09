import { NextResponse, type NextRequest } from "next/server";
import { getCurrentStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { EXPORTS, toCsv, monthRange } from "@/lib/exports";

/**
 * A month of the record, as a CSV.
 *
 * Reads through the ordinary Supabase client, so row-level security applies to
 * an export exactly as it does to a screen: a person who cannot see a client's
 * restricted detail does not get a file containing it either. The column lists
 * below are written out rather than selected with a star, so adding a column
 * to a table never quietly adds it to a file that leaves the building.
 */

const NOT_FOUND = () =>
  NextResponse.json({ error: "No such export." }, { status: 404 });

export async function GET(
  request: NextRequest,
  context: { params: Promise<{ kind: string }> },
) {
  const me = await getCurrentStaff();
  if (!me) return NextResponse.json({ error: "Not signed in." }, { status: 401 });

  const { kind } = await context.params;
  const spec = EXPORTS.find((e) => e.key === kind);
  if (!spec) return NOT_FOUND();
  if (spec.adminOnly && me.role !== "Admin") {
    return NextResponse.json({ error: "Admin only." }, { status: 403 });
  }

  const { month, start, end } = monthRange(request.nextUrl.searchParams.get("month"));
  const supabase = await createClient();

  const inMonth = (d: string | null | undefined) => Boolean(d && d >= start && d <= end);

  let headers: string[] = [];
  let rows: unknown[][] = [];

  if (kind === "service-hours") {
    const [{ data: entries }, { data: auths }, { data: clients }, { data: staff }] =
      await Promise.all([
        supabase
          .from("service_entries")
          .select("auth_id, date, hours, non_billable, primary_code, secondary_code, notes, staff_id")
          .gte("date", start)
          .lte("date", end)
          .order("date"),
        supabase.from("authorizations").select("id, number, service_type, client_id, rate, rate_type"),
        supabase.from("clients").select("id, name, client_no, agency_id"),
        supabase.from("staff").select("id, name"),
      ]);

    const authById = new Map((auths ?? []).map((a) => [a.id, a]));
    const clientById = new Map((clients ?? []).map((c) => [c.id, c]));
    const staffName = new Map((staff ?? []).map((s) => [s.id, s.name]));

    headers = [
      "Date", "Client", "Client no", "USOR ID", "Authorization", "Service",
      "Hours", "Billable", "Rate type", "Rate", "Primary code", "Secondary code",
      "Logged by", "Notes",
    ];
    rows = (entries ?? []).map((e) => {
      const a = authById.get(e.auth_id);
      const c = a ? clientById.get(a.client_id) : undefined;
      return [
        e.date, c?.name ?? "", c?.client_no ?? "", c?.agency_id ?? "",
        a?.number ?? "", a?.service_type ?? "", e.hours, e.non_billable ? "No" : "Yes",
        a?.rate_type ?? "", a?.rate ?? "", e.primary_code, e.secondary_code,
        e.staff_id ? (staffName.get(e.staff_id) ?? "") : "", e.notes,
      ];
    });
  } else if (kind === "invoices") {
    const [{ data: invoices }, { data: auths }, { data: clients }] = await Promise.all([
      supabase
        .from("invoices")
        .select("auth_id, number, date, amount, status, sent_date, paid_date, warrant, voucher, service_type")
        .or(`and(date.gte.${start},date.lte.${end}),and(paid_date.gte.${start},paid_date.lte.${end})`)
        .order("date"),
      supabase.from("authorizations").select("id, number, client_id"),
      supabase.from("clients").select("id, name, client_no, agency_id"),
    ]);

    const authById = new Map((auths ?? []).map((a) => [a.id, a]));
    const clientById = new Map((clients ?? []).map((c) => [c.id, c]));

    headers = [
      "Invoice", "Date", "Client", "Client no", "USOR ID", "Authorization", "Service",
      "Amount", "Status", "Sent", "Paid", "Warrant", "Voucher", "In this month",
    ];
    rows = (invoices ?? []).map((i) => {
      const a = i.auth_id ? authById.get(i.auth_id) : undefined;
      const c = a ? clientById.get(a.client_id) : undefined;
      // Which month a row belongs to is the question the accountant is
      // actually asking, so it is answered in the file rather than left to
      // whoever sorts it.
      const belongs = [
        inMonth(i.date) ? "raised" : null,
        inMonth(i.paid_date) ? "paid" : null,
      ].filter(Boolean).join(" and ");
      return [
        i.number, i.date, c?.name ?? "", c?.client_no ?? "", c?.agency_id ?? "",
        a?.number ?? "", i.service_type, i.amount, i.status,
        i.sent_date ?? "", i.paid_date ?? "", i.warrant, i.voucher, belongs,
      ];
    });
  } else if (kind === "authorizations") {
    const [{ data: econ }, { data: clients }] = await Promise.all([
      supabase
        .from("authorization_economics")
        .select(
          "auth_id, client_id, auth_number, service_type, funding_source, status, rate_type, rate, total_hours, start_date, end_date, hours_used, hours_left, authorized, earned, invoiced, received, outstanding, unbilled, committed",
        ),
      supabase.from("clients").select("id, name, client_no, agency_id"),
    ]);

    const clientById = new Map((clients ?? []).map((c) => [c.id, c]));

    headers = [
      "Authorization", "Client", "Client no", "USOR ID", "Service", "Funding", "Status",
      "Rate type", "Rate", "Authorized hours", "Hours used", "Hours left",
      "Start", "End", "Authorized", "Earned", "Invoiced", "Received", "Outstanding",
      "Earned not invoiced", "Authorized not earned",
    ];
    rows = (econ ?? []).map((e) => {
      const c = e.client_id ? clientById.get(e.client_id) : undefined;
      return [
        e.auth_number, c?.name ?? "", c?.client_no ?? "", c?.agency_id ?? "",
        e.service_type, e.funding_source, e.status, e.rate_type, e.rate,
        e.total_hours ?? "", e.hours_used, e.hours_left ?? "",
        e.start_date ?? "", e.end_date ?? "", e.authorized, e.earned, e.invoiced,
        e.received, e.outstanding, e.unbilled, e.committed,
      ];
    });
  } else if (kind === "placements") {
    const [{ data: placements }, { data: clients }] = await Promise.all([
      supabase
        .from("placements")
        .select("client_id, employer, title, start_date, wage, hours_week, check30, check60, check90, jp_submitted, jp_paid, notes")
        .gte("start_date", start)
        .lte("start_date", end)
        .order("start_date"),
      supabase.from("clients").select("id, name, client_no, agency_id"),
    ]);

    const clientById = new Map((clients ?? []).map((c) => [c.id, c]));

    headers = [
      "Started", "Client", "Client no", "USOR ID", "Employer", "Position",
      "Wage", "Hours a week", "30-day check", "60-day check", "90-day check",
      "Fee submitted", "Fee paid", "Notes",
    ];
    rows = (placements ?? []).map((p) => {
      const c = clientById.get(p.client_id);
      return [
        p.start_date, c?.name ?? "", c?.client_no ?? "", c?.agency_id ?? "",
        p.employer, p.title, p.wage ?? "", p.hours_week ?? "",
        p.check30 ?? "", p.check60 ?? "", p.check90 ?? "",
        p.jp_submitted ?? "", p.jp_paid ?? "", p.notes,
      ];
    });
  } else if (kind === "referrals") {
    const [{ data: pipeline }, { data: counselors }, { data: staff }] = await Promise.all([
      supabase
        .from("client_pipeline")
        .select(
          "client_id, name, status, stage, counselor_id, referring_office, assigned_staff_id, referred_at, stage_since, days_in_stage, auth_count, first_placement_on",
        ),
      supabase.from("counselors").select("id, name, office"),
      supabase.from("staff").select("id, name"),
    ]);

    const counselorById = new Map((counselors ?? []).map((k) => [k.id, k]));
    const staffName = new Map((staff ?? []).map((s) => [s.id, s.name]));

    // The whole active caseload, plus anybody referred in the month whatever
    // has become of them since.
    const wanted = (pipeline ?? []).filter(
      (p) => p.status === "Active" || inMonth((p.referred_at ?? "").slice(0, 10)),
    );

    headers = [
      "Client", "Status", "Stage", "Days in stage", "Referred", "Referred in this month",
      "Counselor", "Counselor office", "Referring office", "Assigned to",
      "Authorizations", "First placement",
    ];
    rows = wanted.map((p) => {
      const k = p.counselor_id ? counselorById.get(p.counselor_id) : undefined;
      return [
        p.name, p.status, p.stage, p.days_in_stage,
        (p.referred_at ?? "").slice(0, 10),
        inMonth((p.referred_at ?? "").slice(0, 10)) ? "Yes" : "No",
        k?.name ?? "", k?.office ?? "", p.referring_office,
        p.assigned_staff_id ? (staffName.get(p.assigned_staff_id) ?? "") : "",
        p.auth_count, p.first_placement_on ?? "",
      ];
    });
  } else if (kind === "contractor-hours") {
    const [{ data: sessions }, { data: staff }, { data: clients }] = await Promise.all([
      supabase
        .from("work_session_values")
        .select("staff_id, worked_on, hours, description, client_id, category_label, pay_rate, rate_unit, amount, statement_id")
        .gte("worked_on", start)
        .lte("worked_on", end)
        .order("worked_on"),
      supabase.from("staff").select("id, name, role"),
      supabase.from("clients").select("id, name"),
    ]);

    const staffById = new Map((staff ?? []).map((s) => [s.id, s]));
    const clientName = new Map((clients ?? []).map((c) => [c.id, c.name]));

    headers = [
      "Day", "Staff", "Role", "Hours", "Kind of time", "Client", "Description",
      "Rate", "Rate unit", "Amount", "On a statement",
    ];
    rows = (sessions ?? []).map((s) => [
      s.worked_on,
      s.staff_id ? (staffById.get(s.staff_id)?.name ?? "") : "",
      s.staff_id ? (staffById.get(s.staff_id)?.role ?? "") : "",
      s.hours,
      s.category_label ?? "Not categorised",
      s.client_id ? (clientName.get(s.client_id) ?? "") : "",
      s.description,
      s.pay_rate ?? "",
      s.rate_unit ?? "",
      s.amount ?? "",
      s.statement_id ? "Yes" : "No",
    ]);
  } else {
    return NOT_FOUND();
  }

  const body = toCsv(headers, rows);
  const filename = `zion-${kind}-${month}.csv`;

  return new NextResponse(body, {
    headers: {
      "Content-Type": "text/csv; charset=utf-8",
      "Content-Disposition": `attachment; filename="${filename}"`,
      "Cache-Control": "no-store",
    },
  });
}
