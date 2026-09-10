import Link from "next/link";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { ORG } from "@/lib/roles";
import { money, today, daysBetween, median } from "@/lib/constants";

/**
 * The outcomes one-pager.
 *
 * One page, for handing to somebody: a counselor asking what we did with
 * their referrals, USOR at a review, or the owner deciding whether a quarter
 * went well. It prints — the practice's name and vendor number at the top, no
 * navigation, nothing that only makes sense on a screen.
 *
 * Every figure that cannot be measured shows a dash and says why underneath.
 * A one-pager full of confident zeros is worse than a short one: somebody
 * quotes "0% retention" to a funder and it is not true, it is unrecorded.
 */

const show = (v: number | null, unit = "") => (v === null ? "—" : `${v}${unit}`);

type Period = { key: string; label: string; start: string; end: string };

function periods(now: string): Period[] {
  const year = Number(now.slice(0, 4));
  const twelve = new Date(now + "T00:00:00Z");
  twelve.setUTCFullYear(twelve.getUTCFullYear() - 1);
  return [
    {
      key: "12m",
      label: "Last 12 months",
      start: twelve.toISOString().slice(0, 10),
      end: now,
    },
    { key: "ytd", label: `${year} to date`, start: `${year}-01-01`, end: now },
    {
      key: String(year - 1),
      label: `${year - 1}`,
      start: `${year - 1}-01-01`,
      end: `${year - 1}-12-31`,
    },
    { key: "all", label: "All time", start: "1900-01-01", end: now },
  ];
}

function Figure({
  value,
  label,
  note,
}: {
  value: string | number;
  label: string;
  note?: string;
}) {
  return (
    <div className="card">
      <div className="stat">
        {value}
        <small>{label}</small>
      </div>
      {note && (
        <p className="lock" style={{ margin: "6px 0 0" }}>
          {note}
        </p>
      )}
    </div>
  );
}

