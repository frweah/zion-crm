import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { money } from "@/lib/constants";
import { WarrantLineReview, type AuthOption, type ReviewLine } from "./warrant-review";

type ReviewPage = {
  id: string;
  page_no: number;
  image_path: string;
  warrant_no: string;
  warrant_date: string | null;
  total: number | null;
  lines_total: number | null;
  problems: string[];
  ocr_confidence: number | null;
  warrant_documents: { filename: string; page_count: number } | null;
  warrant_lines: ReviewLine[];
};

/**
 * Warrant lines waiting for a person, beside a picture of the page.
 *
 * One home: shown on Billing → Invoices, where the money it settles is, and at
 * the top of the full warrants list. Every line the page proved is already a
 * payment; these are the ones it could not prove. The reason a line stopped is
 * almost always visible on the stub - a digit OCR misread, a smudged total.
 * The storage policy lets only Admin and Billing sign the image links.
 */
export async function WarrantsToReview({ showAllLink = true }: { showAllLink?: boolean }) {
  const supabase = await createClient();
  const [{ data: pageData }, { data: authData }] = await Promise.all([
    supabase
      .from("warrant_pages")
      .select(
        "id, page_no, image_path, warrant_no, warrant_date, total, lines_total, problems, ocr_confidence, warrant_documents(filename, page_count), warrant_lines(id, line_no, raw, voucher, invoice_ref, described_ref, client_name, service_date, amount, described_amount, status, problem)",
      )
      .eq("status", "Needs review")
      .order("received_at", { ascending: false })
      .limit(100),
    supabase.from("authorizations").select("id, number, service_type, clients(name)").order("number"),
  ]);

  const review = (pageData ?? []) as unknown as ReviewPage[];
  const auths: AuthOption[] = (
    (authData ?? []) as unknown as { id: string; number: string; service_type: string; clients: { name: string } | null }[]
  ).map((a) => ({ id: a.id, number: a.number, label: `${a.number} · ${a.clients?.name ?? "?"} · ${a.service_type}` }));

  const paths = review.map((p) => p.image_path).filter(Boolean);
  const { data: signed } = paths.length
    ? await supabase.storage.from("warrants").createSignedUrls(paths, 3600)
    : { data: [] as { path: string | null; signedUrl: string }[] };
  const urlFor = new Map((signed ?? []).map((s) => [s.path, s.signedUrl]));
  const waitingLines = review.reduce((n, p) => n + (p.warrant_lines ?? []).filter((l) => l.status === "Needs review").length, 0);

  return (
    <>
      <div className="row2" style={{ justifyContent: "space-between", alignItems: "baseline", gap: 12 }}>
        <h2 className="h1" style={{ fontSize: 20, margin: 0 }}>
          Warrant lines needing review
          <span className="lock" style={{ fontWeight: 400 }}> · {waitingLines}</span>
        </h2>
        {showAllLink && <Link href="/billing/warrants">Every warrant received</Link>}
      </div>

      {review.length === 0 && (
        <div className="card" style={{ marginTop: 8 }}>
          <p className="sub" style={{ margin: 0 }}>
            Nothing waiting. Every line read from the warrants so far was proved and recorded, or has
            been dealt with.
          </p>
        </div>
      )}

      {review.map((p) => {
        const waiting = (p.warrant_lines ?? []).filter((l) => l.status === "Needs review").sort((a, b) => a.line_no - b.line_no);
        const url = urlFor.get(p.image_path);
        const adds = p.total !== null && p.lines_total !== null && Number(p.total) === Number(p.lines_total);
        return (
          <div key={p.id} className="card" style={{ margin: "10px 0 14px" }}>
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
                Total {p.total !== null ? money(Number(p.total)) : "not read"} · lines{" "}
                {p.lines_total !== null ? money(Number(p.lines_total)) : "incomplete"}
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
                    <img
                      src={url}
                      alt={`Warrant ${p.warrant_no} page ${p.page_no}`}
                      style={{ width: "100%", border: "1px solid var(--line)", borderRadius: 6 }}
                    />
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
    </>
  );
}
