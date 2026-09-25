import { can } from "@/lib/roles";
import Link from "next/link";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { money, today, daysBetween } from "@/lib/constants";
import { PageHead } from "../../page-head";
import { DataTable, type DataRow } from "../../data-table";
import { Kpi as Stat, lastTwelveMonths } from "../kpi";
import { FollowupForm } from "./followup-form";

/**
 * Revenue.
 *
 * The billing screens answer "what did we invoice". This one answers the
 * question that decides whether a month is going to be all right: what have we
 * been authorized to earn, how much of it have we actually done, and how much
 * of what we have done have we not asked for yet.
 *
 * Every figure comes from authorization_economics, which knows that hourly
 * work earns by the hour and flat-fee work earns on completion. A screen that
 * treated them the same would read confidently and be wrong on two thirds of
 * the caseload.
 */

const RISK_QUIET_DAYS = 60;
const RISK_ENDING_DAYS = 30;
const NEARLY_SPENT = 0.9;

type Econ = {
  auth_id: string;
  client_id: string;
  auth_number: string | null;
  service_type: string | null;
  funding_source: string | null;
  status: string | null;
  rate_type: string | null;
  rate: number | null;
  total_hours: number | null;
  start_date: string | null;
  end_date: string | null;
  hours_used: number | null;
  hours_left: number | null;
  last_entry_on: string | null;
  entry_count: number | null;
  completed_on: string | null;
  authorized: number | null;
  earned: number | null;
  invoiced: number | null;
  received: number | null;
  outstanding: number | null;
  last_invoice_on: string | null;
  unbilled: number | null;
  committed: number | null;
};

