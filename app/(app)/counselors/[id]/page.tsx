import Link from "next/link";
import { notFound } from "next/navigation";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { today, fmtStamp } from "@/lib/constants";
import { RecordHeader } from "../../record-header";
import { DataTable } from "../../data-table";
import { can } from "@/lib/roles";
import { DirectoryHistory, DIRECTORY_CHANGE_COLUMNS, type DirectoryChange } from "../directory-history";
import { EditCounselorForm, MoveOfficeForm } from "./counselor-edit";

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
  searchParams: Promise<{ show?: string }>;
}) {
  const { id } = await params;
  const { show: rawShow } = await searchParams;
  const me = await requireStaff();
  const canEdit = can(me, "counselors", "edit");

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

  const [
    { data: staff },
    { data: activity },
    { data: next },
    { data: contacts },
    { data: history },
    { data: officeRows },
    { data: billingRows },
  ] = await Promise.all([
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
      supabase
        .from("directory_changes")
        .select(DIRECTORY_CHANGE_COLUMNS)
        .eq("entity", "Counselor")
        .eq("entity_key", id)
        .order("seq", { ascending: false })
        .limit(50),
      supabase.from("offices").select("name, billing_office_id").order("name"),
      supabase.from("billing_offices").select("id, name"),
    ]);

  const billingNames = new Map((billingRows ?? []).map((b) => [b.id, b.name]));
  const officeOptions = (officeRows ?? []).map((o) => ({
    name: o.name,
    billing: billingNames.get(o.billing_office_id) ?? null,
  }));

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

  // Quietest first: never-touched at the top, because they are the ones nobody
  // is going to remember on their own. That is only the order the table opens
  // in - its headings sort by name, stage or what is next when asked.
  const visible = rows
    .filter((r) => (show === "all" ? true : show === "quiet" ? r.quiet : r.status === "Active"))
    .sort((a, b) => {
      const av = a.days ?? Number.MAX_SAFE_INTEGER;
      const bv = b.days ?? Number.MAX_SAFE_INTEGER;
      return bv - av || a.name.localeCompare(b.name);
    });

  const activeCount = rows.filter((r) => r.status === "Active").length;
  const quietCount = rows.filter((r) => r.quiet).length;

  const link = (w: string) => `/counselors/${id}?show=${w}`;

  return (
    <>
      <RecordHeader
        back={{ href: "/counselors?tab=directory", label: "Counselors" }}
        title={counselor.name}
        identity={[counselor.agency, counselor.office, counselor.phone, counselor.email]}
        actions={
          <>
            {canEdit && (
              <a className="btn ghost" href="#details" style={{ textDecoration: "none" }}>
                Edit details
              </a>
            )}
            {counselor.email && (
              <Link className="btn ghost" href={`/mail/compose?counselor=${counselor.id}`} style={{ textDecoration: "none" }}>
                Email {counselor.name.split(" ")[0]}
              </Link>
            )}
            <Link className="btn gold" href="/counselors?tab=contact" style={{ textDecoration: "none" }}>
              Log contact
            </Link>
            <Link className="btn ghost" href="/counselors?tab=contact" style={{ textDecoration: "none" }}>
              Full contact log
            </Link>
          </>
        }
      />

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

      <section className="page-section">
        <h2 className="h2">Caseload</h2>
        <div className="row2 no-print" style={{ alignItems: "center", gap: 8, margin: "8px 0" }}>
          <span className="lock">Show</span>
          <div className="segmented">
            <Link href={link("active")} className={show === "active" ? "on" : undefined}>
              Active
            </Link>
            <Link href={link("quiet")} className={show === "quiet" ? "on" : undefined}>
              Gone quiet
            </Link>
            <Link href={link("all")} className={show === "all" ? "on" : undefined}>
              Everyone
            </Link>
          </div>
        </div>

        <div className="card" style={{ padding: 0 }}>
          <DataTable
            label="clients"
            columns={[
              { key: "client", label: "Client" },
              { key: "stage", label: "Stage" },
              { key: "assigned", label: "Assigned to" },
              { key: "last", label: "Last activity" },
              { key: "next", label: "Next" },
            ]}
            rows={visible.map((r) => {
              const assigned = r.assigned_staff_id ? (staffName.get(r.assigned_staff_id) ?? "—") : "—";
              return {
                key: r.id,
                cells: {
                  client: (
                    <>
                      <Link href={`/clients/${r.id}`} style={{ color: "var(--teal)" }}>
                        <b>{r.name}</b>
                      </Link>
                      <div className="lock">
                        {r.client_no ? `#${r.client_no}` : ""}
                        {r.agency_id ? ` · USOR ID ${r.agency_id}` : ""}
                        {r.status !== "Active" ? ` · ${r.status}` : ""}
                      </div>
                    </>
                  ),
                  stage: <span className="chip">{r.stage}</span>,
                  assigned,
                  last: (
                    <span style={{ whiteSpace: "nowrap" }}>
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
                    </span>
                  ),
                  next: r.next ? (
                    <>
                      {r.next.kind} · {fmtStamp(r.next.at)}
                      <div className="lock">{r.next.title}</div>
                    </>
                  ) : (
                    <Link href={`/clients/${r.id}?tab=activity`} className="lock">
                      nothing booked
                    </Link>
                  ),
                },
                sort: {
                  client: r.name,
                  stage: r.stage,
                  assigned,
                  last: r.last,
                  next: r.next?.at ?? null,
                },
                text: `${r.name} ${r.client_no ?? ""} ${r.agency_id ?? ""} ${r.stage} ${assigned}`,
              };
            })}
            empty={
              rows.length === 0
                ? "No clients are on this counselor's caseload."
                : "Nobody on this caseload matches that choice."
            }
          />
        </div>

        <p className="lock" style={{ marginTop: 10 }}>
          Quiet means nothing recorded for {QUIET_DAYS} days — no note, appointment, email, job
          application, stage change or logged hour. Same measure as the dashboard's inactive-clients list.
        </p>
      </section>

      <section className="page-section">
        <h2 className="h2">Recent contact with {counselor.name.split(" ")[0]}</h2>
        <p className="sub" style={{ margin: "0 0 10px" }}>
          The last fifteen, across the whole caseload.
        </p>
        <div className="card" style={{ padding: 0 }}>
          <DataTable
            label="contacts"
            columns={[
              { key: "date", label: "Date" },
              { key: "method", label: "Method" },
              { key: "client", label: "Client" },
              { key: "topic", label: "Topic" },
            ]}
            rows={(contacts ?? []).map((x) => {
              const client = x.client_id ? (clientName.get(x.client_id) ?? "—") : null;
              return {
                key: x.id,
                cells: {
                  date: <span style={{ whiteSpace: "nowrap" }}>{x.date}</span>,
                  method: <span className="chip">{x.method}</span>,
                  client: x.client_id ? (
                    <Link href={`/clients/${x.client_id}`} style={{ color: "var(--teal)" }}>
                      {client}
                    </Link>
                  ) : (
                    "—"
                  ),
                  topic: (
                    <>
                      {x.topic}
                      {x.outcome && <div className="lock">{x.outcome}</div>}
                    </>
                  ),
                },
                sort: { date: x.date, method: x.method, client, topic: x.topic },
                text: `${x.date} ${x.method} ${client ?? ""} ${x.topic} ${x.outcome ?? ""}`,
              };
            })}
            empty="Nothing has been logged with this counselor yet."
          />
        </div>
      </section>

      {canEdit && (
        <section className="page-section" id="details">
          <h2 className="h2">Details and office</h2>
          <div className="grid" style={{ gap: 14 }}>
            <EditCounselorForm counselor={counselor} />
            <MoveOfficeForm counselor={counselor} offices={officeOptions} clients={rows.length} />
          </div>
        </section>
      )}

      <section className="page-section">
        <h2 className="h2">History</h2>
        <p className="sub" style={{ margin: "0 0 10px" }}>
          Every change to this counselor&apos;s record: who, when, and what it was before.
        </p>
        <div className="card" style={{ padding: 0 }}>
          <DirectoryHistory
            changes={(history ?? []) as DirectoryChange[]}
            billingNames={billingNames}
            showWhat={false}
            empty="No changes recorded since the log began."
          />
        </div>
      </section>

      <p className="lock" style={{ marginTop: 10 }}>
        Internal view. {counselor.name} has no login here — anything they should see is sent to
        them, from the client&apos;s Report tab or as a signed form. Today is {today()}.
      </p>
    </>
  );
}
