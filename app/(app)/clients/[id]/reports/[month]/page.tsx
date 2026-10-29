import { notFound } from "next/navigation";
import Link from "next/link";
import { RecordHeader } from "../../../../record-header";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { today } from "@/lib/constants";
import type { MonthlyContent } from "@/lib/report-drafts";
import { draftMonthlySummary, monthlyReportLines } from "@/lib/report-text";
import { MonthReport } from "./month-report";

/**
 * One month, as the person who signs it reads it.
 *
 * The whole report is on the screen, drawn from `monthlyReportLines` — the
 * same array the PDF draws. That is the point of this screen: the document
 * somebody signs has to be the document they read, and a screen that laid the
 * sections out in its own way would be a second renderer and a different
 * document.
 *
 * What is on the screen and deliberately not in the PDF: the weeks this month
 * was assembled from, which of them nobody confirmed, and the stretches no
 * weekly report covered. Those are the practice's own account of how good its
 * account is, which is what somebody about to sign needs and a counselor does
 * not.
 */
export default async function ClientMonthPage({
  params,
}: {
  params: Promise<{ id: string; month: string }>;
}) {
  const { id, month: asked } = await params;
  const me = await requireStaff();
  const supabase = await createClient();

  // "2026-10" in the address, the first of the month in the record.
  if (!/^\d{4}-\d{2}$/.test(asked)) notFound();
  const month = `${asked}-01`;

  const { data: client } = await supabase
    .from("clients")
    .select("id, name, client_no, agency_id, status, counselor_id")
    .eq("id", id)
    .maybeSingle();
  if (!client) notFound();

  const { data: report } = await supabase
    .from("client_monthly_reports")
    .select(
      "id, month, status, due_on, note, content, owner_id, signed_at, signed_by, sent_at, sent_to, reopen_reason, pdf_attachment_id",
    )
    .eq("client_id", id)
    .eq("month", month)
    .maybeSingle();
  if (!report) notFound();

  const whoIds = [report.owner_id, report.signed_by].filter(Boolean) as string[];
  const [{ data: counselor }, { data: staffRows }] = await Promise.all([
    client.counselor_id
      ? supabase.from("counselors").select("name, email").eq("id", client.counselor_id).maybeSingle()
      : Promise.resolve({ data: null }),
    whoIds.length
      ? supabase.from("staff").select("id, name").in("id", whoIds)
      : Promise.resolve({ data: [] as { id: string; name: string }[] }),
  ]);
  const nameOf = new Map((staffRows ?? []).map((s) => [s.id, s.name] as const));

  const content = (report.content ?? {}) as unknown as MonthlyContent;
  const drafted = draftMonthlySummary(content);
  const lines = monthlyReportLines(month, content, {
    clientName: client.name,
    clientNo: client.client_no,
    agencyId: client.agency_id,
    counselorName: counselor?.name ?? null,
    ownerName: report.owner_id ? (nameOf.get(report.owner_id) ?? null) : null,
    summary: report.note || drafted,
  });

  const title = new Date(`${month}T12:00:00Z`).toLocaleDateString("en-US", {
    month: "long",
    year: "numeric",
  });

  return (
    <>
      <RecordHeader
        back={{ href: `/clients/${id}/reports`, label: `${client.name} · Reports` }}
        title={title}
        identity={[client.name, client.client_no ? `Client #${client.client_no}` : null]}
        standing={
          <span
            className={
              "chip " +
              (report.status === "Sent"
                ? "ok"
                : report.status === "Signed"
                  ? "gold"
                  : report.due_on < today()
                    ? "warn"
                    : "")
            }
          >
            {report.status}
          </span>
        }
        actions={
          <Link
            className="btn ghost"
            href={`/clients/${id}?tab=documents`}
            style={{ textDecoration: "none" }}
          >
            Documents
          </Link>
        }
      />

      <MonthReport
        clientId={id}
        canSign={me.role === "Admin" || report.owner_id === me.id}
        report={{
          id: report.id,
          month,
          status: report.status,
          due_on: report.due_on,
          note: report.note ?? "",
          drafted,
          signed_at: report.signed_at,
          signed_by_name: report.signed_by ? (nameOf.get(report.signed_by) ?? "") : "",
          sent_at: report.sent_at,
          sent_to: report.sent_to ?? "",
          reopen_reason: report.reopen_reason ?? "",
          pdf_attachment_id: report.pdf_attachment_id,
        }}
        lines={lines}
        weeks={content.weeks ?? []}
        gaps={content.gaps ?? []}
        counselorEmail={counselor?.email ?? ""}
      />
    </>
  );
}