export default async function RevenuePage() {
  const me = await requireStaff();
  const supabase = await createClient();
  const canBill = can(me, "billing", "edit");

  const [econResult, clientsResult, invoicesResult, paperworkResult, followupResult, staffResult] = await Promise.all([
    supabase
      .from("authorization_economics")
      .select("*")
      .order("committed", { ascending: false, nullsFirst: false }),
    supabase.from("clients").select("id, name, counselor_id, status"),
    supabase.from("invoices").select("date, amount, status, paid_date, service_type"),
    supabase.from("client_paperwork").select("client_id, auth_id, usor").eq("state", "Missing"),
    supabase
      .from("authorizations")
      .select("id, followup_owner, followup_action, followup_due, followup_set_at")
      .eq("status", "Open"),
    supabase.from("staff").select("id, name").eq("active", true).eq("is_system", false).order("name"),
  ]);
  const followup = new Map((followupResult.data ?? []).map((f) => [f.id, f]));
  const staff = staffResult.data ?? [];
  const staffName = new Map(staff.map((s) => [s.id, s.name]));

  const econ = (econResult.data ?? []) as unknown as Econ[];
  const clients = clientsResult.data ?? [];
  const clientName = new Map(clients.map((c) => [c.id, c.name]));
  const invoices = (invoicesResult.data ?? []).map((i) => ({ ...i, amount: Number(i.amount) }));
  const blocked = new Set((paperworkResult.data ?? []).map((p) => p.auth_id).filter(Boolean));

  const n = (v: number | null | undefined) => Number(v ?? 0);
  const open = econ.filter((e) => e.status === "Open");

  const committed = open.reduce((s, e) => s + n(e.committed), 0);
  const unbilled = open.reduce((s, e) => s + n(e.unbilled), 0);
  const outstanding = econ.reduce((s, e) => s + n(e.outstanding), 0);
  const receivedAll = econ.reduce((s, e) => s + n(e.received), 0);

  // ── not yet invoiced: who is moving each one (punch list #5) ──
  // Authorized and not invoiced - the work still to do as well as the work
  // done and not asked for - each with the person who owns getting it
  // invoiced and what they do next. Nothing here invoices anything.
  const notInvoiced = open
    .map((e) => ({ e, left: Math.max(0, n(e.authorized) - n(e.invoiced)), f: followup.get(e.auth_id) }))
    .filter((r) => r.left > 0)
    .sort((a, b) => b.left - a.left);
  const notInvoicedTotal = notInvoiced.reduce((s, r) => s + r.left, 0);
  const unowned = notInvoiced.filter((r) => !r.f?.followup_owner || !r.f?.followup_action);

  // ── the months ────────────────────────────────────────────
  const months = lastTwelveMonths(today().slice(0, 7));
  const byMonth = months.map((m) => ({
    month: m,
    received: invoices
      .filter((i) => i.status === "Paid" && (i.paid_date ?? "").startsWith(m))
      .reduce((s, i) => s + i.amount, 0),
    invoiced: invoices
      .filter((i) => i.status !== "Void" && i.date.startsWith(m))
      .reduce((s, i) => s + i.amount, 0),
  }));
  const peak = Math.max(1, ...byMonth.map((b) => Math.max(b.received, b.invoiced)));
  const received12 = byMonth.reduce((s, b) => s + b.received, 0);
  const earning = byMonth.filter((b) => b.received > 0);
  const monthlyAverage = earning.length ? received12 / earning.length : 0;

  // ── at risk ───────────────────────────────────────────────
  const now = today();
  const risks = open
    .map((e) => {
      const reasons: string[] = [];

      const quietSince = e.last_entry_on ?? e.start_date;
      if (n(e.entry_count) === 0 && n(e.invoiced) === 0) {
        const age = e.start_date ? daysBetween(e.start_date, now) : null;
        if (age !== null && age >= RISK_QUIET_DAYS) {
          reasons.push(`nothing logged against it in ${age} days`);
        }
      } else if (quietSince && daysBetween(quietSince, now) >= RISK_QUIET_DAYS) {
        reasons.push(`no hours since ${quietSince}`);
      }

      if (e.end_date) {
        const left = daysBetween(now, e.end_date);
        if (left >= 0 && left <= RISK_ENDING_DAYS && n(e.committed) > 0) {
          reasons.push(`ends in ${left} days with ${money(n(e.committed))} unearned`);
        } else if (left < 0 && n(e.committed) > 0) {
          reasons.push(`ended ${-left} days ago with ${money(n(e.committed))} unearned`);
        }
      }

      if (
        e.total_hours != null &&
        n(e.total_hours) > 0 &&
        n(e.hours_used) / n(e.total_hours) >= NEARLY_SPENT
      ) {
        reasons.push(`${n(e.hours_left)} of ${n(e.total_hours)} hours left — ask before overrunning`);
      }

      if (n(e.unbilled) > 0 && blocked.has(e.auth_id)) {
        reasons.push("a USOR form it needs is unfinished, so it cannot be invoiced");
      }

      return { e, reasons };
    })
    .filter((r) => r.reasons.length > 0)
    .sort((a, b) => n(b.e.committed) - n(a.e.committed));

  // ── where the money comes from ────────────────────────────
  const services = new Map<string, { received: number; committed: number }>();
  for (const e of econ) {
    const key = e.service_type || "—";
    const row = services.get(key) ?? { received: 0, committed: 0 };
    row.received += n(e.received);
    row.committed += n(e.committed);
    services.set(key, row);
  }
  const byService = [...services.entries()]
    .map(([service, v]) => ({ service, ...v }))
    .sort((a, b) => b.received + b.committed - (a.received + a.committed));

  // ── what the figures cannot yet mean ──────────────────────
  const loggedHours = econ.reduce((s, e) => s + n(e.entry_count), 0);
  const undated = open.filter((e) => !e.start_date).length;
  const caveats: string[] = [];
  if (loggedHours === 0) {
    caveats.push(
      "No service hours have been logged in the CRM yet, so hourly work shows as earned only for the hours carried over at migration. Earned and unbilled become real figures on the day people start logging.",
    );
  }
  if (open.some((e) => e.rate_type === "Flat Fee" && n(e.rate) === 0)) {
    caveats.push(
      "An open flat-fee authorization has a rate of $0, so it counts as nothing authorized. Put the fee on it in Billing and this page will pick it up.",
    );
  }
  if (undated > 0) {
    caveats.push(
      `${undated} of ${open.length} open authorizations have no start date. Nothing can be said about how long they have been sitting there, so "worth watching" will miss them until the date is filled in.`,
    );
  }
  if (open.filter((e) => e.end_date).length < open.length) {
    caveats.push(
      `${open.length - open.filter((e) => e.end_date).length} of ${open.length} open authorizations have no end date, so nothing here can warn you that they are about to expire. The date is on the authorization in Billing.`,
    );
  }

  const riskRows: DataRow[] = risks.map(({ e, reasons }) => {
    const client = clientName.get(e.client_id) ?? "—";
    return {
      key: e.auth_id,
      cells: {
        client: (
          <>
            <Link href={`/clients/${e.client_id}`} style={{ color: "var(--teal)" }}>
              <b>{client}</b>
            </Link>
            <div className="lock">
              {e.auth_number || "(no number)"} · {e.service_type}
            </div>
            <div style={{ fontSize: "var(--text-sm)", color: "var(--bad)" }}>{reasons.join(" · ")}</div>
          </>
        ),
        unearned: <b>{money(n(e.committed))}</b>,
      },
      sort: { client, unearned: n(e.committed) },
      text: [client, e.auth_number, e.service_type, ...reasons].filter(Boolean).join(" "),
    };
  });

  const openRows: DataRow[] = open.map((e) => {
    const client = clientName.get(e.client_id) ?? "—";
    return {
      key: e.auth_id,
      cells: {
        client: (
          <>
            <Link href={`/clients/${e.client_id}`} style={{ color: "var(--teal)" }}>
              {client}
            </Link>
            <div className="lock">{e.auth_number || "(no number)"}</div>
          </>
        ),
        service: (
          <>
            {e.service_type}
            <div className="lock">
              {e.rate_type === "Hourly" ? `${money(n(e.rate))} an hour` : "flat fee, earned on completion"}
            </div>
          </>
        ),
        authorized: money(n(e.authorized)),
        earned: (
          <>
            {money(n(e.earned))}
            {n(e.unbilled) > 0 && (
              <div className="lock" style={{ color: "var(--bad)" }}>
                {money(n(e.unbilled))} not invoiced
              </div>
            )}
          </>
        ),
        toEarn: <b>{money(n(e.committed))}</b>,
        hours: (
          <span style={{ whiteSpace: "nowrap" }}>
            {e.total_hours == null ? (
              <span className="lock">{e.completed_on ? `completed ${e.completed_on}` : "not started"}</span>
            ) : (
              <>
                {n(e.hours_used)} / {n(e.total_hours)}
                <div className="lock">{n(e.hours_left)} left</div>
              </>
            )}
          </span>
        ),
      },
      sort: {
        client,
        service: e.service_type,
        authorized: n(e.authorized),
        earned: n(e.earned),
        toEarn: n(e.committed),
        hours: e.total_hours == null ? null : n(e.hours_left),
      },
      text: [client, e.auth_number, e.service_type, e.rate_type].filter(Boolean).join(" "),
    };
  });

  return (
    <>
      <PageHead
        title="Money"
        context="What USOR has authorized, what we have earned against it, and what has been paid — live from the record"
      />

      <div
        className="grid"
        style={{ gridTemplateColumns: "repeat(auto-fit, minmax(210px, 1fr))", margin: "14px 0 8px" }}
      >
        <Stat
          value={money(committed)}
          label="authorized, not yet earned"
          detail={`${open.length} open authorizations. This is the work still to do, and the money still to make.`}
        />
        <Stat
          value={money(unbilled)}
          label="earned, not yet invoiced"
          tone={unbilled > 0 ? "bad" : undefined}
          detail={
            unbilled > 0
              ? "Work already done that nobody has asked for yet. The section below counts a wider thing: everything authorized and not invoiced, earned or not."
              : "Everything earned has been invoiced."
          }
        />
        <Stat
          value={money(outstanding)}
          label="invoiced, not yet paid"
          tone={outstanding > 0 ? "bad" : undefined}
          detail={
            outstanding > 0 ? (
              "Sent to USOR and outstanding."
            ) : (
              "Nothing is sitting with USOR unpaid."
            ) as string
          }
        />
        <Stat
          value={money(received12)}
          label="received in the last 12 months"
          tone="good"
          series={byMonth.map((b) => ({ month: b.month, value: b.received }))}
          describe={(v) => money(v)}
          detail={
            monthlyAverage > 0
              ? `${money(monthlyAverage)} in an average earning month. ${money(receivedAll)} received in total.`
              : `${money(receivedAll)} received in total.`
          }
        />
      </div>

      {caveats.length > 0 && (
        <div className="alert" style={{ marginBottom: 18 }}>
          <b>Read these figures with the record in mind.</b>
          <ul style={{ margin: "8px 0 0", paddingLeft: 20 }}>
            {caveats.map((c) => (
              <li key={c} style={{ marginBottom: 4 }}>
                {c}
              </li>
            ))}
          </ul>
        </div>
      )}

      <section id="not-invoiced" style={{ marginBottom: 24 }}>
        <h2 className="h2">Authorized and not yet invoiced — who is moving it</h2>
        <p className="sub" style={{ marginBottom: 12 }}>
          {money(notInvoicedTotal)} authorized and not invoiced across {notInvoiced.length} open authorization
          {notInvoiced.length === 1 ? "" : "s"}.{" "}
          {unowned.length === 0
            ? "Every one has an owner and a next action."
            : `${unowned.length} ${unowned.length === 1 ? "has" : "have"} no owner or no next action yet.`}{" "}
          Only what the work supports is ever invoiced — this says who is getting it there.
        </p>
        <div className="card" style={{ padding: 0 }}>
          <DataTable
            label="authorizations not yet invoiced"
            columns={[
              { key: "client", label: "Authorization" },
              { key: "left", label: "Not invoiced", align: "right" },
              { key: "followup", label: "Owner · next action · due" },
            ]}
            rows={notInvoiced.map(({ e, left, f }) => {
              const client = clientName.get(e.client_id) ?? "—";
              const overdue = Boolean(f?.followup_due && f.followup_due < now);
              const ownerName = f?.followup_owner ? (staffName.get(f.followup_owner) ?? "former staff") : "";
              return {
                key: e.auth_id,
                cells: {
                  client: (
                    <>
                      <Link href={`/clients/${e.client_id}`} style={{ color: "var(--teal)" }}>
                        <b>{client}</b>
                      </Link>
                      <div className="lock">
                        {e.auth_number || "(no number)"} · {e.service_type}
                      </div>
                    </>
                  ),
                  left: (
                    <>
                      <b>{money(left)}</b>
                      {n(e.unbilled) > 0 && (
                        <div className="lock" style={{ color: "var(--bad)" }}>
                          {money(n(e.unbilled))} earned
                        </div>
                      )}
                    </>
                  ),
                  followup: canBill ? (
                    <>
                      <FollowupForm
                        authId={e.auth_id}
                        owner={f?.followup_owner ?? null}
                        action={f?.followup_action ?? ""}
                        due={f?.followup_due ?? null}
                        staff={staff}
                      />
                      {overdue && (
                        <div style={{ fontSize: "var(--text-sm)", color: "var(--bad)" }}>Due {f?.followup_due} — overdue</div>
                      )}
                    </>
                  ) : ownerName ? (
                    <>
                      <b>{ownerName}</b> · {f?.followup_action}
                      {f?.followup_due && (
                        <span style={{ color: overdue ? "var(--bad)" : undefined }}> · due {f.followup_due}</span>
                      )}
                    </>
                  ) : (
                    <span style={{ color: "var(--bad)" }}>No owner yet</span>
                  ),
                },
                sort: { client, left, followup: ownerName || null },
                text: [client, e.auth_number, e.service_type, ownerName, f?.followup_action].filter(Boolean).join(" "),
              };
            })}
            empty="Every open authorization has been invoiced in full."
          />
        </div>
      </section>

      <section style={{ marginBottom: 24 }}>
        <h2 className="h2">Money in, by month</h2>
        <p className="sub" style={{ marginBottom: 12 }}>
          Invoiced against received. A month where the two diverge is a month USOR has not paid
          yet, not a month we did not work.
        </p>
        <div className="card">
          <table className="t" data-layout="bar chart, one row per month">
            <tbody>
              {byMonth.map((b) => (
                <tr key={b.month}>
                  <td style={{ width: 80, whiteSpace: "nowrap" }}>{b.month}</td>
                  <td>
                    <div
                      style={{
                        height: 10,
                        borderRadius: 5,
                        background: "var(--lime)",
                        width: `${Math.round((b.received / peak) * 100)}%`,
                        minWidth: b.received > 0 ? 4 : 0,
                      }}
                      title={`received ${money(b.received)}`}
                    />
                    {b.invoiced !== b.received && (
                      <div
                        style={{
                          height: 4,
                          marginTop: 3,
                          borderRadius: 2,
                          background: "var(--line)",
                          width: `${Math.round((b.invoiced / peak) * 100)}%`,
                          minWidth: b.invoiced > 0 ? 4 : 0,
                        }}
                        title={`invoiced ${money(b.invoiced)}`}
                      />
                    )}
                  </td>
                  <td style={{ textAlign: "right", whiteSpace: "nowrap" }}>
                    <b>{money(b.received)}</b>
                    {b.invoiced !== b.received && (
                      <div className="lock">{money(b.invoiced)} invoiced</div>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>

      <section style={{ marginBottom: 24 }}>
        <h2 className="h2">Worth watching</h2>
        <p className="sub" style={{ marginBottom: 12 }}>
          Open authorizations where the money is at risk — quiet for {RISK_QUIET_DAYS} days,
          ending within {RISK_ENDING_DAYS}, nearly out of hours, or blocked by paperwork.
        </p>
        <div className="card" style={{ padding: 0 }}>
          <DataTable
            label="authorizations"
            columns={[
              { key: "client", label: "Client and why" },
              { key: "unearned", label: "Unearned", align: "right" },
            ]}
            rows={riskRows}
            empty={
              undated > 0
                ? `Nothing to show. ${undated} of ${open.length} open authorizations carry no start date, so how long they have been quiet cannot be worked out — this section stays empty until they have one, or until hours start being logged against them.`
                : "Nothing at risk: every open authorization has been worked recently and has room left."
            }
          />
        </div>
      </section>

      <section style={{ marginBottom: 24 }}>
        <h2 className="h2">Open authorizations</h2>
        <p className="sub" style={{ marginBottom: 12 }}>
          Every one still open, largest first by what is left to earn.
        </p>
        <div className="card" style={{ padding: 0 }}>
          <DataTable
            label="authorizations"
            columns={[
              { key: "client", label: "Client" },
              { key: "service", label: "Service" },
              { key: "authorized", label: "Authorized", align: "right" },
              { key: "earned", label: "Earned", align: "right" },
              { key: "toEarn", label: "To earn", align: "right" },
              { key: "hours", label: "Hours" },
            ]}
            rows={openRows}
            empty="No authorization is open."
          />
        </div>
      </section>

      <section>
        <h2 className="h2">Where the money comes from</h2>
        <p className="sub" style={{ marginBottom: 12 }}>
          Received all time, and what is still authorized, by service.
        </p>
        <div className="card" style={{ padding: 0 }}>
          <table className="t" data-layout="totals by service, not a list of records">
            <thead>
              <tr>
                <th>Service</th>
                <th style={{ textAlign: "right" }}>Received</th>
                <th style={{ textAlign: "right" }}>Still to earn</th>
              </tr>
            </thead>
            <tbody>
              {byService.map((s) => (
                <tr key={s.service}>
                  <td>{s.service}</td>
                  <td style={{ textAlign: "right" }}>{money(s.received)}</td>
                  <td style={{ textAlign: "right" }}>
                    {s.committed > 0 ? <b>{money(s.committed)}</b> : <span className="lock">—</span>}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>

      <p className="lock" style={{ marginTop: 10 }}>
        Hourly work earns by the hour; flat-fee work earns on completion, so a flat fee with no
        completion recorded has earned nothing however much time went into it. A closed
        authorization counts as settled.{" "}
        What each client has been paid and still owes is on{" "}
        <Link href="/billing?tab=invoices#paid-and-outstanding">Billing → Invoices</Link>.{" "}
        {canBill && <Link href="/billing?tab=invoices">Raise an invoice in Billing</Link>}
      </p>
    </>
  );
}
