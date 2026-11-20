import { createClient } from "@/lib/supabase/server";
import { money } from "@/lib/constants";
import { WarrantLineReview, type AuthOption, type QueueLine } from "./warrant-review";

type PageHeader = {
  id: string;
  page_no: number;
  total: number | null;
  lines_total: number | null;
  ocr_confidence: number | null;
  warrant_documents: { filename: string; page_count: number } | null;
};

/**
 * Warrant lines still a question, beside a picture of the page.
 *
 * One home: Admin → Warrants, which is the only screen warrants appear on
 * since the owner moved them there on 14 November 2026.
 *
 * The queue is `warrant_review_queue` (0376) and not the lines table: one row
 * per line on the stub however many times the stub was scanned, and only the
 * lines no payment on file accounts for. The reason a line stopped is almost
 * always visible on the stub - a digit OCR misread, a smudged total. The
 * storage policy lets only Admin sign the image links.
 */
export async function loadWarrantsToReview() {
  const supabase = await createClient();
  const [{ data: queueData }, { data: authData }] = await Promise.all([
    supabase.rpc("warrant_review_queue"),
    supabase.from("authorizations").select("id, number, service_type, clients(name)").order("number"),
  ]);

  const rows = (queueData ?? []) as unknown as (QueueLine & {
    page_id: string;
    image_path: string;
    warrant_no: string;
    warrant_date: string | null;
    line_ids: string[];
    settled: boolean;
  })[];
  const queue = rows.filter((r) => !r.settled);
  const settled = rows.filter((r) => r.settled);

  const auths: AuthOption[] = (
    (authData ?? []) as unknown as { id: string; number: string; service_type: string; clients: { name: string } | null }[]
  ).map((a) => ({ id: a.id, number: a.number, label: `${a.number} · ${a.clients?.name ?? "?"} · ${a.service_type}` }));

  // The pages the questions are asked against, and nothing else: a page whose
  // every line the record accounts for has nothing to look at.
  const pageIds = [...new Set(queue.map((r) => r.page_id))];
  const { data: pageData } = pageIds.length
    ? await supabase
        .from("warrant_pages")
        .select("id, page_no, total, lines_total, ocr_confidence, warrant_documents(filename, page_count)")
        .in("id", pageIds)
    : { data: [] };
  const header = new Map(((pageData ?? []) as unknown as PageHeader[]).map((p) => [p.id, p]));

  const paths = [...new Set(queue.map((r) => r.image_path).filter(Boolean))];
  const { data: signed } = paths.length
    ? await supabase.storage.from("warrants").createSignedUrls(paths, 3600)
    : { data: [] as { path: string | null; signedUrl: string }[] };
  const urlFor = new Map((signed ?? []).map((s) => [s.path, s.signedUrl]));

  // Every reading of a line still in the queue, so the list of pages can say
  // which pages hold a question and which only hold readings of one answered
  // elsewhere.
  const openLines = new Set(queue.flatMap((r) => r.line_ids));

  return { queue, settled, auths, urlFor, header, openLines };
}

export async function WarrantsToReview({
  data,
}: {
  /** Already started by the page; otherwise the section loads for itself. */
  data?: ReturnType<typeof loadWarrantsToReview>;
}) {
  const { queue, settled, auths, urlFor, header } = await (data ?? loadWarrantsToReview());

  // One item per page, because the page image is what a person reads the
  // answer off. The lines on it are the stub's lines, not the page's rows.
  const byPage = new Map<string, typeof queue>();
  for (const row of queue) {
    const got = byPage.get(row.page_id);
    if (got) got.push(row);
    else byPage.set(row.page_id, [row]);
  }

  return (
    <>
      <div className="row2" style={{ justifyContent: "space-between", alignItems: "baseline", gap: 12 }}>
        <h2 className="h2" style={{ margin: 0 }}>
          Warrant lines needing review
          <span className="lock" style={{ fontWeight: 400 }}> · {queue.length}</span>
        </h2>
      </div>

      {settled.length > 0 && (
        <p className="lock" style={{ margin: "6px 0 0" }}>
          {settled.length} more match a payment already on record, so they are not asked about
        </p>
      )}

      {queue.length === 0 && (
        <p className="empty" style={{ margin: "8px 0 0" }}>
          Nothing waiting — every line read from the warrants is money the record accounts for.
        </p>
      )}

      {/*
        One list, a page to an item. These are records that each carry their own
        forms and a picture, not summaries, so they are not a stack of cards.
      */}
      {queue.length > 0 && (
        <div className="list" style={{ margin: "10px 0 14px" }}>
          {[...byPage.entries()].map(([pageId, lines]) => {
            const p = header.get(pageId);
            const first = lines[0];
            const url = urlFor.get(first.image_path);
            const adds =
              p && p.total !== null && p.lines_total !== null && Number(p.total) === Number(p.lines_total);
            return (
              <div key={pageId} className="list-item">
                <div className="row2" style={{ justifyContent: "space-between", alignItems: "baseline" }}>
                  <div>
                    <b>Warrant {first.warrant_no || "(number not read)"}</b>
                    <div className="lock">
                      {first.warrant_date ?? "date not read"}
                      {p ? ` · page ${p.page_no}` : ""}
                      {p?.warrant_documents
                        ? ` of ${p.warrant_documents.page_count} in ${p.warrant_documents.filename}`
                        : ""}
                      {p?.ocr_confidence !== null && p?.ocr_confidence !== undefined
                        ? ` · read at ${Math.round(Number(p.ocr_confidence))}%`
                        : ""}
                    </div>
                  </div>
                  {p && (
                    <span className={"chip " + (adds ? "ok" : "warn")}>
                      Total {p.total !== null ? money(Number(p.total)) : "not read"} · lines{" "}
                      {p.lines_total !== null ? money(Number(p.lines_total)) : "incomplete"}
                    </span>
                  )}
                </div>

                <div
                  className="grid"
                  style={{ gridTemplateColumns: "minmax(280px, 1fr) minmax(320px, 1.2fr)", gap: 14, marginTop: 10 }}
                >
                  <div>
                    {url ? (
                      <a href={url} target="_blank" rel="noopener">
                        {/* eslint-disable-next-line @next/next/no-img-element */}
                        <img
                          src={url}
                          alt={`Warrant ${first.warrant_no} page ${p?.page_no ?? ""}`}
                          style={{ width: "100%", border: "1px solid var(--line)", borderRadius: 6 }}
                        />
                      </a>
                    ) : (
                      <p className="lock">No page image was kept.</p>
                    )}
                  </div>
                  <div>
                    {[...lines]
                      .sort((a, b) => a.line_no - b.line_no)
                      .map((l) => (
                        <WarrantLineReview key={l.key} line={l} auths={auths} />
                      ))}
                  </div>
                </div>
              </div>
            );
          })}
        </div>
      )}
    </>
  );
}
