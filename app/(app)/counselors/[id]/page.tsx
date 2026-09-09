import Link from "next/link";
import { notFound } from "next/navigation";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { today, fmtStamp } from "@/lib/constants";

/**
 * One counselor's caseload, for us.
 *
 * This is an internal screen, not a counselor login — the question it answers
 * is the one asked on the phone: "how are my people doing?" A counselor calls
 * about ten clients at once, and the answer has been ten trips through the
 * client list.
 *
 * Quiet is thirty days, the same figure the needs list uses, and it reads the
 * same view. One definition of quiet, or the two screens will disagree in
 * front of somebody.
 */
const QUIET_DAYS = 30;

const SORTS = [
  { key: "quiet", label: "Quietest first" },
  { key: "name", label: "Name" },
  { key: "stage", label: "Stage" },
  { key: "next", label: "What is next" },
];

function daysSince(iso: string | null): number | null {
  if (!iso) return null;
  const then = new Date(iso).getTime();
  if (Number.isNaN(then)) return null;
  return Math.floor((Date.now() - then) / 86400000);
}

export default async function CounselorCaseloadPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ sort?: string; show?: string }>;
}) {
  const { id } = await params;
  const { sort: rawSort, show: rawShow } = await searchParams;
  await requireStaff();

  const sort = SORTS.some((s) => s.key === rawSort) ? rawSort! : "quiet";
  const show = rawShow === "all" ? "all" : rawShow === "quiet" ? "quiet" : "active";

  const supabase = await createClient();

  const { data: counselor } = await supabase
    .from("counselors")
    .select("id, name, agency, office, phone, fax, email, notes")
    .eq("id", id)
    .maybeSingle();

  if (!counselor) notFound();

  const { data: clientRows } = await supabase
    .from("clients")
    .select("id, name, client_no, agency_id, stage, status, assigned_staff_id")
    .eq("counselor_id", id)
    .order("name");

  const clients = clientRows ?? [];
  const ids = clients.map((c) => c.id);
  const none = ["00000000-0000-0000-0000-000000000000"];

  const [{ data: staff }, { data: activity }, { data: next }, { data: contacts }] =
    await Promise.all([
      supabase.from("staff").select("id, name"),
      supabase
        .from("client_last_activity")
        .select("client_id, last_activity_at")
        .in("client_id", ids.length ? ids : none),
      supabase
        .from("client_next_up")
        .select("client_id, at, kind, title")
        .in("client_id", ids.length ? ids : none),
      supabase
        .from("contact_log")
        .select("id, client_id, date, method, topic, outcome")
        .eq("counselor_id", id)
        .order("date", { ascending: false })
        .limit(15),
    ]);

  const staffName = new Map((staff ?? []).map((s) => [s.id, s.name]));
  const lastBy = new Map((activity ?? []).map((a) => [a.client_id, a.last_activity_at]));
  const nextBy = new Map((next ?? []).map((n) => [n.client_id, n]));
  const clientName = new Map(clients.map((c) => [c.id, c.name]));

  const rows = clients.map((c) => {
    const last = lastBy.get(c.id) ?? null;
    const days = daysSince(last);
    return {
      ...c,
      last,
      days,
      quiet: c.status === "Active" && (days === null || days >= QUIET_DAYS),
      next: nextBy.get(c.id) ?? null,
    };
  });

  const visible = rows
    .filter((r) => (show === "all" ? true : show === "quiet" ? r.quiet : r.status === "Active"))
    .sort((a, b) => {
      if (sort === "name") return a.name.localeCompare(b.name);
      if (sort === "stage") return a.stage.localeCompare(b.stage) || a.name.localeCompare(b.name);
      if (sort === "next") {
        // Something booked beats nothing booked, soonest first.
        if (!a.next && !b.next) return a.name.localeCompare(b.name);
        if (!a.next) return 1;
        if (!b.next) return -1;
        return (a.next.at ?? "").localeCompare(b.next.at ?? "");
      }
      // Quietest first: never-touched at the top, because they are the ones
      // nobody is going to remember on their own.
      const av = a.days ?? Number.MAX_SAFE_INTEGER;
      const bv = b.days ?? Number.MAX_SAFE_INTEGER;
      return bv - av || a.name.localeCompare(b.name);
    });

  const activeCount = rows.filter((r) => r.status === "Active").length;
  const quietCount = rows.filter((r) => r.quiet).length;

  const link = (s: string, w: string) => `/counselors/${id}?sort=${s}&show=${w}`;

  return (
    <>
      <p className="sub" style={{ marginBottom: 8 }}>
        <Link href="/counselors?tab=directory" style={{ color: "var(--teal)" }}>
          ← Counselors
        </Link>
      </p>

      <h1 className="h1">{counselor.name}</h1>
      <p className="sub">
        {counselor.agency}
        {counselor.office && ` · ${counselor.office}`}
        {counselor.phone && ` · ${counselor.phone}`}
        {counselor.email && ` · ${counselor.email}`}
      </p>

      <div className="grid" style={{ gridTemplateColumns: "repeat(3, 1fr)", margin: "12px 0" }}>
        <div className="card">
          <div className="stat">
            {activeCount}
            <small>active clients</small>
          </div>
        </div>
        <div className="card">
          <div className="stat" style={quietCount > 0 ? { color: "var(--bad)" } : undefined}>
            {quietCount}
            <small>nothing in {QUIET_DAYS} days</small>
          </div>
        </div>
        <div className="card">
          <div className="stat">
            {rows.length}
            <small>on the caseload in total</small>
          </div>
        </div>
      </div>

      <div className="card" style={{ marginBottom: 12 }}>
        <div className="row2">
          <div className="field" style={{ marginBottom: 0 }}>
            Show
            <div className="tabs" style={{ margin: "4px 0 0", borderBottom: 0 }}>
              <Link href={link(sort, "active")} className={show === "active" ? "on" : ""}>
                Active
              </Link>
              <Link href={link(sort, "quiet")} className={show === "quiet" ? "on" : ""}>
                Gone quiet
              </Link>
              <Link href={link(sort, "all")} className={show === "all" ? "on" : ""}>
                Everyone
              </Link>
            </div>
          </div>

          <div className="field" style={{ marginBottom: 0 }}>
            Sort
            <div className="tabs" style={{ margin: "4px 0 0", borderBottom: 0, flexWrap: "wrap" }}>
              {SORTS.map((s) => (
                <Link key={s.key} href={link(s.key, show)} className={sort === s.key ? "on" : ""}>
                  {s.label}
                </Link>
              ))}
            </div>
          </div>
        </div>
      </div>

      <div className="card" style={{ padding: 0 }}>
        <table className="t">
          <thead>
            <tr>
              <th>Client</th>
              <th>Stage</th>
              <th>Assigned to</th>
              <th>Last activity</th>
              <th>Next</th>
            </tr>
          </thead>
          <tbody>
            {visible.length === 0 && (
              <tr>
                <td colSpan={5} className="empty">
                  {rows.length === 0
                    ? "No clients on this counselor's caseload."
                    : "Nobody matches that filter."}
                </td>
              </tr>
            )}
            {visible.map((r) => (
              <tr key={r.id}>
                <td>
                  <Link href={`/clients/${r.id}`} style={{ color: "var(--teal)" }}>
                    <b>{r.name}</b>
                  </Link>
                  <div className="lock">
                    {r.client_no ? `#${r.client_no}` : ""}
                    {r.agency_id ? ` · USOR ID ${r.agency_id}` : ""}
                    {r.status !== "Active" ? ` · ${r.status}` : ""}
                  </div>
                </td>
                <td>
                  <span className="chip">{r.stage}</span>
                </td>
                <td>{r.assigned_staff_id ? (staffName.get(r.assigned_staff_id) ?? "—") : "—"}</td>
                <td style={{ whiteSpace: "nowrap" }}>
                  {r.last ? (
                    <>
                      <span className={"chip " + (r.quiet ? "bad" : "")}>
                        {r.days === 0 ? "today" : `${r.days} days ago`}
                      </span>
                      <div className="lock">{r.last.slice(0, 10)}</div>
                    </>
                  ) : (
                    <span className={"chip " + (r.quiet ? "bad" : "")}>nothing recorded</span>
                  )}
                </td>
                <td>
                  {r.next ? (
                    <>
                      {r.next.kind} · {fmtStamp(r.next.at)}
                      <div className="lock">{r.next.title}</div>
                    </>
                  ) : (
                    <Link href={`/clients/${r.id}?tab=tasks`} className="lock">
                      nothing booked
                    </Link>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <p className="lock" style={{ marginTop: 10 }}>
        Quiet means nothing recorded for {QUIET_DAYS} days — no note, appointment, email, job
        application, stage change or logged hour. Same measure as the Needs attention screen.
      </p>

      <div className="card" style={{ marginTop: 14, padding: 0 }}>
        <div style={{ padding: "16px 16px 0" }}>
          <h3 style={{ margin: 0 }}>Recent contact with {counselor.name.split(" ")[0]}</h3>
          <p className="sub" style={{ margin: "4px 0 0" }}>
            The last fifteen, across the whole caseload.{" "}
            <Link href="/counselors">Full contact log</Link>
          </p>
        </div>
        <table className="t">
          <tbody>
            {(contacts ?? []).length === 0 && (
              <tr>
                <td className="empty">Nothing logged with this counselor yet.</td>
              </tr>
            )}
            {(contacts ?? []).map((x) => (
              <tr key={x.id}>
                <td style={{ whiteSpace: "nowrap" }}>{x.date}</td>
                <td>
                  <span className="chip">{x.method}</span>
                </td>
                <td>
                  {x.client_id ? (
                    <Link href={`/clients/${x.client_id}`} style={{ color: "var(--teal)" }}>
                      {clientName.get(x.client_id) ?? "—"}
                    </Link>
                  ) : (
                    "—"
                  )}
                </td>
                <td>
                  {x.topic}
                  {x.outcome && <div className="lock">{x.outcome}</div>}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <p className="lock" style={{ marginTop: 10 }}>
        Internal view. {counselor.name} has no login here — anything they should see is sent to
        them, from the client&apos;s Report tab or as a signed form. Today is {today()}.
      </p>
    </>
  );
}
