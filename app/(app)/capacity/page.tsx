import Link from "next/link";
import { redirect } from "next/navigation";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { money, today } from "@/lib/constants";

/**
 * Capacity.
 *
 * Not "how busy is everyone" — that question has no answer anybody can act
 * on. This one answers "who should the next referral go to", which is a
 * decision somebody has to make every time the phone rings.
 *
 * Admin only, and not out of delicacy: work_session_values shows a person
 * their own hours and shows Admin everybody's, so anyone else would get a
 * screen of zeros for their colleagues and read it as idleness.
 */

const RECENT_DAYS = 30;

type Row = {
  staff_id: string;
  name: string;
  role: string;
  active_clients: number;
  quiet_clients: number;
  front_clients: number;
  open_authorizations: number;
  committed_hours: number;
  committed_value: number;
  hours_30: number;
  hours_90: number;
  client_hours_90: number;
  uncategorised_hours_90: number;
};

export default async function CapacityPage() {
  const me = await requireStaff();
  if (me.role !== "Admin") redirect("/dashboard");

  const supabase = await createClient();

  const [capacityResult, unassignedResult] = await Promise.all([
    supabase.from("staff_capacity").select("*"),
    supabase
      .from("clients")
      .select("id, name, stage")
      .eq("status", "Active")
      .is("assigned_staff_id", null)
      .order("name"),
  ]);

  const rows = ((capacityResult.data ?? []) as unknown as Row[]).sort(
    (a, b) => Number(b.active_clients) - Number(a.active_clients),
  );
  const unassigned = unassignedResult.data ?? [];

  const n = (v: number | null | undefined) => Number(v ?? 0);

  const totals = rows.reduce(
    (t, r) => ({
      clients: t.clients + n(r.active_clients),
      quiet: t.quiet + n(r.quiet_clients),
      hours: t.hours + n(r.hours_30),
      committedHours: t.committedHours + n(r.committed_hours),
      committedValue: t.committedValue + n(r.committed_value),
    }),
    { clients: 0, quiet: 0, hours: 0, committedHours: 0, committedValue: 0 },
  );

  // Months of work in hand at the rate people are actually logging. Only
  // meaningful once anybody is logging — a rate of nothing divides into any
  // backlog for ever, which is a true statement and a useless one.
  const monthlyRate = totals.hours; // hours in the last 30 days
  const monthsInHand =
    monthlyRate > 0 ? Math.round((totals.committedHours / monthlyRate) * 10) / 10 : null;

  const carrying = rows.filter((r) => n(r.active_clients) > 0);
  const concentrated =
    carrying.length === 1 && rows.length > 1 ? carrying[0] : null;

  return (
    <>
      <h1 className="h1">Capacity</h1>
      <p className="sub">
        Who is carrying what, what is owed on it, and what is actually being delivered
      </p>

      <div
        className="grid"
        style={{ gridTemplateColumns: "repeat(auto-fit, minmax(200px, 1fr))", margin: "14px 0 8px" }}
      >
        <div className="card">
          <div className="stat">
            {totals.clients}
            <small>active clients carried</small>
          </div>
        </div>
        <div className="card">
          <div className="stat" style={totals.quiet > 0 ? { color: "var(--bad)" } : undefined}>
            {totals.quiet}
            <small>of them untouched in 30 days</small>
          </div>
        </div>
        <div className="card">
          <div className="stat">
            {n(totals.committedHours).toFixed(0)}
            <small>hours owed on open authorizations</small>
          </div>
          <p className="lock" style={{ margin: "6px 0 0" }}>
            Plus {money(totals.committedValue)} of authorized work in total, flat fees included.
          </p>
        </div>
        <div className="card">
          <div className="stat">
            {monthsInHand === null ? "—" : monthsInHand}
            <small>months of work in hand</small>
          </div>
          <p className="lock" style={{ margin: "6px 0 0" }}>
            {monthlyRate > 0
              ? `At ${monthlyRate.toFixed(1)} hours logged in the last ${RECENT_DAYS} days.`
              : "Nothing has been logged in the last 30 days, so there is no rate to divide by."}
          </p>
        </div>
      </div>

      {concentrated && (
        <div className="alert bad" style={{ marginBottom: 18 }}>
          <b>Every active client is assigned to {concentrated.name}.</b> All{" "}
          {n(concentrated.active_clients)} of them, including{" "}
          {n(concentrated.front_clients)} still at the front of the pipeline and{" "}
          {n(concentrated.quiet_clients)} nothing has happened to in a month. Either the caseload
          really does sit with one person, or the migration assigned everybody to whoever imported
          the workbook — worth checking before reading anything else on this page.{" "}
          <Link href="/clients">Reassign from the clients list</Link>.
        </div>
      )}

      {unassigned.length > 0 && (
        <div className="alert" style={{ marginBottom: 18 }}>
          <b>{unassigned.length} active clients are assigned to nobody.</b> They appear on no
          caseload and in nobody&apos;s needs list:{" "}
          {unassigned.slice(0, 6).map((c, i) => (
            <span key={c.id}>
              {i > 0 && ", "}
              <Link href={`/clients/${c.id}`}>{c.name}</Link>
            </span>
          ))}
          {unassigned.length > 6 && `, and ${unassigned.length - 6} more`}.
        </div>
      )}

      <div className="card" style={{ marginBottom: 18, padding: 0 }}>
        <div style={{ padding: "16px 16px 0" }}>
          <h3 style={{ margin: 0 }}>By person</h3>
          <p className="sub" style={{ margin: "4px 0 0" }}>
            Hours owed are hourly authorizations only — a flat fee is money owed with no hours
            attached to it, so it is counted in the value and not in the hours.
          </p>
        </div>
        <table className="t">
          <thead>
            <tr>
              <th>Person</th>
              <th>Caseload</th>
              <th>Owed</th>
              <th>Delivered</th>
              <th>Reaching a client</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => {
              const known = n(r.hours_90) - n(r.uncategorised_hours_90);
              const share = known > 0 ? Math.round((n(r.client_hours_90) / known) * 100) : null;
              return (
                <tr key={r.staff_id}>
                  <td>
                    <b>{r.name}</b>
                    <div className="lock">{r.role}</div>
                  </td>
                  <td>
                    {n(r.active_clients)} active
                    <div className="lock">
                      {n(r.quiet_clients) > 0 && (
                        <span style={{ color: "var(--bad)" }}>
                          {n(r.quiet_clients)} quiet
                        </span>
                      )}
                      {n(r.quiet_clients) > 0 && n(r.front_clients) > 0 && " · "}
                      {n(r.front_clients) > 0 && `${n(r.front_clients)} at the front`}
                      {n(r.quiet_clients) === 0 && n(r.front_clients) === 0 && "all moving"}
                    </div>
                  </td>
                  <td>
                    {n(r.committed_hours) > 0 ? (
                      <>
                        {n(r.committed_hours).toFixed(0)} hrs
                        <div className="lock">{money(n(r.committed_value))}</div>
                      </>
                    ) : n(r.committed_value) > 0 ? (
                      <>
                        {money(n(r.committed_value))}
                        <div className="lock">flat fees, no hours</div>
                      </>
                    ) : (
                      <span className="lock">nothing</span>
                    )}
                  </td>
                  <td>
                    {n(r.hours_30).toFixed(2)} hrs
                    <div className="lock">last {RECENT_DAYS} days</div>
                  </td>
                  <td>
                    {share === null ? (
                      <span className="lock">nothing says what it was</span>
                    ) : (
                      <>
                        {share}%
                        <div className="lock">
                          of {known.toFixed(1)} categorised hours in 90 days
                          {n(r.uncategorised_hours_90) > 0 &&
                            ` · ${n(r.uncategorised_hours_90).toFixed(1)} not said`}
                        </div>
                      </>
                    )}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>

      <div className="card">
        <h3 style={{ marginTop: 0 }}>How to read this</h3>
        <p className="sub" style={{ marginTop: 0 }}>
          Three separate questions, deliberately not added into one score.
        </p>
        <ul style={{ margin: 0, paddingLeft: 20, fontSize: 13, lineHeight: 1.6 }}>
          <li>
            <b>Caseload</b> is how many people are counting on them. A large one with everybody
            moving is fine; a small one where half is quiet is not.
          </li>
          <li>
            <b>Owed</b> is the work USOR has already authorized on their clients. This is the
            backlog that has to be delivered before it expires, and it is the closest thing here
            to a commitment.
          </li>
          <li>
            <b>Delivered</b> is what they have actually logged. Where that is far below what is
            owed, the constraint is time, not referrals — and taking another referral makes it
            worse rather than better.
          </li>
        </ul>
        <p className="lock" style={{ margin: "10px 0 0" }}>
          Read on {today()}. Quiet means nothing recorded for 30 days, the same measure the needs
          list and the counselor caseload use.
        </p>
      </div>
    </>
  );
}
