import { redirect } from "next/navigation";
import Link from "next/link";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { money, fmtStamp, CAN_EDIT_BILLING } from "@/lib/constants";
import { WarrantLineReview, type AuthOption, type ReviewLine } from "./warrant-review";

/**
 * Warrants.
 *
 * What USOR actually paid. The agent reads the stubs in the _Warrants folder;
 * every line the page proves is already a payment, and every line it cannot
 * prove waits here, beside a picture of the page, for a person to record or
 * set aside. The page image is the point: the reason a line stopped is almost
 * always visible on the stub - a digit OCR misread, a smudged total.
 */

type PageRow = {
  id: string;
  page_no: number;
  image_path: string;
  warrant_no: string;
  warrant_date: string | null;
  total: number | null;
  lines_total: number | null;
  status: string;
  problems: string[];
  ocr_confidence: number | null;
  received_at: string;
  warrant_documents: { filename: string; page_count: number } | null;
  warrant_lines: ReviewLine[];
};

export default async function WarrantsPage() {
  const me = await requireStaff();
  if (!CAN_EDIT_BILLING.includes(me.role)) redirect("/dashboard");

  const supabase = await createClient();
  const [{ data: pageData }, { data: authData }] = await Promise.all([
    supabase
      .from("warrant_pages")
      .select(
        "id, page_no, image_path, warrant_no, warrant_date, total, lines_total, status, problems, ocr_confidence, received_at, warrant_documents(filename, page_count), warrant_lines(id, line_no, raw, voucher, invoice_ref, described_ref, client_name, service_date, amount, described_amount, status, problem)",
      )
      .order("received_at", { ascending: false })
      .limit(300),
    supabase.from("authorizations").select("id, number, service_type, clients(name)").order("number"),
  ]);

  const pages = (pageData ?? []) as unknown as PageRow[];
  const auths: AuthOption[] = ((authData ?? []) as unknown as { id: string; number: string; service_type: string; clients: { name: string } | null }[]).map(
    (a) => ({ id: a.id, number: a.number, label: `${a.number} · ${a.clients?.name ?? "?"} · ${a.service_type}` }),
  );

  const review = pages.filter((p) => p.status === "Needs review");
  const allLines = pages.flatMap((p) => p.warrant_lines ?? []);
  const count = (s: string) => allLines.filter((l) => l.status === s).length;
  const paidOnPages = allLines
    .filter((l) => ["Reconciled", "Already recorded", "Resolved by hand"].includes(l.status))
    .reduce((s, l) => s + Number(l.amount ?? 0), 0);

  // Short-lived links to the page images; the storage policy lets only Admin
  // and Billing have them.
  const paths = review.map((p) => p.image_path).filter(Boolean);
  const { data: signed } = paths.length
    ? await supabase.storage.from("warrants").createSignedUrls(paths, 3600)
    : { data: [] as { path: string | null; signedUrl: string }[] };
  const urlFor = new Map((signed ?? []).map((s) => [s.path, s.signedUrl]));

  return (
    <>
      <h1 className="h1">Warrants</h1>
      <p className="sub">
        What USOR paid, read from the stubs in the _Warrants folder and reconciled against the
        authorizations and invoices on file. <Link href="/billing/position">Paid &amp; outstanding</Link>
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

      {review.length > 0 && <h3>To review</h3>}
      {review.map((p) => {
        const waiting = (p.warrant_lines ?? []).filter((l) => l.status === "Needs review").sort((a, b) => a.line_no - b.line_no);
        const url = urlFor.get(p.image_path);
        const adds = p.total !== null && p.lines_total !== null && Number(p.total) === Number(p.lines_total);
        return (
          <div key={p.id} className="card" style={{ marginBottom: 14 }}>
            <div className="row2" style={{ justifyContent: "space-between", alignItems: "baseline" }}>
              <div>
                <b>Warrant {p.warrant_no || "(number not read)"}</b>
                <div className="lock">
                  {p.warrant_date ?? "date not read"} · page {p.page_no}
                  {p.warrant_documents ? ` of ${p.warrant_documents.page_count} in ${p.warrant_documents.filename}` : ""}
                  {p.ocr_confidence !== null ? ` · read at ${Math.round(Number(p.ocr_confidence))}%` : ""}
                </div>
              </div>
              <span className={"chip " + (adds ? "ok" : "warn")}>
                Total {p.total !== null ? money(Number(p.total)) : "not read"} · lines {p.lines_total !== null ? money(Number(p.lines_total)) : "incomplete"}
              </span>
            </div>

            {p.problems?.length > 0 && (
              <p className="lock" style={{ margin: "6px 0 0" }}>
                Reading the page: {p.problems.join("; ")}.
              </p>
            )}

            <div className="grid" style={{ gridTemplateColumns: "minmax(280px, 1fr) minmax(320px, 1.2fr)", gap: 14, marginTop: 10 }}>
              <div>
                {url ? (
                  <a href={url} target="_blank" rel="noopener">
                    {/* eslint-disable-next-line @next/next/no-img-element */}
                    <img src={url} alt={`Warrant ${p.warrant_no} page ${p.page_no}`} style={{ width: "100%", border: "1px solid var(--line)", borderRadius: 6 }} />
                  </a>
                ) : (
                  <p className="lock">No page image was kept.</p>
                )}
              </div>
              <div>
                {waiting.map((l) => (
                  <WarrantLineReview key={l.id} line={l} auths={auths} />
                ))}
              </div>
            </div>
          </div>
        );
      })}

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
