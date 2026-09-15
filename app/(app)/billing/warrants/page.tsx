import { redirect } from "next/navigation";
import Link from "next/link";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { money, fmtStamp, CAN_EDIT_BILLING } from "@/lib/constants";
import { WarrantsToReview } from "./review-section";

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
  if (!CAN_EDIT_BILLING.includes(me.role)) redirect("/dashboard");

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

  return (
    <>
      <h1 className="h1">Warrants</h1>
      <p className="sub">
        What USOR paid, read from the stubs in the _Warrants folder and reconciled against the
        authorizations and invoices on file.{" "}
        <Link href="/billing?tab=invoices#paid-and-outstanding">Paid &amp; outstanding</Link>
      </p>

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

      {pages.length === 0 && (
        <div className="card">
          <p className="sub" style={{ margin: 0 }}>
            No warrants yet. Put the stubs - one PDF, any number of pages - in a folder named
            <b> _Warrants</b> beside the client folders, and the agent reads them on its next run.
          </p>
        </div>
      )}

      {count("Needs review") > 0 && <WarrantsToReview showAllLink={false} />}

      {pages.length > 0 && (
        <>
          <h3 style={{ marginTop: 22 }}>Received</h3>
          <div className="card" style={{ padding: 0, overflowX: "auto" }}>
            <table className="t">
              <thead>
                <tr>
                  <th>Warrant</th>
                  <th>Date</th>
                  <th style={{ textAlign: "right" }}>Total</th>
                  <th>Lines</th>
                  <th>Status</th>
                  <th>Received</th>
                </tr>
              </thead>
              <tbody>
                {pages.map((p) => {
                  const lines = p.warrant_lines ?? [];
                  return (
                    <tr key={p.id}>
                      <td>
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
                      </td>
                      <td>{p.warrant_date ?? "—"}</td>
                      <td style={{ textAlign: "right" }}>{p.total !== null ? money(Number(p.total)) : "—"}</td>
                      <td className="lock">
                        {lines.length} · {lines.filter((l) => l.status === "Reconciled").length} paid ·{" "}
                        {lines.filter((l) => l.status === "Already recorded").length} recorded ·{" "}
                        {lines.filter((l) => l.status === "Resolved by hand").length} by hand ·{" "}
                        {lines.filter((l) => l.status === "Dismissed").length} set aside
                      </td>
                      <td>
                        <span className={"chip " + (p.status === "Reconciled" ? "ok" : p.status === "Needs review" ? "warn" : "")}>{p.status}</span>
                      </td>
                      <td className="lock">{fmtStamp(p.received_at)}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </>
      )}
    </>
  );
}
