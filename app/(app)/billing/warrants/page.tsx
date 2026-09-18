import { can } from "@/lib/roles";
import { redirect } from "next/navigation";
import Link from "next/link";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { money, fmtStamp } from "@/lib/constants";
import { WarrantsToReview } from "./review-section";
import { PageHead } from "../../page-head";
import { DataTable, type DataRow } from "../../data-table";

/**
 * Every warrant received.
 *
 * What USOR actually paid, read by the agent from the stubs in the _Warrants
 * folder. The lines waiting for review are on Billing → Invoices beside the
 * money they settle; they are repeated at the top here only as the same
 * section, not a second list.
 */

type PageRow = {
  id: string;
  page_no: number;
  image_path: string;
  warrant_no: string;
  warrant_date: string | null;
  total: number | null;
  status: string;
  received_at: string;
  warrant_documents: { filename: string; page_count: number } | null;
  warrant_lines: { status: string; amount: number | null }[];
};

export default async function WarrantsPage() {
  const me = await requireStaff();
  if (!can(me, "billing", "view")) redirect("/dashboard");

  const supabase = await createClient();
  const { data: pageData } = await supabase
    .from("warrant_pages")
    .select("id, page_no, image_path, warrant_no, warrant_date, total, status, received_at, warrant_documents(filename, page_count), warrant_lines(status, amount)")
    .order("received_at", { ascending: false })
    .limit(300);

  const pages = (pageData ?? []) as unknown as PageRow[];
  const allLines = pages.flatMap((p) => p.warrant_lines ?? []);
  const count = (s: string) => allLines.filter((l) => l.status === s).length;
  const paidOnPages = allLines
    .filter((l) => ["Reconciled", "Already recorded", "Resolved by hand"].includes(l.status))
    .reduce((s, l) => s + Number(l.amount ?? 0), 0);

  const received: DataRow[] = pages.map((p) => {
    const lines = p.warrant_lines ?? [];
    const lineCount = (s: string) => lines.filter((l) => l.status === s).length;
    return {
      key: p.id,
      cells: {
        warrant: (
          <>
            <b>{p.warrant_no || "—"}</b>
            <div className="lock">
              page {p.page_no} · {p.warrant_documents?.filename ?? ""}
              {p.image_path && (
                <>
                  {" · "}
                  <a href={`/billing/warrants/image/${p.id}`} target="_blank" rel="noopener" style={{ color: "var(--teal)" }}>
                    page image
                  </a>
                </>
              )}
            </div>
          </>
        ),
        date: p.warrant_date ?? "—",
        total: p.total !== null ? money(Number(p.total)) : "—",
        lines: (
          <span className="lock">
            {lines.length} · {lineCount("Reconciled")} paid · {lineCount("Already recorded")} recorded ·{" "}
            {lineCount("Resolved by hand")} by hand · {lineCount("Dismissed")} set aside
          </span>
        ),
        status: (
          <span className={"chip " + (p.status === "Reconciled" ? "ok" : p.status === "Needs review" ? "warn" : "")}>
            {p.status}
          </span>
        ),
        received: <span className="lock">{fmtStamp(p.received_at)}</span>,
      },
      sort: {
        warrant: p.warrant_no,
        date: p.warrant_date,
        total: p.total === null ? null : Number(p.total),
        lines: lines.length,
        status: p.status,
        received: p.received_at,
      },
      text: [p.warrant_no, p.warrant_date, p.warrant_documents?.filename, p.status].filter(Boolean).join(" "),
    };
  });

  return (
    <>
      <PageHead
        title="Warrants"
        context="What USOR paid, read from the stubs in the _Warrants folder and reconciled against the authorizations and invoices on file"
        actions={
          <Link href="/billing?tab=invoices#paid-and-outstanding" className="btn ghost" style={{ textDecoration: "none" }}>
            Paid &amp; outstanding
          </Link>
        }
      />

      <div className="grid" style={{ gridTemplateColumns: "repeat(auto-fit, minmax(170px, 1fr))", marginBottom: 18 }}>
        <div className="card">
          <div className="stat">
            {count("Reconciled")}
            <small>lines paid from warrants</small>
          </div>
        </div>
        <div className="card">
          <div className="stat">
            {count("Already recorded")}
            <small>already in the workbook</small>
          </div>
        </div>
        <div className="card">
          <div className="stat" style={count("Needs review") ? { color: "var(--bad)" } : undefined}>
            {count("Needs review")}
            <small>lines to review</small>
          </div>
        </div>
        <div className="card">
          <div className="stat">
            {money(paidOnPages)}
            <small>on the warrants read</small>
          </div>
        </div>
      </div>

      {count("Needs review") > 0 && <WarrantsToReview showAllLink={false} />}

      <h2 className="h2" style={{ margin: "32px 0 8px" }}>
        Received
      </h2>
      <div className="card" style={{ padding: 0 }}>
        <DataTable
          label="warrant pages"
          columns={[
            { key: "warrant", label: "Warrant" },
            { key: "date", label: "Date" },
            { key: "total", label: "Total", align: "right" },
            { key: "lines", label: "Lines" },
            { key: "status", label: "Status" },
            { key: "received", label: "Received" },
          ]}
          rows={received}
          empty={
            <>
              No warrants yet. Put the stubs - one PDF, any number of pages - in a folder named
              <b> _Warrants</b> beside the client folders, and the agent reads them on its next run.
            </>
          }
        />
      </div>
    </>
  );
}
