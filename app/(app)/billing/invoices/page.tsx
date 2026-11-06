import Link from "next/link";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { can } from "@/lib/roles";
import { money } from "@/lib/constants";
import { PageHead } from "../../page-head";
import { DataTable } from "../../data-table";

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

/** Which month, as the segmented control offers it. */
function monthStart(when: string | undefined): string | null {
  if (!when || when === "all") return null;
  return /^\d{4}-\d{2}$/.test(when) ? `${when}-01` : null;
}

export default async function InvoicesPage({
  searchParams,
}: {
  searchParams: Promise<{ status?: string; client?: string; office?: string; period?: string }>;
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

  const { status, client, office, period } = await searchParams;
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

  if (status && (STATUSES as readonly string[]).includes(status)) query = query.eq("status", status);
  if (client) query = query.eq("client_id", client);
  if (office) query = query.eq("office_id", office);
  if (from) {
    const next = new Date(`${from}T00:00:00Z`);
    next.setUTCMonth(next.getUTCMonth() + 1);
    query = query.gte("submitted_on", from).lt("submitted_on", next.toISOString().slice(0, 10));
  }

  const [{ data: rows }, { data: clients }, { data: offices }, { data: auths }, { data: months }] =
    await Promise.all([
      query,
      supabase.from("clients").select("id, name").order("name"),
      supabase.from("billing_offices").select("id, name").order("name"),
      supabase.from("authorizations").select("id, number, service_type"),
      supabase.from("invoices").select("submitted_on").not("submitted_on", "is", null),
    ]);

  const invoices = rows ?? [];
  const clientName = new Map((clients ?? []).map((c) => [c.id, c.name]));
  const officeName = new Map((offices ?? []).map((o) => [o.id, o.name]));
  const authOf = new Map((auths ?? []).map((a) => [a.id, a]));

  // The months there is anything to show, newest first. Offered rather than
  // typed: a period filter that lets somebody ask for a month with nothing in
  // it is a filter that answers "no invoices" and tells them nothing.
  const periods = [...new Set((months ?? []).map((m) => (m.submitted_on ?? "").slice(0, 7)))]
    .filter(Boolean)
    .sort()
    .reverse()
    .slice(0, 13);

  const total = invoices.reduce((n, i) => n + Number(i.amount ?? 0), 0);
  const received = invoices.reduce((n, i) => n + Number(i.amount_paid ?? 0), 0);
  const owed = invoices
    .filter((i) => i.status === "Submitted" || i.status === "Short-paid")
    .reduce((n, i) => n + (Number(i.amount ?? 0) - Number(i.amount_paid ?? 0)), 0);

  const here = (next: Record<string, string | undefined>) => {
    const p = new URLSearchParams();
    const all = { status, client, office, period, ...next };
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

      <div className="segmented" role="group" aria-label="Status" style={{ marginBottom: 10 }}>
        <Link href={here({ status: undefined })} className={!status ? "on" : undefined}>
          All
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
        {(offices ?? []).map((o) => (
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
            const days =
              i.status === "Submitted" && i.submitted_on
                ? Math.floor((Date.now() - new Date(`${i.submitted_on}T00:00:00Z`).getTime()) / 86400000)
                : null;
            return {
              key: i.id,
              text: [i.number, name, a?.number, a?.service_type, i.warrant, i.voucher, i.status]
                .filter(Boolean)
                .join(" "),
              sort: {
                number: i.number,
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
                    <b>{i.number}</b>
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
                  <span style={{ whiteSpace: "nowrap" }}>
                    {i.submitted_on}
                    {days !== null && days >= 30 && (
                      <span className="chip warn" style={{ marginLeft: 6 }}>
                        {days} days
                      </span>
                    )}
                  </span>
                ) : (
                  <span className="lock">Not on file</span>
                ),
                office: i.office_id ? (officeName.get(i.office_id) ?? "—") : <span className="lock">—</span>,
                amount: money(Number(i.amount ?? 0)),
                status: (
                  <span className={"chip " + (i.status === "Short-paid" || i.status === "Rejected" ? "bad" : "")}>
                    {i.status}
                  </span>
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
