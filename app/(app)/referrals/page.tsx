import Link from "next/link";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { today, median } from "@/lib/constants";

/**
 * The referral pipeline.
 *
 * The clients list says what stage somebody is in. This says how long they
 * have been in it and how many get past it — the difference between a busy
 * front door and a queue nobody is working.
 *
 * The first time it was run it found 24 clients at Referral, 23 of them with
 * nothing authorized, the oldest sitting there 496 days. None of that was
 * hidden; it was just spread across 92 records with no screen that added up.
 */

const FUNNEL = [
  "Referral",
  "Intake",
  "Assessment",
  "Job Development",
  "Placement",
  "Job Coaching",
  "Follow-Along",
] as const;

/** The stages where a client is waiting on us rather than working. */
const FRONT = ["Referral", "Intake", "Assessment"];
const STALLED_DAYS = 30;

type Row = {
  client_id: string;
  name: string;
  status: string;
  stage: string;
  counselor_id: string | null;
  referring_office: string | null;
  assigned_staff_id: string | null;
  referred_at: string;
  stage_since: string | null;
  days_in_stage: number;
  auth_count: number;
  first_auth_on: string | null;
  first_placement_on: string | null;
  no_authorization: boolean;
};

function lastTwelve(month: string): string[] {
  const [y, m] = month.split("-").map(Number);
  const out: string[] = [];
  for (let i = 11; i >= 0; i--) {
    out.push(new Date(Date.UTC(y, m - 1 - i, 1)).toISOString().slice(0, 7));
  }
  return out;
}

