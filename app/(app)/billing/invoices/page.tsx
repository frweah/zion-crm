import Link from "next/link";
import { invoiceNumberLabel } from "@/lib/billing";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { can } from "@/lib/roles";
import { money, today } from "@/lib/constants";
import { PageHead } from "../../page-head";
import { DataTable } from "../../data-table";
import { RecordQuery } from "./query-form";

/**
 * Invoices (Phase 3, owner 6 November 2026).
 *
 * One row per invoice sent to USOR: what was billed, when, to which office,
 * and what came back. Until this screen the only record of an invoice was an
 * email and a PDF, and Phase 2 found what that costs - an invoice sent on 6
 * October for an authorization the CRM did not have, another sitting as
 * Authorized ten days after it went out, and a Money figure $810 short
 * because two invoices were valued from a rate rather than from what was
 * actually sent.
 *
 * Nothing on this screen raises an invoice. Sending the packet does that, in
 * the database, and check-nav holds the screens to it - there is one door to a
 * bill and this is not a second one. What a person does here is read, filter
 * and export.
 */
export const dynamic = "force-dynamic";

const STATUSES = ["Submitted", "Short-paid", "Paid", "Rejected"] as const;

/**
 * Sent and not paid, which is the question this screen is opened to answer
 * (owner, 9 November 2026).
 *
 * It is not a status - the statuses are what came back - and it is not "all
 * minus Paid" either, because a rejected invoice is not money owed, it is an
 * invoice to raise again. Submitted and Short-paid are the two that mean
 * somebody at USOR still owes this practice something.
 */
const OUTSTANDING = "Outstanding";
const OUTSTANDING_STATUSES = ["Submitted", "Short-paid"];

/** Which month, as the segmented control offers it. */
function monthStart(when: string | undefined): string | null {
  if (!when || when === "all") return null;
  return /^\d{4}-\d{2}$/.test(when) ? `${when}-01` : null;
}