export default async function OutcomesPage({
  searchParams,
}: {
  searchParams: Promise<{ period?: string }>;
}) {
  await requireStaff();
  const { period: rawPeriod } = await searchParams;

  const now = today();
  const options = periods(now);
  const period = options.find((p) => p.key === rawPeriod) ?? options[0];
  const { start, end } = period;
  const within = (d: string | null | undefined) => Boolean(d && d >= start && d <= end);

  const supabase = await createClient();

  const [
    clientsResult,
    reachedResult,
    placementsResult,
    invoicesResult,
    entriesResult,
    econResult,
    counselorsResult,
  ] = await Promise.all([
    supabase
      .from("clients")
      .select("id, name, status, stage, created_at, counselor_id, ce, wsa_tier, wsa_completed, wsa_submitted"),
    supabase.from("client_stages_reached").select("client_id, stage"),
    supabase
      .from("placements")
      .select("client_id, employer, title, start_date, wage, hours_week, check30, check60, check90, jp_paid"),
    supabase.from("invoices").select("auth_id, date, amount, status, paid_date, service_type"),
    supabase.from("service_entries").select("auth_id, date, hours, non_billable"),
    supabase.from("authorization_economics").select("auth_id, client_id, service_type, hours_used, received"),
    supabase.from("counselors").select("id, name"),
  ]);

  const clients = clientsResult.data ?? [];
  const reached = reachedResult.data ?? [];
  const placements = placementsResult.data ?? [];
  const invoices = (invoicesResult.data ?? []).map((i) => ({ ...i, amount: Number(i.amount) }));
  const entries = entriesResult.data ?? [];
  const econ = econResult.data ?? [];
  const counselors = counselorsResult.data ?? [];

  const authService = new Map(econ.map((e) => [e.auth_id, e.service_type ?? "—"]));
  const authClient = new Map(econ.map((e) => [e.auth_id, e.client_id]));

  // ── who we worked with ────────────────────────────────────
  const referredInPeriod = clients.filter((c) => within(c.created_at.slice(0, 10)));

  // "Served" means something happened for them that we can point at: an hour
  // logged, an invoice raised, or a placement started.
  const servedIds = new Set<string>();
  for (const e of entries) {
    if (!within(e.date)) continue;
    const clientOf = authClient.get(e.auth_id);
    if (clientOf) servedIds.add(clientOf);
  }
  for (const p of placements) if (within(p.start_date)) servedIds.add(p.client_id);
  for (const i of invoices) {
    // The authorization says whose invoice it is. Matching on service type
    // would count everybody who has ever had Job Coaching authorized.
    if (i.status !== "Paid" || !within(i.paid_date)) continue;
    const clientOf = i.auth_id ? authClient.get(i.auth_id) : null;
    if (clientOf) servedIds.add(clientOf);
  }

  // ── placements ────────────────────────────────────────────
  const started = placements.filter((p) => within(p.start_date));
  const feesPaid = placements.filter((p) => within(p.jp_paid));

  const eligible90 = placements.filter(
    (p) => p.start_date && daysBetween(p.start_date, end) >= 90,
  );
  const held90 = eligible90.filter((p) => p.check90);
  const retention90 = eligible90.length
    ? Math.round((held90.length / eligible90.length) * 100)
    : null;

  const withWage = placements.filter((p) => within(p.start_date) && p.wage != null);
  const medianWage = withWage.length
    ? median(withWage.map((p) => Number(p.wage) * 100))
    : null;
  const withHours = placements.filter((p) => within(p.start_date) && p.hours_week != null);
  const medianHours = withHours.length
    ? median(withHours.map((p) => Number(p.hours_week)))
    : null;

  // ── service delivered ─────────────────────────────────────
  const hoursInPeriod = entries
    .filter((e) => within(e.date) && !e.non_billable)
    .reduce((s, e) => s + Number(e.hours), 0);

  const byService = new Map<string, { hours: number; received: number }>();
  for (const e of entries) {
    if (!within(e.date) || e.non_billable) continue;
    const key = authService.get(e.auth_id) ?? "—";
    const row = byService.get(key) ?? { hours: 0, received: 0 };
    row.hours += Number(e.hours);
    byService.set(key, row);
  }
  for (const i of invoices) {
    if (i.status !== "Paid" || !within(i.paid_date)) continue;
    const key = i.service_type || "—";
    const row = byService.get(key) ?? { hours: 0, received: 0 };
    row.received += i.amount;
    byService.set(key, row);
  }
  const services = [...byService.entries()]
    .map(([service, v]) => ({ service, ...v }))
    .sort((a, b) => b.received - a.received || b.hours - a.hours);

  const receivedInPeriod = invoices
    .filter((i) => i.status === "Paid" && within(i.paid_date))
    .reduce((s, i) => s + i.amount, 0);

  // ── assessments and CIE ───────────────────────────────────
  const wsaCompleted = clients.filter((c) => within(c.wsa_completed)).length;
  const wsaSubmitted = clients.filter((c) => within(c.wsa_submitted)).length;
  const cie = clients.filter((c) => c.ce).length;

  // ── conversion, all time ──────────────────────────────────
  const reachedSet = (stage: string) =>
    new Set(reached.filter((r) => r.stage === stage).map((r) => r.client_id));
  const reachedJD = reachedSet("Job Development").size;
  const reachedPlacement = reachedSet("Placement").size;
  const placementRate = reachedJD ? Math.round((reachedPlacement / reachedJD) * 100) : null;

  // ── counselors we worked with ─────────────────────────────
  const counselorName = new Map(counselors.map((k) => [k.id, k.name]));
  const byCounselor = new Map<string, { referred: number; served: number }>();
  for (const c of clients) {
    if (!c.counselor_id) continue;
    const key = counselorName.get(c.counselor_id) ?? "—";
    const row = byCounselor.get(key) ?? { referred: 0, served: 0 };
    if (within(c.created_at.slice(0, 10))) row.referred += 1;
    if (servedIds.has(c.id)) row.served += 1;
    byCounselor.set(key, row);
  }
  const counselorRows = [...byCounselor.entries()]
    .map(([name, v]) => ({ name, ...v }))
    .filter((r) => r.referred > 0 || r.served > 0)
    .sort((a, b) => b.served - a.served || b.referred - a.referred);

  // ── what is not recorded ──────────────────────────────────
  const unmeasured: string[] = [];
  if (eligible90.length === 0) {
    unmeasured.push(
      "90-day retention: no placement in this period is both 90 days old and has a 90-day check recorded, so the rate cannot be worked out.",
    );
  } else if (held90.length === 0) {
    unmeasured.push(
      `90-day retention reads 0% because ${eligible90.length} placements are past 90 days and none has a check recorded. That is a gap in the record, not a result.`,
    );
  }
  if (withWage.length === 0) {
    unmeasured.push("Wages: no placement carries a wage, so no wage figure can be given.");
  }
  if (withHours.length === 0) {
    unmeasured.push("Hours a week: not recorded on any placement.");
  }
  const undatedPlacements = placements.filter((p) => !p.start_date).length;
  if (undatedPlacements > 0) {
    unmeasured.push(
      `${undatedPlacements} of ${placements.length} placements have no start date, so they cannot be counted in any period — only in "all time".`,
    );
  }
  if (hoursInPeriod === 0) {
    unmeasured.push(
      "Service hours: none have been logged in the CRM yet. Hours delivered before the migration live on the authorizations as a carried total and are not dated, so they cannot be counted into a period.",
    );
  }

  return (
    <>
      <div className="no-print">
        <div className="row2" style={{ justifyContent: "space-between", alignItems: "flex-end" }}>
          <div>
            <h1 className="h1">Outcomes</h1>
            <p className="sub" style={{ margin: 0 }}>
              One page to hand to a counselor or a funder. Use your browser&apos;s print to make
              a PDF.
            </p>
          </div>
          <div className="tabs" style={{ margin: 0, borderBottom: 0, flexWrap: "wrap" }}>
            {options.map((p) => (
              <Link
                key={p.key}
                href={`/insights/outcomes?period=${p.key}`}
                className={p.key === period.key ? "on" : ""}
              >
                {p.label}
              </Link>
            ))}
          </div>
        </div>
      </div>

      <div className="card" style={{ margin: "14px 0" }}>
        <h2 style={{ margin: 0, fontSize: 20 }}>{ORG.name}</h2>
        <p className="sub" style={{ margin: "2px 0 0" }}>
          {ORG.address} · {ORG.phone} · {ORG.email}
        </p>
        <p className="sub" style={{ margin: "2px 0 0" }}>
          Vendor {ORG.vendor} · Utah State Office of Rehabilitation
        </p>
        <hr style={{ border: 0, borderTop: "1px solid var(--line)", margin: "12px 0" }} />
        <h3 style={{ margin: 0 }}>Client outcomes — {period.label}</h3>
        <p className="lock" style={{ margin: "4px 0 0" }}>
          {start} to {end} · prepared {now}
        </p>
      </div>

      <div
        className="grid"
        style={{ gridTemplateColumns: "repeat(auto-fit, minmax(190px, 1fr))", marginBottom: 14 }}
      >
        <Figure value={servedIds.size} label="clients served" note="Hours logged, a placement started, or an invoice paid for them." />
        <Figure value={referredInPeriod.length} label="new referrals" />
        <Figure value={started.length} label="placements started" />
        <Figure value={feesPaid.length} label="placement fees paid" note="A fee paid is USOR agreeing the placement stood." />
        <Figure value={show(retention90, "%")} label="90-day retention" note={`${held90.length} of ${eligible90.length} eligible`} />
        <Figure
          value={medianWage === null ? "—" : money(medianWage / 100)}
          label="median starting wage"
        />
        <Figure value={show(medianHours)} label="median hours a week" />
        <Figure value={money(receivedInPeriod)} label="received for services" />
      </div>

      <div
        className="grid"
        style={{ gridTemplateColumns: "repeat(auto-fit, minmax(190px, 1fr))", marginBottom: 14 }}
      >
        <Figure value={wsaCompleted} label="work skills assessments completed" />
        <Figure value={wsaSubmitted} label="assessments submitted to USOR" />
        <Figure value={cie} label="in competitive integrated employment" note="All time, from the client record." />
        <Figure
          value={show(placementRate, "%")}
          label="reach job development and get placed"
          note="All time, not the period."
        />
      </div>

      <div className="card" style={{ marginBottom: 14, padding: 0 }}>
        <div style={{ padding: "16px 16px 0" }}>
          <h3 style={{ margin: 0 }}>Service delivered</h3>
          <p className="sub" style={{ margin: "4px 0 0" }}>
            Hours logged in the period, and money received for that service in the period.
          </p>
        </div>
        <table className="t">
          <thead>
            <tr>
              <th>Service</th>
              <th style={{ textAlign: "right" }}>Hours</th>
              <th style={{ textAlign: "right" }}>Received</th>
            </tr>
          </thead>
          <tbody>
            {services.length === 0 && (
              <tr>
                <td colSpan={3} className="empty">
                  Nothing logged or received in this period.
                </td>
              </tr>
            )}
            {services.map((s) => (
              <tr key={s.service}>
                <td>{s.service}</td>
                <td style={{ textAlign: "right" }}>
                  {s.hours > 0 ? s.hours : <span className="lock">—</span>}
                </td>
                <td style={{ textAlign: "right" }}>
                  {s.received > 0 ? money(s.received) : <span className="lock">—</span>}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {started.length > 0 && (
        <div className="card" style={{ marginBottom: 14, padding: 0 }}>
          <div style={{ padding: "16px 16px 0" }}>
            <h3 style={{ margin: 0 }}>Placements in the period</h3>
          </div>
          <table className="t">
            <thead>
              <tr>
                <th>Started</th>
                <th>Employer</th>
                <th>Position</th>
                <th>Checks</th>
              </tr>
            </thead>
            <tbody>
              {started
                .sort((a, b) => (a.start_date ?? "").localeCompare(b.start_date ?? ""))
                .map((p, i) => (
                  <tr key={`${p.client_id}-${i}`}>
                    <td>{p.start_date}</td>
                    <td>{p.employer || "—"}</td>
                    <td>{p.title || "—"}</td>
                    <td className="lock">
                      {[p.check30 && "30", p.check60 && "60", p.check90 && "90"]
                        .filter(Boolean)
                        .join(" · ") || "none recorded"}
                    </td>
                  </tr>
                ))}
            </tbody>
          </table>
        </div>
      )}

      {counselorRows.length > 0 && (
        <div className="card" style={{ marginBottom: 14, padding: 0 }}>
          <div style={{ padding: "16px 16px 0" }}>
            <h3 style={{ margin: 0 }}>By counselor</h3>
          </div>
          <table className="t">
            <thead>
              <tr>
                <th>Counselor</th>
                <th style={{ textAlign: "right" }}>Referred in period</th>
                <th style={{ textAlign: "right" }}>Served in period</th>
              </tr>
            </thead>
            <tbody>
              {counselorRows.map((r) => (
                <tr key={r.name}>
                  <td>{r.name}</td>
                  <td style={{ textAlign: "right" }}>{r.referred}</td>
                  <td style={{ textAlign: "right" }}>{r.served}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <div className="card">
        <h3 style={{ marginTop: 0 }}>How these figures are counted</h3>
        <ul style={{ margin: "8px 0 0", paddingLeft: 20, fontSize: 13, lineHeight: 1.6 }}>
          <li>
            <b>Clients served</b> — anyone with an hour logged, a placement started, or an invoice
            paid for their service inside the period.
          </li>
          <li>
            <b>90-day retention</b> — placements that started at least 90 days before the end of
            the period and have a 90-day check recorded, over all placements old enough to have
            one.
          </li>
          <li>
            <b>Received</b> — invoices marked paid inside the period, by the date they were paid,
            not the date they were raised.
          </li>
          <li>
            <b>Placement rate</b> — of everyone who has ever reached Job Development, the share
            who have ever reached Placement. All time, because a rate over three months is a
            number about timing rather than about outcomes.
          </li>
        </ul>

        {unmeasured.length > 0 && (
          <>
            <h3 style={{ marginBottom: 4 }}>What is not in the record</h3>
            <ul style={{ margin: 0, paddingLeft: 20, fontSize: 13, lineHeight: 1.6 }}>
              {unmeasured.map((u) => (
                <li key={u}>{u}</li>
              ))}
            </ul>
          </>
        )}

        <p className="lock" style={{ margin: "12px 0 0" }}>
          Prepared from the client record on {now}. Figures that cannot be measured are shown as a
          dash rather than as zero.
        </p>
      </div>
    </>
  );
}
