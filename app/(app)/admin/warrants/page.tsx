import Link from "next/link";
import { requireAdmin } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { money, fmtStamp } from "@/lib/constants";
import { WarrantsToReview } from "./review-section";
import { PageHead } from "../../page-head";
import { DataTable, type DataRow } from "../../data-table";

/**
 * Admin → Warrants: everything a warrant is.
 *
 * What USOR actually paid, read by the agent from the stubs in the _Warrants
 * folder. Moved here whole on 14 November 2026: the owner's ruling is that
 * warrants live in Admin and nowhere else, so this screen is the import, the
 * list, the lines waiting for review, the payments with no stub on file, and
 * the warrants whose dollars do not add up. There is no second warrant screen
 * and no warrant panel anywhere on Billing.
 *
 * `requireAdmin`, not a billing view: the billing area grant is how a CPA and
 * a reports manager are let into the money, and the whole point of the ruling
 * is that it stops carrying warrants with it. The database says the same thing
 * in `warrant_hands()`, which is what actually holds - this redirect only
 * saves somebody a screen of nothing.
 */

type GapRow = {
  warrant_no: string;
  warrant_date: string | null;
  total: number;
  recorded: number;
  gap: number;
  pages: number;
  lines: number;
};

type WaitingRow = {
  payment_id: string;
  client_id: string;
  client_name: string;
  about: string;
  authorization_status: string;
  amount: number;
  warrant_date: string | null;
  source: string;
  recorded_by_name: string;
  days: number | null;
};

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
  await requireAdmin();

  const supabase = await createClient();
  const [{ data: pageData }, { data: waitingData }, { data: gapData }] = await Promise.all([
    supabase
      .from("warrant_pages")
      .select("id, page_no, image_path, warrant_no, warrant_date, total, status, received_at, warrant_documents(filename, page_count), warrant_lines(status, amount)")
      .order("received_at", { ascending: false })
      .limit(300),
    // Money recorded from a remittance whose stub has not arrived (0311).
    // Asked of the rows rather than read off a flag: the import takes a row
    // off this list by writing the warrant number onto the payment, and a
    // flag would need somebody to remember to clear it.
    supabase
      .from("payment_waiting_for_its_warrant")
      .select("payment_id, client_id, client_name, about, authorization_status, amount, warrant_date, source, recorded_by_name, days")
      .order("warrant_date", { ascending: true }),
    /*
     * The warrants whose dollars do not add up.
     *
     * `warrants_not_accounted_for` has existed since 0326 and has never been
     * on a screen: it was called by that migration's own block and by
     * `verify_warrant_lines`, and nowhere else. So the practice could answer
     * "this stub says $2,610 and $2,250 is recorded against it" and nobody
     * could ask it. It is asked here.
     */
    supabase.rpc("warrants_not_accounted_for"),
  ]);

  const waiting = (waitingData ?? []) as WaitingRow[];
  const waitingTotal = waiting.reduce((n, w) => n + Number(w.amount ?? 0), 0);

  const gaps = ((gapData ?? []) as GapRow[]).map((g) => ({ ...g, gap: Number(g.gap) }));

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
                  <a href={`/admin/warrants/image/${p.id}`} target="_blank" rel="noopener" style={{ color: "var(--teal)" }}>
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
        context="What USOR paid, read from the stubs in the _Warrants folder"
        actions={
          <Link href="/insights/money#paid-and-outstanding" className="btn ghost" style={{ textDecoration: "none" }}>
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

      {count("Needs review") > 0 && <WarrantsToReview />}

      <h2 className="h2" style={{ margin: "32px 0 8px" }}>
        Warrant not on file
      </h2>
      <div className="card" style={{ padding: 0 }}>
        <DataTable
          label="payments waiting for a warrant"
          sortBy
          columns={[
            { key: "client", label: "Client" },
            { key: "about", label: "Authorization" },
            { key: "matched", label: "Warrant" },
            { key: "amount", label: "Amount", align: "right" },
            { key: "when", label: "Received" },
            { key: "who", label: "Recorded by" },
            { key: "waiting", label: "Waiting", align: "right" },
          ]}
          rows={waiting.map((w) => ({
            key: w.payment_id,
            cells: {
              client: (
                <Link href={`/clients/${w.client_id}?tab=billing`} style={{ color: "var(--teal)" }}>
                  {w.client_name}
                </Link>
              ),
              about: w.about,
              /*
               * Matched or not, which is the detail the ruling of 15 November
               * 2026 took off Billing's screens and kept here.
               *
               * Every row on this list is unmatched by definition - that is
               * what the list is - so what the cell adds is what the record
               * says about it beside that: an authorization reading Paid with
               * no stub behind it is a different thing to chase from one
               * still reading Submitted.
               */
              matched: (
                <span className={w.authorization_status === "Paid" ? "chip warn" : "chip"}>
                  not matched · {w.authorization_status.toLowerCase()}
                </span>
              ),
              amount: money(Number(w.amount ?? 0)),
              when: w.warrant_date ?? <span className="lock">—</span>,
              who: (
                <span className="lock">
                  {w.recorded_by_name || "—"} · {w.source.toLowerCase()}
                </span>
              ),
              waiting:
                w.days === null ? (
                  <span className="lock">—</span>
                ) : (
                  <span className={w.days >= 30 ? "chip warn" : "chip"}>{w.days} days</span>
                ),
            },
            sort: {
              client: w.client_name,
              about: w.about,
              matched: w.authorization_status,
              amount: Number(w.amount ?? 0),
              when: w.warrant_date,
              who: w.recorded_by_name,
              waiting: w.days ?? -1,
            },
            text: [w.client_name, w.about, w.recorded_by_name].filter(Boolean).join(" "),
          }))}
          empty="Every payment on file names the warrant that paid it."
        />
      </div>
      {waiting.length > 0 && (
        <p className="lock">
          {money(waitingTotal)} received with no stub on file — put the warrant in <b>_Warrants</b> and
          reconciliation matches these rather than paying them twice
        </p>
      )}

      <h2 className="h2" style={{ margin: "32px 0 8px" }}>
        Does not add up
      </h2>
      <div className="card" style={{ padding: 0 }}>
        <DataTable
          label="warrants whose dollars do not add up"
          columns={[
            { key: "warrant", label: "Warrant" },
            { key: "date", label: "Date" },
            { key: "total", label: "On the stub", align: "right" },
            { key: "recorded", label: "Recorded", align: "right" },
            { key: "gap", label: "Difference", align: "right" },
            { key: "lines", label: "Lines" },
          ]}
          rows={gaps.map((g) => ({
            key: g.warrant_no,
            cells: {
              warrant: <b>{g.warrant_no}</b>,
              date: g.warrant_date ?? <span className="lock">—</span>,
              total: money(Number(g.total)),
              recorded: money(Number(g.recorded)),
              gap: <span className="chip warn">{money(g.gap)}</span>,
              lines: (
                <span className="lock">
                  {g.lines} on {g.pages} {g.pages === 1 ? "page" : "pages"}
                </span>
              ),
            },
            sort: {
              warrant: g.warrant_no,
              date: g.warrant_date,
              total: Number(g.total),
              recorded: Number(g.recorded),
              gap: Math.abs(g.gap),
              lines: g.lines,
            },
            text: [g.warrant_no, g.warrant_date].filter(Boolean).join(" "),
          }))}
          empty="Every warrant read accounts for every dollar on it."
        />
      </div>
      {gaps.length > 0 && (
        <p className="lock">Open the page image and add the line the reader missed</p>
      )}

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