export default async function InvoicesPage({
  searchParams,
}: {
  searchParams: Promise<{
    status?: string;
    client?: string;
    office?: string;
    period?: string;
    invoice?: string;
  }>;
}) {
  const me = await requireStaff();
  if (!can(me, "billing")) {
    // The money is Billing's and Admin's. A grant answers this too.
    return (
      <>
        <PageHead title="Invoices" context="What has been sent to USOR, and what has come back" />
        <div className="alert">Invoices are Billing&apos;s and Admin&apos;s.</div>
      </>
    );
  }

  const { status, client, office, period, invoice } = await searchParams;
  const from = monthStart(period);

  const supabase = await createClient();
  let query = supabase
    .from("invoices")
    .select(
      "id, number, client_id, auth_id, claim, submitted_on, amount, status, paid_on, amount_paid, warrant, voucher, office_id, sent_to, source, note",
    )
    .order("submitted_on", { ascending: false, nullsFirst: false })
    .order("number", { ascending: false })
    .limit(2000);

  if (status === OUTSTANDING) query = query.in("status", OUTSTANDING_STATUSES);
  else if (status && (STATUSES as readonly string[]).includes(status)) query = query.eq("status", status);
  if (client) query = query.eq("client_id", client);
  if (office) query = query.eq("office_id", office);
  if (from) {
    const next = new Date(`${from}T00:00:00Z`);
    next.setUTCMonth(next.getUTCMonth() + 1);
    query = query.gte("submitted_on", from).lt("submitted_on", next.toISOString().slice(0, 10));
  }

  const [{ data: rows }, { data: clients }, { data: offices }, { data: auths }, { data: months },
    { data: settledRows }, { data: openedRow }, { data: lineRows }, { data: queryRows }] =
    await Promise.all([
      query,
      supabase.from("clients").select("id, name").order("name"),
      supabase.from("billing_offices").select("id, name").order("name"),
      supabase.from("authorizations").select("id, number, service_type"),
      // Every invoice's month and office, unfiltered: the chips offer what
      // there is rather than every office on file, and they have to be the
      // same whichever chip is on - a filter that disappears once you use it
      // is a filter you cannot undo.
      supabase.from("invoices").select("submitted_on, office_id"),
      // Which of them somebody has queried and settled, so the list says so
      // beside the status rather than only inside the record (0312).
      supabase.from("invoice_queries").select("invoice_id").eq("resolved", true),
      // The one invoice somebody opened, which is where a chase task lands.
      // Asked for by id rather than looked for among the filtered rows: a
      // link from My day carries no filters, but the screen may already have
      // some from the last time somebody used it, and a link that does not
      // open the invoice it names is worse than no link.
      invoice
        ? supabase
            .from("invoices")
            .select(
              "id, number, client_id, auth_id, claim, submitted_on, amount, status, paid_on, amount_paid, warrant, voucher, office_id, sent_to, source, note",
            )
            .eq("id", invoice)
            .maybeSingle()
        : Promise.resolve({ data: null }),
      invoice
        ? supabase
            .from("invoice_lines")
            .select("id, on_date, description, hours, rate, amount")
            .eq("invoice_id", invoice)
            .order("on_date", { ascending: true, nullsFirst: false })
        : Promise.resolve({ data: [] }),
      invoice
        ? supabase
            .from("invoice_queries")
            .select("id, asked_on, asked_of, said, resolved, recorded_by_name, at")
            .eq("invoice_id", invoice)
            .order("asked_on", { ascending: false })
            .order("at", { ascending: false })
        : Promise.resolve({ data: [] }),
    ]);

  const invoices = rows ?? [];
  const clientName = new Map((clients ?? []).map((c) => [c.id, c.name]));
  const officeName = new Map((offices ?? []).map((o) => [o.id, o.name]));
  const authOf = new Map((auths ?? []).map((a) => [a.id, a]));
  const settled = new Set(((settledRows ?? []) as { invoice_id: string }[]).map((q) => q.invoice_id));

  // The months there is anything to show, newest first. Offered rather than
  // typed: a period filter that lets somebody ask for a month with nothing in
  // it is a filter that answers "no invoices" and tells them nothing.
  const periods = [...new Set((months ?? []).map((m) => (m.submitted_on ?? "").slice(0, 7)))]
    .filter(Boolean)
    .sort()
    .reverse()
    .slice(0, 13);
  const officesWithInvoices = new Set(
    ((months ?? []) as { office_id: string | null }[]).map((m) => m.office_id).filter(Boolean) as string[],
  );
  const officeChips = (offices ?? []).filter(
    (o) => officesWithInvoices.has(o.id) || office === o.id,
  );

  const total = invoices.reduce((n, i) => n + Number(i.amount ?? 0), 0);
  const received = invoices.reduce((n, i) => n + Number(i.amount_paid ?? 0), 0);
  const owed = invoices
    .filter((i) => i.status === "Submitted" || i.status === "Short-paid")
    .reduce((n, i) => n + (Number(i.amount ?? 0) - Number(i.amount_paid ?? 0)), 0);

  const opened = openedRow ?? null;
  const lines = (lineRows ?? []) as {
    id: string;
    on_date: string | null;
    description: string;
    hours: number | null;
    rate: number | null;
    amount: number | null;
  }[];
  const queries = (queryRows ?? []) as {
    id: string;
    asked_on: string;
    asked_of: string;
    said: string;
    resolved: boolean;
    recorded_by_name: string;
  }[];
  const openedClient = opened?.client_id ? (clientName.get(opened.client_id) ?? "—") : "—";
  const openedAuth = opened?.auth_id ? authOf.get(opened.auth_id) : undefined;
  const openedShort = opened
    ? Math.max(Number(opened.amount ?? 0) - Number(opened.amount_paid ?? 0), 0)
    : 0;
  const lineHours = lines.reduce((n, l) => n + Number(l.hours ?? 0), 0);
  const lineAmount = lines.reduce((n, l) => n + Number(l.amount ?? 0), 0);
  const canRecord = can(me, "billing", "edit");

  const here = (next: Record<string, string | undefined>) => {
    const p = new URLSearchParams();
    const all = { status, client, office, period, invoice, ...next };
    for (const [k, v] of Object.entries(all)) if (v) p.set(k, v);
    const tail = p.toString();
    return tail ? `/billing/invoices?${tail}` : "/billing/invoices";
  };

  return (
    <>
      <PageHead
        title="Invoices"
        context="What has been sent to USOR, and what has come back"
        actions={
          <a className="btn ghost" href="/api/export/invoices">
            Export
          </a>
        }
      />

      {opened && (
        <section className="page-section" style={{ marginBottom: 18 }}>
          <div className="record-actions" style={{ marginBottom: 8 }}>
            <h2 className="h2" style={{ margin: 0, flex: 1 }}>
              Invoice {invoiceNumberLabel(opened)}
            </h2>
            <Link href={here({ invoice: undefined })} className="btn ghost" style={{ textDecoration: "none" }}>
              Done
            </Link>
          </div>

          <p className="lock" style={{ marginTop: 0 }}>
            {openedClient}
            {openedAuth ? ` · ${openedAuth.number || openedAuth.service_type}` : ""}
            {opened.claim ? ` · claim ${opened.claim}` : ""}
            {opened.submitted_on ? ` · sent ${opened.submitted_on}` : " · no date on file"}
            {opened.office_id ? ` · ${officeName.get(opened.office_id) ?? ""}` : ""}
            {opened.sent_to ? ` · ${opened.sent_to}` : ""} · {money(Number(opened.amount ?? 0))}
            {opened.amount_paid ? ` · ${money(Number(opened.amount_paid))} received` : ""}
            {openedShort > 0 ? ` · ${money(openedShort)} short` : ""}
          </p>

          <h3 className="h3">Services billed</h3>
          <div className="card" style={{ padding: 0 }}>
            <DataTable
              label="invoice lines"
              columns={[
                { key: "day", label: "Day" },
                { key: "what", label: "What" },
                { key: "hours", label: "Hours", align: "right" },
                { key: "rate", label: "Rate", align: "right" },
                { key: "amount", label: "Amount", align: "right" },
              ]}
              rows={lines.map((l) => ({
                key: l.id,
                cells: {
                  day: l.on_date ?? <span className="lock">—</span>,
                  what: l.description,
                  hours: l.hours === null ? <span className="lock">—</span> : Number(l.hours).toFixed(2),
                  rate: l.rate === null ? <span className="lock">—</span> : money(Number(l.rate)),
                  amount:
                    l.amount === null ? (
                      <span className="lock">in the fee</span>
                    ) : (
                      money(Number(l.amount))
                    ),
                },
                text: [l.on_date, l.description].filter(Boolean).join(" "),
              }))}
              empty="No services on this record — it was backfilled from the warrant that paid it."
            />
          </div>
          {lineHours > 0 && (
            <p className="lock">
              {lineHours.toFixed(2)} hours
              {lineAmount > 0 ? ` · ${money(lineAmount)} on the lines` : " · a flat fee, so the days are what the form reports"}
            </p>
          )}

          <h3 className="h3" style={{ marginTop: 18 }}>
            Queries
          </h3>
          <div className="card" style={{ padding: 0 }}>
            <DataTable
              label="queries"
              columns={[
                { key: "asked", label: "Asked" },
                { key: "who", label: "Who was asked" },
                { key: "said", label: "What they said" },
                { key: "settled", label: "Settled" },
                { key: "by", label: "Recorded by" },
              ]}
              rows={queries.map((q) => ({
                key: q.id,
                cells: {
                  asked: q.asked_on,
                  who: q.asked_of,
                  said: q.said || <span className="lock">nothing yet</span>,
                  settled: q.resolved ? <span className="chip ok">Settled</span> : <span className="lock">no</span>,
                  by: <span className="lock">{q.recorded_by_name || "—"}</span>,
                },
                text: [q.asked_of, q.said].filter(Boolean).join(" "),
              }))}
              empty="Nothing asked yet — record the call below once somebody has rung the office."
            />
          </div>
          {canRecord ? (
            <RecordQuery invoiceId={opened.id} today={today()} />
          ) : (
            <p className="lock">Admin and Billing record what came of a query.</p>
          )}
        </section>
      )}

      <div className="segmented" role="group" aria-label="Status" style={{ marginBottom: 10 }}>
        <Link href={here({ status: undefined })} className={!status ? "on" : undefined}>
          All
        </Link>
        <Link
          href={here({ status: OUTSTANDING })}
          className={status === OUTSTANDING ? "on" : undefined}
        >
          Outstanding
        </Link>
        {STATUSES.map((s) => (
          <Link key={s} href={here({ status: s })} className={status === s ? "on" : undefined}>
            {s}
          </Link>
        ))}
      </div>

      <div className="segmented" role="group" aria-label="Office" style={{ marginBottom: 10 }}>
        <Link href={here({ office: undefined })} className={!office ? "on" : undefined}>
          Every office
        </Link>
        {officeChips.map((o) => (
          <Link key={o.id} href={here({ office: o.id })} className={office === o.id ? "on" : undefined}>
            {o.name}
          </Link>
        ))}
      </div>

      {periods.length > 1 && (
        <div className="segmented" role="group" aria-label="Period" style={{ marginBottom: 14 }}>
          <Link href={here({ period: undefined })} className={!period ? "on" : undefined}>
            Any month
          </Link>
          {periods.map((p) => (
            <Link key={p} href={here({ period: p })} className={period === p ? "on" : undefined}>
              {new Date(`${p}-01T00:00:00Z`).toLocaleDateString("en-GB", {
                month: "short",
                year: "numeric",
                timeZone: "UTC",
              })}
            </Link>
          ))}
        </div>
      )}

      <p className="sub" style={{ marginBottom: 10 }}>
        {invoices.length} {invoices.length === 1 ? "invoice" : "invoices"} · {money(total)} invoiced ·{" "}
        {money(received)} received · {money(owed)} owed
      </p>

      <div className="card" style={{ padding: 0 }}>
        <DataTable
          label="invoices"
          sortBy
          pageSize={50}
          columns={[
            { key: "number", label: "Invoice" },
            { key: "client", label: "Client" },
            { key: "auth", label: "Authorization" },
            { key: "sent", label: "Sent" },
            { key: "waiting", label: "Waiting", align: "right" },
            { key: "office", label: "Office" },
            { key: "amount", label: "Amount", align: "right" },
            { key: "status", label: "Status" },
            { key: "paid", label: "Paid", align: "right" },
            { key: "warrant", label: "Warrant" },
          ]}
          rows={invoices.map((i) => {
            const a = i.auth_id ? authOf.get(i.auth_id) : undefined;
            const name = i.client_id ? (clientName.get(i.client_id) ?? "—") : "—";
            const short =
              i.status === "Short-paid" ? Number(i.amount ?? 0) - Number(i.amount_paid ?? 0) : 0;
            // Days outstanding: how long the money has been owed, which is
            // what a chase is sorted by (owner, 9 November 2026). A
            // short-paid invoice is still waiting for the rest of it.
            const days =
              (i.status === "Submitted" || i.status === "Short-paid") && i.submitted_on
                ? Math.floor((Date.now() - new Date(`${i.submitted_on}T00:00:00Z`).getTime()) / 86400000)
                : null;
            return {
              key: i.id,
              text: [i.number, name, a?.number, a?.service_type, i.warrant, i.voucher, i.status]
                .filter(Boolean)
                .join(" "),
              sort: {
                number: i.number ?? 0,
                waiting: days ?? -1,
                client: name,
                auth: a?.number ?? "",
                sent: i.submitted_on,
                office: i.office_id ? (officeName.get(i.office_id) ?? "") : "",
                amount: Number(i.amount ?? 0),
                status: i.status,
                paid: Number(i.amount_paid ?? 0),
                warrant: i.warrant,
              },
              cells: {
                number: (
                  <>
                    <Link href={here({ invoice: i.id })} style={{ color: "var(--teal)", fontWeight: 600 }}>
                      {invoiceNumberLabel(i)}
                    </Link>
                    {i.source === "Backfill" && (
                      <span className="chip" style={{ marginLeft: 6 }}>
                        from the warrants
                      </span>
                    )}
                  </>
                ),
                client: i.client_id ? (
                  <Link href={`/clients/${i.client_id}`} style={{ color: "var(--teal)" }}>
                    {name}
                  </Link>
                ) : (
                  "—"
                ),
                auth: a ? (
                  <Link href={`/billing/authorizations/${a.id}`} style={{ color: "var(--teal)" }}>
                    {a.number || a.service_type}
                    {i.claim && <span className="lock"> claim {i.claim}</span>}
                  </Link>
                ) : (
                  <span className="lock">None</span>
                ),
                sent: i.submitted_on ? (
                  <span style={{ whiteSpace: "nowrap" }}>{i.submitted_on}</span>
                ) : (
                  <span className="lock">Not on file</span>
                ),
                // How long the money has been owed, in its own column so the
                // list can be sorted by it. It was a chip on the sent date
                // that appeared at thirty days, which could be read but not
                // sorted - and sorting is the whole job when there are
                // several to chase.
                waiting:
                  days === null ? (
                    <span className="lock">—</span>
                  ) : (
                    <span className={days >= 30 ? "chip warn" : undefined} style={{ whiteSpace: "nowrap" }}>
                      {days} {days === 1 ? "day" : "days"}
                    </span>
                  ),
                office: i.office_id ? (officeName.get(i.office_id) ?? "—") : <span className="lock">—</span>,
                amount: money(Number(i.amount ?? 0)),
                status: (
                  <>
                    <span className={"chip " + (i.status === "Short-paid" || i.status === "Rejected" ? "bad" : "")}>
                      {i.status}
                    </span>
                    {settled.has(i.id) && (
                      <span className="chip ok" style={{ marginLeft: 6 }}>
                        queried
                      </span>
                    )}
                  </>
                ),
                paid: i.amount_paid ? (
                  <>
                    {money(Number(i.amount_paid))}
                    {short > 0 && <div className="lock">{money(short)} short</div>}
                  </>
                ) : (
                  <span className="lock">—</span>
                ),
                warrant: i.warrant ? (
                  <span style={{ whiteSpace: "nowrap" }}>
                    {i.warrant}
                    {i.paid_on && <div className="lock">{i.paid_on}</div>}
                  </span>
                ) : (
                  <span className="lock">—</span>
                ),
              },
            };
          })}
          empty="No invoices match that."
        />
      </div>
    </>
  );
}
