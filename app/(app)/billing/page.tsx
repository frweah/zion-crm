import Link from "next/link";
import { redirect } from "next/navigation";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import {
  money,
  today,
  daysBetween,
  arBuckets,
  CAN_EDIT_BILLING,
  CAN_LOG_HOURS,
} from "@/lib/constants";
import {
  AddAuthorizationForm,
  ServiceEntryForm,
  CompletionDates,
  NewInvoiceForm,
  InvoiceAction,
  type AuthOption,
} from "./billing-forms";
import { readPayments } from "@/lib/payments";
import { WarrantsToReview } from "./warrants/review-section";
import PositionSection from "./position/section";
import { PageHead } from "../page-head";
import { DataTable, type DataRow } from "../data-table";

/**
 * The tabs are the Billing group in the sidebar, drawn once in the layout.
 * This list is only what the page needs to know to pick a view — the labels
 * and the order live with the navigation, so the two cannot disagree.
 */
const TABS = ["authorizations", "log", "invoices"];

export default async function BillingPage({
  searchParams,
}: {
  searchParams: Promise<{ tab?: string; show?: string; filter?: string }>;
}) {
  const me = await requireStaff();
  const { tab: rawTab, show, filter } = await searchParams;

  // Completions and the rate schedule were tabs. Completions sit under
  // Authorizations now; the rate schedule is a setting, in Admin → System.
  if (rawTab === "rates") redirect("/admin/system#rates");
  if (rawTab === "completions") redirect("/billing?tab=authorizations#completions");
  const tab = TABS.includes(rawTab ?? "") ? rawTab! : "authorizations";

  const supabase = await createClient();
  const canBill = CAN_EDIT_BILLING.includes(me.role);
  const canLog = CAN_LOG_HOURS.includes(me.role);

  const [authsResult, clientsResult, entriesResult] = await Promise.all([
    supabase
      .from("authorizations")
      .select(
        "id, client_id, number, service_type, total_hours, carried_used, rate_type, rate, start_date, end_date, status, requires_forms, note",
      )
      .order("number"),
    supabase.from("clients").select("id, name, status").order("name"),
    supabase.from("service_entries").select("id, auth_id, date, hours, non_billable, notes, primary_code, secondary_code, staff_id"),
  ]);

  const auths = authsResult.data ?? [];
  const clients = clientsResult.data ?? [];
  const entries = entriesResult.data ?? [];
  const clientName = new Map(clients.map((c) => [c.id, c.name]));

  // Hours used = carried over at migration, plus everything billable logged.
  const usedByAuth = new Map<string, number>();
  for (const a of auths) usedByAuth.set(a.id, Number(a.carried_used ?? 0));
  for (const e of entries) {
    if (e.non_billable) continue;
    usedByAuth.set(e.auth_id, (usedByAuth.get(e.auth_id) ?? 0) + Number(e.hours));
  }

  const authLabel = (a: (typeof auths)[number]) =>
    `${a.number || "(no number)"} · ${clientName.get(a.client_id) ?? "—"} · ${a.service_type}`;

  const toOption = (a: (typeof auths)[number]): AuthOption => ({
    id: a.id,
    label: authLabel(a),
    serviceType: a.service_type,
    rateType: a.rate_type,
    rate: Number(a.rate),
    totalHours: a.total_hours == null ? null : Number(a.total_hours),
    used: usedByAuth.get(a.id) ?? 0,
  });

  // One header on every Billing tab. Reading an authorization off the PDF is
  // the one thing Billing starts from, so it sits on the right wherever you are.
  const header = (
    <PageHead
      title="Billing"
      context="Authorizations, service log, invoices, and receivables"
      actions={
        canBill ? (
          <Link href="/billing/import" className="btn" style={{ textDecoration: "none" }}>
            Read an authorization
          </Link>
        ) : undefined
      }
    />
  );

  // ── Service log ───────────────────────────────────────────
  if (tab === "log") {
    const staffResult = await supabase.from("staff").select("id, name");
    const staffName = new Map((staffResult.data ?? []).map((s) => [s.id, s.name]));
    const authById = new Map(auths.map((a) => [a.id, a]));
    const hourly = auths.filter((a) => a.rate_type === "Hourly" && a.status === "Open");

    const logRows: DataRow[] = [...entries]
      .sort((a, b) => b.date.localeCompare(a.date))
      .map((e) => {
        const a = authById.get(e.auth_id);
        const client = a ? (clientName.get(a.client_id) ?? "—") : "—";
        const staff = e.staff_id ? (staffName.get(e.staff_id) ?? "—").split(" ")[0] : "—";
        return {
          key: e.id,
          cells: {
            date: e.date,
            auth: a?.number || "—",
            client,
            hours: (
              <>
                {e.hours}
                {e.non_billable && (
                  <span className="chip" style={{ marginLeft: 6 }}>
                    non-billable
                  </span>
                )}
              </>
            ),
            staff,
            notes: (
              <>
                {e.primary_code && (
                  <span className="chip" style={{ marginRight: 4 }}>
                    #{e.primary_code}
                    {e.secondary_code ? `/${e.secondary_code}` : ""}
                  </span>
                )}
                {e.notes}
              </>
            ),
          },
          sort: { hours: Number(e.hours), notes: e.notes ?? "" },
          text: [e.date, a?.number, client, staff, e.notes, e.primary_code, e.non_billable ? "non-billable" : ""]
            .filter(Boolean)
            .join(" "),
        };
      });

    return (
      <>
        {header}
        <div className="alert">
          Log hours on the date the service actually happened. Entries that would exceed an
          authorization&apos;s remaining hours are refused — request additional hours from the
          counselor instead.
        </div>

        {canLog && <ServiceEntryForm auths={hourly.map(toOption)} />}

        <div className="card" style={{ padding: 0 }}>
          <DataTable
            label="service entries"
            columns={[
              { key: "date", label: "Date" },
              { key: "auth", label: "Authorization" },
              { key: "client", label: "Client" },
              { key: "hours", label: "Hours", align: "right" },
              { key: "staff", label: "Staff" },
              { key: "notes", label: "Notes" },
            ]}
            rows={logRows}
            empty="No service entries yet. The workbook carried authorizations and payments, but no hour-by-hour log — this fills up as staff record their time."
          />
        </div>
      </>
    );
  }

  // ── Invoices ──────────────────────────────────────────────
  if (tab === "invoices") {
    const { data: invoiceRows } = await supabase
      .from("invoices")
      .select("id, auth_id, number, date, amount, status, warrant, service_type, paid_date")
      .order("date", { ascending: false });

    const invoices = (invoiceRows ?? []).map((i) => ({ ...i, amount: Number(i.amount) }));
    const ar = arBuckets(invoices);

    // The warrant page each paid invoice was read from, when one was kept.
    const pageByInvoice = new Map<string, string>();
    for (const p of await readPayments(supabase)) {
      if (p.invoice_id && p.page_id && !pageByInvoice.has(p.invoice_id)) pageByInvoice.set(p.invoice_id, p.page_id);
    }
    const authById = new Map(auths.map((a) => [a.id, a]));

    const view = filter === "paid" ? "paid" : filter === "all" ? "all" : "open";
    const shown = invoices.filter((i) =>
      view === "all" ? true : view === "paid" ? i.status === "Paid" : i.status !== "Paid",
    );
    const paidCount = invoices.filter((i) => i.status === "Paid");
    const paidTotal = paidCount.reduce((t, i) => t + i.amount, 0);

    const rows: DataRow[] = shown.map((i) => {
      const a = authById.get(i.auth_id);
      const days = i.status === "Sent" ? daysBetween(i.date, today()) : null;
      const client = a ? (clientName.get(a.client_id) ?? "—") : "—";
      const service = i.service_type || a?.service_type || "—";
      return {
        key: i.id,
        cells: {
          invoice: (
            <>
              <b>{i.number}</b>
              {i.warrant && (
                <div style={{ fontSize: 11, color: "var(--muted)" }}>
                  {pageByInvoice.has(i.id) ? (
                    <a
                      href={`/billing/warrants/image/${pageByInvoice.get(i.id)}`}
                      target="_blank"
                      rel="noopener"
                      style={{ color: "var(--teal)" }}
                    >
                      {i.warrant} · page image
                    </a>
                  ) : (
                    i.warrant
                  )}
                </div>
              )}
            </>
          ),
          service,
          client: a ? (
            <Link href={`/clients/${a.client_id}`} style={{ color: "var(--teal)" }}>
              {client}
            </Link>
          ) : (
            "—"
          ),
          date: i.date,
          amount: money(i.amount),
          status: (
            <>
              <span className={"chip " + (i.status === "Paid" ? "ok" : i.status === "Sent" ? "warn" : "")}>
                {i.status}
              </span>
              {i.status === "Paid" && i.paid_date && <div className="lock">paid {i.paid_date}</div>}
            </>
          ),
          days:
            days !== null ? (
              <span className={"chip " + (days >= 90 ? "bad" : days >= 30 ? "warn" : "")}>{days}</span>
            ) : (
              "—"
            ),
          action: canBill ? <InvoiceAction invoiceId={i.id} status={i.status} /> : null,
        },
        sort: { invoice: i.number, client, amount: i.amount, status: i.status, days },
        text: [i.number, i.warrant, service, client, i.date, i.status].filter(Boolean).join(" "),
      };
    });

    return (
      <>
        {header}

        <div
          className="grid"
          style={{ gridTemplateColumns: "repeat(auto-fit, minmax(150px, 1fr))", marginBottom: 14 }}
        >
          {(["0-30", "31-60", "61-90", "90+"] as const).map((k) => (
            <div key={k} className="card">
              <div className="stat" style={{ fontSize: 18 }}>
                {money(ar[k])}
                <small>{k} days</small>
              </div>
            </div>
          ))}
          <div className="card" style={{ borderColor: "var(--lime)" }}>
            <div className="stat" style={{ fontSize: 18 }}>
              {money(ar.total)}
              <small>total outstanding</small>
            </div>
          </div>
        </div>

        {canBill && <NewInvoiceForm auths={auths.map(toOption)} />}

        {/* Which invoices to show is a filter on this list, not a tab. */}
        <div style={{ marginBottom: 8 }}>
          <div className="segmented">
            {[
              { key: "open", label: "Open" },
              { key: "paid", label: `Paid (${paidCount.length} · ${money(paidTotal)})` },
              { key: "all", label: "All" },
            ].map((f) => (
              <Link
                key={f.key}
                href={`/billing?tab=invoices&filter=${f.key}`}
                className={view === f.key ? "on" : undefined}
              >
                {f.label}
              </Link>
            ))}
          </div>
        </div>

        <div className="card" style={{ padding: 0 }}>
          <DataTable
            label="invoices"
            columns={[
              { key: "invoice", label: "Invoice" },
              { key: "service", label: "Service" },
              { key: "client", label: "Client" },
              { key: "date", label: "Date" },
              { key: "amount", label: "Amount", align: "right" },
              { key: "status", label: "Status" },
              { key: "days", label: "Days", align: "right" },
              { key: "action", label: "", sortable: false },
            ]}
            rows={rows}
            empty={
              view === "open"
                ? "Nothing outstanding. Complete a service or log hours, then raise an invoice."
                : view === "paid"
                  ? "No invoice has been paid yet."
                  : "No invoices have been raised yet."
            }
          />
        </div>

        <p className="lock" style={{ marginTop: 10 }}>
          An invoice cannot be marked Sent until every USOR form required for its service type is
          completed. Those forms arrive with the Phase 4 form engine — until then, that gate will
          refuse new sends.
        </p>

        <section id="warrant-review" style={{ marginTop: 32 }}>
          <WarrantsToReview />
        </section>

        {/* Paid & outstanding lives here, beside the invoices it counts (owner, 14 Sept 2026). */}
        <section id="paid-and-outstanding" style={{ marginTop: 32 }}>
          <PositionSection searchParams={Promise.resolve({ show })} />
        </section>
      </>
    );
  }

  // ── Authorizations ────────────────────────────────────────
  const showAll = show === "all";
  const closedCount = auths.filter((a) => a.status !== "Open").length;
  const shownAuths = auths.filter((a) => showAll || a.status === "Open");

  const [{ data: completions }, { count: waitingInInbox }] = await Promise.all([
    supabase.from("completions").select("id, auth_id, start_date, completion, billed, notes"),
    supabase.from("inbox_pending").select("id", { count: "exact", head: true }).eq("kind", "Authorization"),
  ]);
  const authById = new Map(auths.map((a) => [a.id, a]));

  const authRows: DataRow[] = shownAuths.map((a) => {
    const total = a.total_hours == null ? null : Number(a.total_hours);
    const used = usedByAuth.get(a.id) ?? 0;
    const rem = total === null ? null : total - used;
    const client = clientName.get(a.client_id) ?? "—";
    return {
      key: a.id,
      cells: {
        number: <b>{a.number || "—"}</b>,
        client: (
          <Link href={`/clients/${a.client_id}`} style={{ color: "var(--teal)" }}>
            {client}
          </Link>
        ),
        service: a.service_type,
        rate: `${money(a.rate)}${a.rate_type === "Hourly" ? "/hr" : " flat"}`,
        hours:
          total !== null && rem !== null ? (
            <>
              {used} / {total}{" "}
              <span className={"chip " + (rem <= 0 ? "bad" : rem <= total * 0.1 ? "warn" : "ok")}>
                {rem <= 0 ? "Exhausted" : rem <= total * 0.1 ? "Low" : "OK"}
              </span>
            </>
          ) : (
            <span className="chip">completion-based</span>
          ),
        dates: (
          <span style={{ whiteSpace: "nowrap" }}>
            {a.start_date || a.end_date ? (
              `${a.start_date ?? "—"} → ${a.end_date ?? "—"}`
            ) : (
              <span className="lock">{a.note || "—"}</span>
            )}
          </span>
        ),
        status: <span className={"chip " + (a.status === "Paid" ? "ok" : "")}>{a.status}</span>,
      },
      sort: {
        number: a.number,
        client,
        rate: Number(a.rate),
        // The share used, so an exhausted authorization sorts beside the other exhausted ones.
        hours: total ? used / total : null,
        dates: a.start_date ?? a.end_date,
        status: a.status,
      },
      text: [a.number, client, a.service_type, a.status, a.start_date, a.end_date, a.note].filter(Boolean).join(" "),
    };
  });

  const completionRows: DataRow[] = (completions ?? []).map((c) => {
    const a = authById.get(c.auth_id);
    const client = a ? (clientName.get(a.client_id) ?? "—") : "—";
    const billed = c.billed ? "Yes" : c.completion ? "ready to invoice" : "needs completion date";
    return {
      key: c.id,
      cells: {
        auth: <b>{a?.number ?? "—"}</b>,
        client,
        service: a?.service_type ?? "—",
        dates: <CompletionDates completionId={c.id} startDate={c.start_date} completion={c.completion} />,
        amount: money(Number(a?.rate ?? 0)),
        billed: c.billed ? (
          <span className="chip ok">Yes</span>
        ) : c.completion ? (
          <span className="chip warn">ready to invoice</span>
        ) : (
          <span className="lock">needs completion date</span>
        ),
      },
      sort: {
        auth: a?.number ?? "",
        dates: c.completion ?? c.start_date,
        amount: Number(a?.rate ?? 0),
        billed,
      },
      text: [a?.number, client, a?.service_type, billed].filter(Boolean).join(" "),
    };
  });

  return (
    <>
      {header}

      {(waitingInInbox ?? 0) > 0 && (
        <div className="alert" style={{ marginBottom: 12 }}>
          <Link href="/admin/documents#inbox" style={{ color: "inherit" }}>
            <b>
              {waitingInInbox} authorization{waitingInInbox === 1 ? "" : "s"} from documents awaiting
              confirmation
            </b>{" "}
            — confirm them in the document inbox.
          </Link>
        </div>
      )}

      {/* Open or everything is a filter on this list, not a tab. */}
      <div style={{ marginBottom: 8 }}>
        <div className="segmented">
          <Link href="/billing?tab=authorizations" className={showAll ? undefined : "on"}>
            Open
          </Link>
          <Link href="/billing?tab=authorizations&show=all" className={showAll ? "on" : undefined}>
            All, with paid and closed ({closedCount})
          </Link>
        </div>
      </div>

      <div className="card" style={{ padding: 0, marginBottom: 14 }}>
        <DataTable
          label="authorizations"
          columns={[
            { key: "number", label: "Auth #" },
            { key: "client", label: "Client" },
            { key: "service", label: "Service" },
            { key: "rate", label: "Rate", align: "right" },
            { key: "hours", label: "Hours used / total" },
            { key: "dates", label: "Dates" },
            { key: "status", label: "Status" },
          ]}
          rows={authRows}
          empty={showAll ? "No authorizations are on file." : "No authorization is open."}
        />
      </div>

      {canBill && (
        <p className="lock" style={{ margin: "0 0 14px" }}>
          Have the PDF USOR sent? <Link href="/billing/import">Read the authorization off it</Link>{" "}
          instead of typing it — a rate keyed as 4.50 instead of 45.00 is not noticed until an
          invoice is short.
        </p>
      )}

      <section id="completions" style={{ margin: "24px 0 14px" }}>
        <h2 className="h2" style={{ marginBottom: 8 }}>
          Flat-fee completions
        </h2>
        <div className="card" style={{ padding: 0 }}>
          <DataTable
            label="completions"
            columns={[
              { key: "auth", label: "Authorization" },
              { key: "client", label: "Client" },
              { key: "service", label: "Service" },
              { key: "dates", label: "Start / completed" },
              { key: "amount", label: "Amount", align: "right" },
              { key: "billed", label: "Billed" },
            ]}
            rows={completionRows}
            empty="No completion-based services."
          />
        </div>
      </section>

      {canBill && <AddAuthorizationForm clients={clients.filter((c) => c.status === "Active")} />}
    </>
  );
}
