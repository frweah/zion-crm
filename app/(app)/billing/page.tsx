import Link from "next/link";
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
  CompletionRow,
  NewInvoiceForm,
  InvoiceAction,
  type AuthOption,
} from "./billing-forms";

const TABS = [
  { key: "authorizations", label: "Authorizations" },
  { key: "log", label: "Service log" },
  { key: "completions", label: "Completion services" },
  { key: "invoices", label: "Invoices" },
  { key: "rates", label: "Rate schedule" },
];

export default async function BillingPage({
  searchParams,
}: {
  searchParams: Promise<{ tab?: string; show?: string; filter?: string }>;
}) {
  const me = await requireStaff();
  const { tab: rawTab, show, filter } = await searchParams;
  const tab = TABS.some((t) => t.key === rawTab) ? rawTab! : "authorizations";

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

  const header = (
    <>
      <h1 className="h1">Billing</h1>
      <p className="sub">Authorizations, service log, invoices, and receivables</p>
      <nav className="tabs">
        {TABS.map((t) => (
          <Link key={t.key} href={`/billing?tab=${t.key}`} className={t.key === tab ? "on" : ""}>
            {t.label}
          </Link>
        ))}
      </nav>
    </>
  );

  // ── Rate schedule ─────────────────────────────────────────
  if (tab === "rates") {
    const { data: rates } = await supabase
      .from("rate_schedule")
      .select("service, sub, fee, unit, funding_source")
      .order("service");

    return (
      <>
        {header}
        <p className="sub">
          The CRP rate schedule from the Voc Rehab Workbook. New authorizations are pre-filled
          from it, and it is keyed by funding source so a second funder can be added without
          code changes.
        </p>
        <div className="card" style={{ padding: 0 }}>
          <table className="t">
            <thead>
              <tr>
                <th>Service</th>
                <th>Subcategory</th>
                <th>Approved fee</th>
                <th>Unit</th>
                <th>Funder</th>
              </tr>
            </thead>
            <tbody>
              {(rates ?? []).map((r, i) => (
                <tr key={i}>
                  <td>{r.service}</td>
                  <td>{r.sub}</td>
                  <td>{money(r.fee)}</td>
                  <td>{r.unit}</td>
                  <td>{r.funding_source}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </>
    );
  }

  // ── Service log ───────────────────────────────────────────
  if (tab === "log") {
    const staffResult = await supabase.from("staff").select("id, name");
    const staffName = new Map((staffResult.data ?? []).map((s) => [s.id, s.name]));
    const authById = new Map(auths.map((a) => [a.id, a]));
    const hourly = auths.filter((a) => a.rate_type === "Hourly" && a.status === "Open");

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
          <table className="t">
            <thead>
              <tr>
                <th>Date</th>
                <th>Authorization</th>
                <th>Client</th>
                <th>Hours</th>
                <th>Staff</th>
                <th>Notes</th>
              </tr>
            </thead>
            <tbody>
              {entries.length === 0 && (
                <tr>
                  <td colSpan={6} className="empty">
                    No service entries yet. The workbook carried authorizations and payments, but
                    no hour-by-hour log — this fills up as staff record their time.
                  </td>
                </tr>
              )}
              {[...entries]
                .sort((a, b) => b.date.localeCompare(a.date))
                .map((e) => {
                  const a = authById.get(e.auth_id);
                  return (
                    <tr key={e.id}>
                      <td>{e.date}</td>
                      <td>{a?.number}</td>
                      <td>{a ? (clientName.get(a.client_id) ?? "—") : "—"}</td>
                      <td>
                        {e.hours}
                        {e.non_billable && (
                          <span className="chip" style={{ marginLeft: 6 }}>
                            non-billable
                          </span>
                        )}
                      </td>
                      <td>{e.staff_id ? (staffName.get(e.staff_id) ?? "—").split(" ")[0] : "—"}</td>
                      <td>
                        {e.primary_code && (
                          <span className="chip" style={{ marginRight: 4 }}>
                            #{e.primary_code}
                            {e.secondary_code ? `/${e.secondary_code}` : ""}
                          </span>
                        )}
                        {e.notes}
                      </td>
                    </tr>
                  );
                })}
            </tbody>
          </table>
        </div>
      </>
    );
  }

  // ── Completion services ───────────────────────────────────
  if (tab === "completions") {
    const { data: completions } = await supabase
      .from("completions")
      .select("id, auth_id, start_date, completion, billed, notes");

    const authById = new Map(auths.map((a) => [a.id, a]));

    return (
      <>
        {header}
        <div className="card" style={{ padding: 0 }}>
          <table className="t">
            <thead>
              <tr>
                <th>Authorization</th>
                <th>Client</th>
                <th>Service</th>
                <th colSpan={2}>Start / completed</th>
                <th>Amount</th>
                <th>Billed</th>
              </tr>
            </thead>
            <tbody>
              {(completions ?? []).length === 0 && (
                <tr>
                  <td colSpan={7} className="empty">
                    No completion-based services.
                  </td>
                </tr>
              )}
              {(completions ?? []).map((c) => {
                const a = authById.get(c.auth_id);
                return (
                  <CompletionRow
                    key={c.id}
                    completion={{
                      id: c.id,
                      auth_number: a?.number ?? "—",
                      client_name: a ? (clientName.get(a.client_id) ?? "—") : "—",
                      service_type: a?.service_type ?? "—",
                      start_date: c.start_date,
                      completion: c.completion,
                      billed: c.billed,
                      rate: Number(a?.rate ?? 0),
                    }}
                  />
                );
              })}
            </tbody>
          </table>
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
    const authById = new Map(auths.map((a) => [a.id, a]));

    const view = filter === "paid" ? "paid" : filter === "all" ? "all" : "open";
    const shown = invoices.filter((i) =>
      view === "all" ? true : view === "paid" ? i.status === "Paid" : i.status !== "Paid",
    );
    const paidCount = invoices.filter((i) => i.status === "Paid");
    const paidTotal = paidCount.reduce((t, i) => t + i.amount, 0);

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

        <div className="row2" style={{ marginBottom: 8 }}>
          {[
            { key: "open", label: "Open" },
            { key: "paid", label: `Paid (${paidCount.length} · ${money(paidTotal)})` },
            { key: "all", label: "All" },
          ].map((f) => (
            <Link
              key={f.key}
              href={`/billing?tab=invoices&filter=${f.key}`}
              className={"btn " + (view === f.key ? "" : "ghost")}
              style={{ textDecoration: "none" }}
            >
              {f.label}
            </Link>
          ))}
        </div>

        <div className="card" style={{ padding: 0 }}>
          <table className="t">
            <thead>
              <tr>
                <th>Invoice</th>
                <th>Service</th>
                <th>Client</th>
                <th>Date</th>
                <th>Amount</th>
                <th>Status</th>
                <th>Days</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {shown.length === 0 && (
                <tr>
                  <td colSpan={8} className="empty">
                    {view === "open"
                      ? "Nothing outstanding. Complete a service or log hours, then raise an invoice."
                      : "None."}
                  </td>
                </tr>
              )}
              {shown.map((i) => {
                const a = authById.get(i.auth_id);
                const days = i.status === "Sent" ? daysBetween(i.date, today()) : null;
                return (
                  <tr key={i.id}>
                    <td>
                      <b>{i.number}</b>
                      {i.warrant && (
                        <div style={{ fontSize: 11, color: "var(--muted)" }}>{i.warrant}</div>
                      )}
                    </td>
                    <td>{i.service_type || a?.service_type}</td>
                    <td>
                      {a ? (
                        <Link href={`/clients/${a.client_id}`} style={{ color: "var(--teal)" }}>
                          {clientName.get(a.client_id) ?? "—"}
                        </Link>
                      ) : (
                        "—"
                      )}
                    </td>
                    <td>{i.date}</td>
                    <td>{money(i.amount)}</td>
                    <td>
                      <span
                        className={
                          "chip " + (i.status === "Paid" ? "ok" : i.status === "Sent" ? "warn" : "")
                        }
                      >
                        {i.status}
                      </span>
                    </td>
                    <td>
                      {days !== null ? (
                        <span className={"chip " + (days >= 90 ? "bad" : days >= 30 ? "warn" : "")}>
                          {days}
                        </span>
                      ) : (
                        "—"
                      )}
                    </td>
                    <td>{canBill && <InvoiceAction invoiceId={i.id} status={i.status} />}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>

        <p className="lock" style={{ marginTop: 10 }}>
          An invoice cannot be marked Sent until every USOR form required for its service type is
          completed. Those forms arrive with the Phase 4 form engine — until then, that gate will
          refuse new sends.
        </p>
      </>
    );
  }

  // ── Authorizations ────────────────────────────────────────
  const showAll = show === "all";
  const closedCount = auths.filter((a) => a.status !== "Open").length;
  const shownAuths = auths.filter((a) => showAll || a.status === "Open");

  return (
    <>
      {header}

      <div className="row2" style={{ marginBottom: 8 }}>
        <Link
          href={`/billing?tab=authorizations${showAll ? "" : "&show=all"}`}
          style={{ fontSize: 12, color: "var(--teal)" }}
        >
          {showAll ? "Show open only" : `Show paid and closed (${closedCount})`}
        </Link>
      </div>

      <div className="card" style={{ padding: 0, marginBottom: 14 }}>
        <table className="t">
          <thead>
            <tr>
              <th>Auth #</th>
              <th>Client</th>
              <th>Service</th>
              <th>Rate</th>
              <th>Hours used / total</th>
              <th>Dates</th>
              <th>Status</th>
            </tr>
          </thead>
          <tbody>
            {shownAuths.length === 0 && (
              <tr>
                <td colSpan={7} className="empty">
                  No authorizations.
                </td>
              </tr>
            )}
            {shownAuths.map((a) => {
              const total = a.total_hours == null ? null : Number(a.total_hours);
              const used = usedByAuth.get(a.id) ?? 0;
              const rem = total === null ? null : total - used;
              return (
                <tr key={a.id}>
                  <td>
                    <b>{a.number || "—"}</b>
                  </td>
                  <td>
                    <Link href={`/clients/${a.client_id}`} style={{ color: "var(--teal)" }}>
                      {clientName.get(a.client_id) ?? "—"}
                    </Link>
                  </td>
                  <td>{a.service_type}</td>
                  <td>
                    {money(a.rate)}
                    {a.rate_type === "Hourly" ? "/hr" : " flat"}
                  </td>
                  <td>
                    {total !== null && rem !== null ? (
                      <>
                        {used} / {total}{" "}
                        <span
                          className={
                            "chip " + (rem <= 0 ? "bad" : rem <= total * 0.1 ? "warn" : "ok")
                          }
                        >
                          {rem <= 0 ? "Exhausted" : rem <= total * 0.1 ? "Low" : "OK"}
                        </span>
                      </>
                    ) : (
                      <span className="chip">completion-based</span>
                    )}
                  </td>
                  <td style={{ whiteSpace: "nowrap" }}>
                    {a.start_date || a.end_date ? (
                      `${a.start_date ?? "—"} → ${a.end_date ?? "—"}`
                    ) : (
                      <span className="lock">{a.note || "—"}</span>
                    )}
                  </td>
                  <td>
                    <span className={"chip " + (a.status === "Paid" ? "ok" : "")}>{a.status}</span>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>

      {canBill && <AddAuthorizationForm clients={clients.filter((c) => c.status === "Active")} />}
    </>
  );
}
