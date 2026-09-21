import Link from "next/link";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import {
  money,
  today,
  daysBetween,
  median,
  STAGES,
  POST_JD_STAGES,
} from "@/lib/constants";
import { Kpi, lastTwelveMonths } from "../kpi";
import { PageHead } from "../../page-head";
import { DataTable, type DataRow } from "../../data-table";

const Stat = Kpi;

/** An unmeasurable figure shows as a dash, never as zero. */
const show = (v: number | null, unit = "") => (v === null ? "—" : `${v}${unit}`);

export default async function ReportsPage({
  searchParams,
}: {
  searchParams: Promise<{ month?: string }>;
}) {
  await requireStaff();
  const { month: rawMonth } = await searchParams;
  const month = /^\d{4}-\d{2}$/.test(rawMonth ?? "") ? rawMonth! : today().slice(0, 7);

  const supabase = await createClient();

  const [
    clientsResult,
    historyResult,
    authsResult,
    entriesResult,
    invoicesResult,
    placementsResult,
    staffResult,
    completionsResult,
  ] = await Promise.all([
    supabase
      .from("clients")
      .select("id, name, created_at, stage, status, assigned_staff_id, wsa_completed, wsa_submitted"),
    supabase.from("client_stage_history").select("client_id, stage, at"),
    supabase
      .from("authorizations")
      .select("id, number, service_type, total_hours, carried_used"),
    supabase.from("service_entries").select("auth_id, date, hours, non_billable"),
    supabase.from("invoices").select("date, amount, status, paid_date"),
    supabase.from("placements").select("start_date, check90, wage"),
    supabase.from("staff").select("id, name, role").eq("active", true).eq("is_system", false),
    supabase.from("completions").select("auth_id, completion"),
  ]);

  const clients = clientsResult.data ?? [];
  const history = historyResult.data ?? [];
  const auths = authsResult.data ?? [];
  const entries = entriesResult.data ?? [];
  const invoices = (invoicesResult.data ?? []).map((i) => ({ ...i, amount: Number(i.amount) }));
  const placements = placementsResult.data ?? [];
  const staff = staffResult.data ?? [];
  const completions = completionsResult.data ?? [];

  const inMonth = (d: string | null) => Boolean(d && d.startsWith(month));

  // ── hours used per authorization ──────────────────────────
  const usedByAuth = new Map<string, number>();
  for (const a of auths) usedByAuth.set(a.id, Number(a.carried_used ?? 0));
  for (const e of entries) {
    if (e.non_billable) continue;
    usedByAuth.set(e.auth_id, (usedByAuth.get(e.auth_id) ?? 0) + Number(e.hours));
  }

  // ── stage history per client ──────────────────────────────
  const stagesByClient = new Map<string, { stage: string; at: string }[]>();
  for (const h of history) {
    const list = stagesByClient.get(h.client_id) ?? [];
    list.push({ stage: h.stage, at: h.at });
    stagesByClient.set(h.client_id, list);
  }

  const reachedJD = clients.filter((c) =>
    (stagesByClient.get(c.id) ?? []).some((h) => POST_JD_STAGES.includes(h.stage)),
  );
  const placedAll = clients.filter((c) =>
    (stagesByClient.get(c.id) ?? []).some((h) => h.stage === "Placement"),
  );

  const placementRate = reachedJD.length
    ? Math.round((placedAll.length / reachedJD.length) * 100)
    : null;

  const daysToPlace = median(
    placedAll
      .map((c) => {
        const at = (stagesByClient.get(c.id) ?? [])
          .filter((h) => h.stage === "Placement")
          .map((h) => h.at)
          .sort()[0];
        return at ? daysBetween(c.created_at, at) : null;
      })
      .filter((n): n is number => n !== null),
  );

  const hourlyAuths = auths.filter((a) => a.total_hours != null);
  const totalAuth = hourlyAuths.reduce((s, a) => s + Number(a.total_hours), 0);
  const totalUsed = hourlyAuths.reduce((s, a) => s + (usedByAuth.get(a.id) ?? 0), 0);
  const util = totalAuth ? Math.round((totalUsed / totalAuth) * 100) : null;

  const daysToPay = median(
    invoices
      .filter((i) => i.status === "Paid" && i.paid_date)
      .map((i) => daysBetween(i.date, i.paid_date!)),
  );

  const ar60 = invoices
    .filter((i) => i.status === "Sent" && daysBetween(i.date, today()) > 60)
    .reduce((s, i) => s + i.amount, 0);

  const started = placements.filter((p) => p.start_date);
  const eligible = started.filter((p) => daysBetween(p.start_date!, today()) >= 90);
  const retention = eligible.length
    ? Math.round((placements.filter((p) => p.check90).length / eligible.length) * 100)
    : null;

  const withWage = started.filter((p) => p.wage != null);
  const avgWage = withWage.length
    ? (withWage.reduce((t, p) => t + Number(p.wage), 0) / withWage.length).toFixed(2)
    : null;

  const wsaDone = clients.filter((c) => c.wsa_completed).length;
  const wsaSubmitted = clients.filter((c) => c.wsa_submitted).length;
  const paidTotal = invoices.filter((i) => i.status === "Paid").reduce((t, i) => t + i.amount, 0);

  // ── the selected month ────────────────────────────────────
  const newClients = clients.filter((c) => inMonth(c.created_at)).length;
  const placedThisMonth = clients.filter((c) =>
    (stagesByClient.get(c.id) ?? []).some((h) => h.stage === "Placement" && inMonth(h.at)),
  ).length;
  const monthHours = entries
    .filter((e) => inMonth(e.date) && !e.non_billable)
    .reduce((s, e) => s + Number(e.hours), 0);
  const issued = invoices.filter((i) => inMonth(i.date));
  const paidInMonth = invoices.filter((i) => i.status === "Paid" && inMonth(i.paid_date));

  // The same five figures for each of the twelve months to the one shown.
  const trend = lastTwelveMonths(month).map((m) => {
    const inM = (d: string | null) => Boolean(d && d.startsWith(m));
    return {
      month: m,
      newClients: clients.filter((c) => inM(c.created_at)).length,
      placed: clients.filter((c) => (stagesByClient.get(c.id) ?? []).some((h) => h.stage === "Placement" && inM(h.at))).length,
      hours: entries.filter((e) => inM(e.date) && !e.non_billable).reduce((s, e) => s + Number(e.hours), 0),
      issued: invoices.filter((i) => inM(i.date)).length,
      paid: invoices.filter((i) => i.status === "Paid" && inM(i.paid_date)).length,
    };
  });
  const series = (k: "newClients" | "placed" | "hours" | "issued" | "paid") =>
    trend.map((t) => ({ month: t.month, value: t[k] }));

  const byStage = STAGES.map((s) => ({
    stage: s,
    n: clients.filter((c) => c.stage === s && c.status === "Active").length,
  }));

  const caseload = staff
    .filter((s) => s.role !== "Reports")
    .map((s) => ({
      name: s.name,
      n: clients.filter((c) => c.assigned_staff_id === s.id && c.status === "Active").length,
    }));

  const completionByAuth = new Map(completions.map((c) => [c.auth_id, c.completion]));

  /**
   * Some KPIs cannot mean what they appear to until the CRM has its own
   * history. Saying so beside the number is better than letting someone quote
   * a confident figure to a counselor.
   */
  const migrationCaveats: string[] = [];

  const singleStageClients = clients.filter(
    (c) => (stagesByClient.get(c.id) ?? []).length <= 1,
  ).length;
  if (singleStageClients > clients.length / 2) {
    migrationCaveats.push(
      `Placement rate and days-to-placement come from pipeline history, and ${singleStageClients} of ${clients.length} clients arrived with a single stage entry — where they stood at import, not the path they took. Anyone who passed through Job Development before the migration is not counted as having reached it.`,
    );
  }

  const sameDayPaid = invoices.filter(
    (i) => i.status === "Paid" && i.paid_date && i.paid_date === i.date,
  ).length;
  const paidWithDate = invoices.filter((i) => i.status === "Paid" && i.paid_date).length;
  if (paidWithDate > 0 && sameDayPaid > paidWithDate / 2) {
    migrationCaveats.push(
      `Days invoice → paid reads ${show(daysToPay)} because ${sameDayPaid} of ${paidWithDate} migrated invoices carry the warrant date as both the issue and payment date. It becomes a real measure for invoices raised in the CRM.`,
    );
  }

  if (eligible.length > 0 && placements.filter((p) => p.check90).length === 0) {
    migrationCaveats.push(
      `90-day retention reads 0% because ${eligible.length} placements are past 90 days but none has a 90-day check recorded. Either the checks were not logged in the workbook, or they are genuinely outstanding — worth confirming, since 90-day retention is what USOR measures.`,
    );
  }

  if (started.length > 0 && withWage.length === 0) {
    migrationCaveats.push(
      `No placement has a wage recorded, so average wage cannot be calculated.`,
    );
  }

  const caseloadRows: DataRow[] = caseload.map((x) => ({
    key: x.name,
    cells: { name: x.name, n: <b>{x.n}</b> },
    sort: { n: x.n },
  }));

  const utilisationRows: DataRow[] = auths.map((a) => {
    const used =
      a.total_hours != null
        ? `${usedByAuth.get(a.id) ?? 0} / ${a.total_hours} hrs`
        : completionByAuth.get(a.id)
          ? "completed"
          : "in progress";
    return {
      key: a.id,
      cells: { number: a.number || "—", service: a.service_type, used },
      // The share of hours used; a flat fee has no share and sorts last.
      sort: { used: a.total_hours ? (usedByAuth.get(a.id) ?? 0) / Number(a.total_hours) : null },
      text: [a.number, a.service_type, used].filter(Boolean).join(" "),
    };
  });

  return (
    <>
      <PageHead title="Key performance indicators" context="All-time, calculated live from the record" />

      <div
        className="grid"
        style={{ gridTemplateColumns: "repeat(auto-fit, minmax(165px, 1fr))", marginBottom: 24 }}
      >
        <Stat value={show(placementRate, "%")} label="placement rate" />
        <Stat value={show(daysToPlace)} label="median days referral → placement" />
        <Stat value={show(util, "%")} label="authorized hours used" />
        <Stat value={show(daysToPay)} label="median days invoice → paid" />
        <Stat
          value={money(ar60)}
          label="A/R over 60 days · aging on Billing → Invoices"
          tone={ar60 > 0 ? "bad" : undefined}
          href="/billing?tab=invoices"
        />
        <Stat value={placements.length} label="placements on record" />
        <Stat value={show(retention, "%")} label="90-day retention (of eligible)" />
        <Stat value={wsaDone} label={`WSAs completed · ${wsaSubmitted} submitted`} />
        <Stat value={avgWage === null ? "—" : `$${avgWage}`} label="average placement wage" />
        <Stat value={money(paidTotal)} label="total received (all time) · see Money" href="/insights/money" />
      </div>

      {migrationCaveats.length > 0 && (
        <div className="alert" style={{ marginBottom: 24 }}>
          <b>Read these figures with the migration in mind.</b> The workbook recorded outcomes,
          not the history behind them, so some measures only become real as work is done in the
          CRM:
          <ul style={{ margin: "8px 0 0", paddingLeft: 20 }}>
            {migrationCaveats.map((c) => (
              <li key={c} style={{ marginBottom: 4 }}>
                {c}
              </li>
            ))}
          </ul>
        </div>
      )}

      <div className="card" style={{ marginBottom: 24 }}>
        <h3>Client progress report</h3>
        <p className="sub" style={{ marginTop: 0 }}>
          Weekly or monthly, built from a client&apos;s timestamped notes, service hours,
          counselor contacts and tasks. Open a client and choose the Report tab.
        </p>
        <Link href="/clients" className="btn ghost" style={{ textDecoration: "none" }}>
          Choose a client
        </Link>
      </div>

      {/* The monthly report is a section of this screen, not a second screen, so its heading is an h2. */}
      <div className="row2" style={{ justifyContent: "space-between", alignItems: "flex-end" }}>
        <div>
          <h2 className="h2">Monthly report</h2>
          <p className="sub" style={{ margin: 0 }}>
            Read-only summary for reporting
          </p>
        </div>
        <form style={{ maxWidth: 200 }}>
          <input type="month" name="month" defaultValue={month} />
          <button className="btn ghost" type="submit" style={{ marginTop: 6, width: "100%" }}>
            Show month
          </button>
        </form>
      </div>

      <div
        className="grid"
        style={{ gridTemplateColumns: "repeat(auto-fit, minmax(165px, 1fr))", margin: "14px 0 24px" }}
      >
        <Stat value={newClients} label="new clients" series={series("newClients")} describe={(v) => `${v} new`} />
        <Stat value={placedThisMonth} label="placements" series={series("placed")} describe={(v) => `${v} placed`} />
        <Stat value={monthHours} label="billable hours logged" series={series("hours")} describe={(v) => `${v} hours`} />
        <Stat
          value={issued.length}
          label={`invoices issued · ${money(issued.reduce((s, i) => s + i.amount, 0))}`}
          series={series("issued")}
          describe={(v) => `${v} issued`}
        />
        <Stat
          value={paidInMonth.length}
          label={`paid · ${money(paidInMonth.reduce((s, i) => s + i.amount, 0))}`}
          series={series("paid")}
          describe={(v) => `${v} paid`}
        />
      </div>

      <div className="grid" style={{ gridTemplateColumns: "repeat(auto-fit, minmax(300px, 1fr))" }}>
        <div className="card">
          <h3>Caseload by stage (active clients)</h3>
          <table className="t" data-layout="key and value: a count for each stage, in pipeline order">
            <tbody>
              {byStage.map((x) => (
                <tr key={x.stage}>
                  <td>{x.stage}</td>
                  <td style={{ textAlign: "right" }}>
                    <b>{x.n}</b>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        <div className="card" style={{ padding: 0 }}>
          <h3 style={{ padding: "20px 20px 0" }}>Active caseload per staff member</h3>
          <DataTable
            label="staff"
            columns={[
              { key: "name", label: "Staff member" },
              { key: "n", label: "Active clients", align: "right" },
            ]}
            rows={caseloadRows}
            empty="No staff to report on."
          />
        </div>

        <div className="card" style={{ gridColumn: "1 / -1", padding: 0 }}>
          <h3 style={{ padding: "20px 20px 0" }}>Authorization utilisation</h3>
          <DataTable
            label="authorizations"
            columns={[
              { key: "number", label: "Authorization" },
              { key: "service", label: "Service" },
              { key: "used", label: "Used" },
            ]}
            rows={utilisationRows}
            empty="No authorizations are on file."
          />
        </div>
      </div>
    </>
  );
}