export default async function ReferralsPage({
  searchParams,
}: {
  searchParams: Promise<{ show?: string }>;
}) {
  await requireStaff();
  const { show: rawShow } = await searchParams;
  const show = rawShow === "all" ? "all" : "front";

  const supabase = await createClient();

  const [pipelineResult, reachedResult, counselorsResult, staffResult] = await Promise.all([
    supabase.from("client_pipeline").select("*"),
    supabase.from("client_stages_reached").select("client_id, stage"),
    supabase.from("counselors").select("id, name"),
    supabase.from("staff").select("id, name"),
  ]);

  const rows = (pipelineResult.data ?? []) as unknown as Row[];
  const reached = reachedResult.data ?? [];
  const counselorName = new Map((counselorsResult.data ?? []).map((k) => [k.id, k.name]));
  const staffName = new Map((staffResult.data ?? []).map((s) => [s.id, s.name]));

  const active = rows.filter((r) => r.status === "Active");

  // ── the funnel ────────────────────────────────────────────
  const reachedBy = new Map<string, Set<string>>();
  for (const r of reached) {
    if (!r.stage || !r.client_id) continue;
    const set = reachedBy.get(r.stage) ?? new Set<string>();
    set.add(r.client_id);
    reachedBy.set(r.stage, set);
  }
  const funnel = FUNNEL.map((stage, i) => {
    const n = reachedBy.get(stage)?.size ?? 0;
    const prev = i === 0 ? n : (reachedBy.get(FUNNEL[i - 1])?.size ?? 0);
    return {
      stage,
      reached: n,
      standingHere: active.filter((r) => r.stage === stage).length,
      fromPrevious: i === 0 || prev === 0 ? null : Math.round((n / prev) * 100),
    };
  });
  const referredKnown = funnel[0].reached;

  // ── arriving ──────────────────────────────────────────────
  const months = lastTwelve(today().slice(0, 7));
  const byMonth = months.map((m) => ({
    month: m,
    n: rows.filter((r) => r.referred_at.startsWith(m)).length,
  }));
  const peak = Math.max(1, ...byMonth.map((b) => b.n));
  const last90 = rows.filter(
    (r) => r.referred_at.slice(0, 10) >= new Date(Date.now() - 90 * 86400000).toISOString().slice(0, 10),
  ).length;

  // ── waiting at the front ──────────────────────────────────
  const front = active.filter((r) => FRONT.includes(r.stage));
  const stalled = front
    .filter((r) => r.days_in_stage >= STALLED_DAYS)
    .sort((a, b) => b.days_in_stage - a.days_in_stage);
  const frontNoAuth = front.filter((r) => r.no_authorization).length;
  const medianFrontWait = median(front.map((r) => r.days_in_stage));

  const listed = show === "all" ? active : front;
  const shown = [...listed].sort((a, b) => b.days_in_stage - a.days_in_stage);

  // ── who sends them ────────────────────────────────────────
  const placedIds = reachedBy.get("Placement") ?? new Set<string>();
  const sources = new Map<string, { referred: number; placed: number; waiting: number }>();
  for (const r of rows) {
    const key = r.counselor_id
      ? (counselorName.get(r.counselor_id) ?? "—")
      : r.referring_office || "Not recorded";
    const row = sources.get(key) ?? { referred: 0, placed: 0, waiting: 0 };
    row.referred += 1;
    if (placedIds.has(r.client_id)) row.placed += 1;
    if (r.status === "Active" && FRONT.includes(r.stage)) row.waiting += 1;
    sources.set(key, row);
  }
  const bySource = [...sources.entries()]
    .map(([source, v]) => ({ source, ...v }))
    .sort((a, b) => b.referred - a.referred);

  // ── what the figures cannot yet mean ──────────────────────
  const caveats: string[] = [];
  const unplaceable = rows.length - referredKnown;
  if (unplaceable > 0) {
    caveats.push(
      `${unplaceable} clients arrived from the workbook with only "Closed" in their stage history, so nothing can be said about the path they took. The funnel below counts the ${referredKnown} whose position is known.`,
    );
  }
  const singleEntry = rows.filter((r) => !r.stage_since).length;
  if (singleEntry > 0) {
    caveats.push(
      `${singleEntry} clients have no record of entering the stage they are in, so "days waiting" counts from when the record was created instead.`,
    );
  }
  const noSource = rows.filter((r) => !r.counselor_id && !r.referring_office).length;
  if (noSource > 0) {
    caveats.push(
      `${noSource} clients have neither a counselor nor a referring office, so where they came from cannot be counted.`,
    );
  }

  return (
    <>
      <h1 className="h1">Referrals</h1>
      <p className="sub">
        Who has been sent to us, how far they get, and how long they wait at each step
      </p>

      <div
        className="grid"
        style={{ gridTemplateColumns: "repeat(auto-fit, minmax(200px, 1fr))", margin: "14px 0 8px" }}
      >
        <div className="card">
          <div className="stat">
            {last90}
            <small>referred in the last 90 days</small>
          </div>
        </div>
        <div className="card">
          <div className="stat" style={front.length > 0 ? { color: "var(--gold)" } : undefined}>
            {front.length}
            <small>waiting at referral, intake or assessment</small>
          </div>
        </div>
        <div className="card">
          <div className="stat" style={frontNoAuth > 0 ? { color: "var(--bad)" } : undefined}>
            {frontNoAuth}
            <small>of those with nothing authorized</small>
          </div>
          <p className="lock" style={{ margin: "6px 0 0" }}>
            USOR has sent them and no service has been agreed, so no work can be billed for them
            yet.
          </p>
        </div>
        <div className="card">
          <div className="stat">
            {medianFrontWait === null ? "—" : medianFrontWait}
            <small>median days waiting at the front</small>
          </div>
        </div>
      </div>

      {caveats.length > 0 && (
        <div className="alert" style={{ marginBottom: 18 }}>
          <b>Read these figures with the migration in mind.</b>
          <ul style={{ margin: "8px 0 0", paddingLeft: 20 }}>
            {caveats.map((c) => (
              <li key={c} style={{ marginBottom: 4 }}>
                {c}
              </li>
            ))}
          </ul>
        </div>
      )}

      <div className="card" style={{ marginBottom: 18, padding: 0 }}>
        <div style={{ padding: "16px 16px 0" }}>
          <h3 style={{ margin: 0 }}>How far people get</h3>
          <p className="sub" style={{ margin: "4px 0 0" }}>
            Everyone who has ever reached each stage, and how many are standing there now. A
            client at Job Coaching is counted as having reached Job Development, whether or not
            the workbook remembered it.
          </p>
        </div>
        <table className="t">
          <thead>
            <tr>
              <th>Stage</th>
              <th>Ever reached</th>
              <th>From the stage before</th>
              <th>Standing here now</th>
            </tr>
          </thead>
          <tbody>
            {funnel.map((f) => (
              <tr key={f.stage}>
                <td>
                  <b>{f.stage}</b>
                </td>
                <td>
                  <div className="row2" style={{ gap: 8 }}>
                    <div
                      style={{
                        height: 10,
                        borderRadius: 5,
                        background: "var(--teal)",
                        width: `${referredKnown ? Math.round((f.reached / referredKnown) * 100) : 0}%`,
                        minWidth: f.reached > 0 ? 4 : 0,
                        flex: "0 0 auto",
                      }}
                    />
                    <span>{f.reached}</span>
                  </div>
                </td>
                <td>{f.fromPrevious === null ? "—" : `${f.fromPrevious}%`}</td>
                <td>{f.standingHere || <span className="lock">none</span>}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div className="card" style={{ marginBottom: 18 }}>
        <h3 style={{ marginTop: 0 }}>Referrals arriving, by month</h3>
        <table className="t">
          <tbody>
            {byMonth.map((b) => (
              <tr key={b.month}>
                <td style={{ width: 80 }}>{b.month}</td>
                <td>
                  <div
                    style={{
                      height: 10,
                      borderRadius: 5,
                      background: "var(--lime)",
                      width: `${Math.round((b.n / peak) * 100)}%`,
                      minWidth: b.n > 0 ? 4 : 0,
                    }}
                  />
                </td>
                <td style={{ textAlign: "right", width: 60 }}>
                  <b>{b.n}</b>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div className="card" style={{ marginBottom: 18, padding: 0 }}>
        <div style={{ padding: "16px 16px 0" }}>
          <div className="row2" style={{ justifyContent: "space-between" }}>
            <div>
              <h3 style={{ margin: 0 }}>
                {show === "front" ? "Waiting at the front" : "Every active client"}
              </h3>
              <p className="sub" style={{ margin: "4px 0 0" }}>
                Longest wait first.{" "}
                {stalled.length > 0 && (
                  <b style={{ color: "var(--bad)" }}>
                    {stalled.length} have been waiting more than {STALLED_DAYS} days.
                  </b>
                )}
              </p>
            </div>
            <div className="tabs" style={{ margin: 0, borderBottom: 0 }}>
              <Link href="/referrals?show=front" className={show === "front" ? "on" : ""}>
                Front of the pipeline
              </Link>
              <Link href="/referrals?show=all" className={show === "all" ? "on" : ""}>
                Everyone active
              </Link>
            </div>
          </div>
        </div>
        <table className="t">
          <thead>
            <tr>
              <th>Client</th>
              <th>Stage</th>
              <th>Waiting</th>
              <th>Counselor</th>
              <th>With</th>
            </tr>
          </thead>
          <tbody>
            {shown.length === 0 && (
              <tr>
                <td colSpan={5} className="empty">
                  Nobody is waiting at the front of the pipeline.
                </td>
              </tr>
            )}
            {shown.map((r) => (
              <tr key={r.client_id}>
                <td>
                  <Link href={`/clients/${r.client_id}`} style={{ color: "var(--teal)" }}>
                    <b>{r.name}</b>
                  </Link>
                  {r.no_authorization && (
                    <div style={{ fontSize: 12, color: "var(--bad)" }}>nothing authorized</div>
                  )}
                </td>
                <td>
                  <span className="chip">{r.stage}</span>
                </td>
                <td style={{ whiteSpace: "nowrap" }}>
                  <span className={"chip " + (r.days_in_stage >= STALLED_DAYS ? "bad" : "")}>
                    {r.days_in_stage} days
                  </span>
                  <div className="lock">
                    {r.stage_since ? `since ${r.stage_since.slice(0, 10)}` : "no stage record"}
                  </div>
                </td>
                <td>
                  {r.counselor_id ? (
                    <Link href={`/counselors/${r.counselor_id}`} style={{ color: "var(--teal)" }}>
                      {counselorName.get(r.counselor_id) ?? "—"}
                    </Link>
                  ) : (
                    <span className="lock">{r.referring_office || "not recorded"}</span>
                  )}
                </td>
                <td>
                  {r.assigned_staff_id ? (
                    (staffName.get(r.assigned_staff_id) ?? "—")
                  ) : (
                    <span className="lock">nobody</span>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div className="card" style={{ padding: 0 }}>
        <div style={{ padding: "16px 16px 0" }}>
          <h3 style={{ margin: 0 }}>Where referrals come from</h3>
          <p className="sub" style={{ margin: "4px 0 0" }}>
            By counselor, or by office where no counselor is recorded.
          </p>
        </div>
        <table className="t">
          <thead>
            <tr>
              <th>Source</th>
              <th>Referred</th>
              <th>Reached placement</th>
              <th>Still waiting</th>
            </tr>
          </thead>
          <tbody>
            {bySource.map((s) => (
              <tr key={s.source}>
                <td>{s.source}</td>
                <td>{s.referred}</td>
                <td>
                  {s.placed}
                  {s.referred > 0 && (
                    <span className="lock"> · {Math.round((s.placed / s.referred) * 100)}%</span>
                  )}
                </td>
                <td>{s.waiting || <span className="lock">none</span>}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  );
}
