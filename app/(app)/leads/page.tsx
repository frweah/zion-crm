import Link from "next/link";
import { redirect } from "next/navigation";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { PageHead } from "../page-head";
import { DataTable } from "../data-table";
import {
  AddEmployerForm,
  AddLeadForm,
  EmployerStatusControl,
  LEAD_STATUSES,
} from "./leads-forms";

const CAN_EDIT = ["Admin", "Job Search"];

/**
 * Jobs: the openings board, then the employers behind them, on one page.
 *
 * They were two tabs of their own under the sidebar's Clients · Jobs tabs,
 * which stacked tabs on tabs. An old link to the employers tab goes to the
 * employers section instead.
 */
export default async function LeadsPage({
  searchParams,
}: {
  searchParams: Promise<{ tab?: string }>;
}) {
  const { tab } = await searchParams;
  if (tab === "employers") redirect("/leads#employers");

  const me = await requireStaff();
  const canEdit = CAN_EDIT.includes(me.role);

  const supabase = await createClient();

  const [employersResult, leadsResult, matchesResult, staffResult, historyResult, clientsResult] = await Promise.all([
    supabase
      .from("employers")
      .select("id, name, industry, relationship_status, contact_name, contact_phone, contact_email, hiring_pattern, notes")
      .order("name"),
    supabase
      .from("job_leads")
      .select("id, employer_id, title, wage_range, hours_week, shift, status, posted_date, owner_staff_id")
      .order("posted_date", { ascending: false, nullsFirst: false }),
    supabase.from("lead_matches").select("id, lead_id, status"),
    supabase.from("staff").select("id, name").eq("active", true).order("name"),
    // Every client's applications and interviews, for the two lists that
    // replace the job-search spreadsheet (0117). What each person may see is
    // the database's decision, as everywhere else.
    supabase
      .from("client_job_history")
      .select("match_id, client_id, status, applied_on, interview_on, interview_time, interview_kind, interview_location, interview_confirmed, interview_result, outcome, notes, title, employer_name, wage_range, hours_week, requisition, posting_url, apply_url")
      .order("applied_on", { ascending: false, nullsFirst: false }),
    supabase.from("clients").select("id, name, assigned_staff_id"),
  ]);
  const history = historyResult.data ?? [];
  const clientById = new Map((clientsResult.data ?? []).map((c) => [c.id, c]));
  const today = new Date().toISOString().slice(0, 10);
  const clock = (t: string | null) => {
    if (!t) return "";
    const [h, m] = t.split(":").map(Number);
    return `${((h + 11) % 12) + 1}:${String(m).padStart(2, "0")} ${h < 12 ? "am" : "pm"}`;
  };
  const interviews = history
    .filter((h) => h.interview_on)
    .sort((a, b) => {
      // Upcoming first, soonest first; then what has happened, latest first.
      const au = a.interview_on! >= today, bu = b.interview_on! >= today;
      if (au !== bu) return au ? -1 : 1;
      return au ? a.interview_on!.localeCompare(b.interview_on!) : b.interview_on!.localeCompare(a.interview_on!);
    });
  const upcoming = interviews.filter((h) => h.interview_on! >= today).length;
  const weekAgo = new Date(Date.now() - 7 * 86400000).toISOString().slice(0, 10);
  const appliedThisWeek = history.filter((h) => h.applied_on && h.applied_on >= weekAgo).length;

  const employers = employersResult.data ?? [];
  const leads = leadsResult.data ?? [];
  const matches = matchesResult.data ?? [];
  const staff = staffResult.data ?? [];

  const employerName = new Map(employers.map((e) => [e.id, e.name]));
  const staffName = new Map(staff.map((s) => [s.id, s.name]));

  const matchCount = new Map<string, number>();
  const hiredCount = new Map<string, number>();
  for (const m of matches) {
    matchCount.set(m.lead_id, (matchCount.get(m.lead_id) ?? 0) + 1);
    if (m.status === "Hired") hiredCount.set(m.lead_id, (hiredCount.get(m.lead_id) ?? 0) + 1);
  }

  const leadsByEmployer = new Map<string, number>();
  for (const l of leads) {
    leadsByEmployer.set(l.employer_id, (leadsByEmployer.get(l.employer_id) ?? 0) + 1);
  }

  return (
    <>
      <PageHead
        title="Jobs"
        context="Employers and the openings the team is working. Putting a client forward writes the note on their record, so the effort is logged once."
        toc={[
          ["interviews", "Interviews"],
          ["applications", "Applications"],
          ["openings", "Openings"],
          ["employers", "Employers"],
        ]}
      />

      {/* ── Interviews ───────────────────────────────────────── */}
      {/*
        The spreadsheet's Interview Schedule tab: every client's interviews in
        one list, the next ones first. Changed on the client's record, where
        the time, whether they confirmed and the result are edited.
      */}
      <section className="page-section" id="interviews">
        <h2 className="h2" style={{ marginBottom: 4 }}>Interviews</h2>
        <p className="sub" style={{ margin: "0 0 12px" }}>
          {upcoming} coming up, then the ones that have happened. Open the client to change one.
        </p>
        <div className="card" style={{ padding: 0 }}>
          <DataTable
            label="interviews"
            pageSize={50}
            columns={[
              { key: "when", label: "When" },
              { key: "client", label: "Client" },
              { key: "job", label: "Job" },
              { key: "where", label: "How and where" },
              { key: "confirmed", label: "Client confirmed" },
              { key: "result", label: "Result" },
            ]}
            rows={interviews.map((h) => {
              const client = clientById.get(h.client_id ?? "");
              const coming = h.interview_on! >= today;
              return {
                key: h.match_id ?? "",
                sort: {
                  when: `${h.interview_on} ${h.interview_time ?? ""}`,
                  client: client?.name ?? "",
                  job: h.employer_name,
                  where: h.interview_kind,
                  confirmed: h.interview_confirmed,
                  result: h.interview_result || h.status,
                },
                text: [client?.name, h.employer_name, h.title, h.interview_kind, h.interview_location, h.interview_confirmed, h.interview_result, h.status].filter(Boolean).join(" "),
                cells: {
                  when: (
                    <span style={{ whiteSpace: "nowrap", fontWeight: coming ? 600 : undefined }}>
                      {h.interview_on}
                      {h.interview_time && <div className="lock">{clock(h.interview_time)}</div>}
                    </span>
                  ),
                  client: client ? (
                    <Link href={`/clients/${h.client_id}?tab=jobs`}>{client.name}</Link>
                  ) : (
                    "—"
                  ),
                  job: (
                    <>
                      <b>{h.employer_name}</b>
                      <div className="lock">{h.title}</div>
                    </>
                  ),
                  where: (
                    <span style={{ fontSize: "var(--text-sm)" }}>
                      {h.interview_kind || "—"}
                      {h.interview_location && <div className="lock">{h.interview_location}</div>}
                    </span>
                  ),
                  confirmed: h.interview_confirmed ? (
                    <span className={"chip " + (h.interview_confirmed === "Confirmed" ? "ok" : "warn")}>{h.interview_confirmed}</span>
                  ) : (
                    <span className="lock">not asked</span>
                  ),
                  result: (
                    <>
                      {h.interview_result ? <span className="chip">{h.interview_result}</span> : <span className="lock">—</span>}
                      <div className="lock">{h.status}</div>
                    </>
                  ),
                },
              };
            })}
            empty="No interviews on record. Set an interview date on a client's job and it appears here."
          />
        </div>
      </section>

      {/* ── Applications ─────────────────────────────────────── */}
      {/*
        The spreadsheet's client tabs, as one list: every application, newest
        first, searchable by client, employer or status.
      */}
      <section className="page-section" id="applications">
        <h2 className="h2" style={{ marginBottom: 4 }}>Applications</h2>
        <p className="sub" style={{ margin: "0 0 12px" }}>
          {history.length} on record, {appliedThisWeek} in the last 7 days. Type a client&apos;s name to see only theirs.
        </p>
        <div className="card" style={{ padding: 0 }}>
          <DataTable
            label="applications"
            pageSize={50}
            columns={[
              { key: "applied", label: "Applied" },
              { key: "client", label: "Client" },
              { key: "job", label: "Job" },
              { key: "pay", label: "Pay and hours" },
              { key: "status", label: "Status" },
            ]}
            rows={history.map((h) => {
              const client = clientById.get(h.client_id ?? "");
              return {
                key: h.match_id ?? "",
                sort: { applied: h.applied_on, client: client?.name ?? "", job: h.employer_name, pay: h.wage_range, status: h.status },
                text: [client?.name, h.employer_name, h.title, h.requisition, h.status, h.outcome, h.notes].filter(Boolean).join(" "),
                cells: {
                  applied: <span style={{ whiteSpace: "nowrap" }}>{h.applied_on ?? "—"}</span>,
                  client: client ? <Link href={`/clients/${h.client_id}?tab=jobs`}>{client.name}</Link> : "—",
                  job: (
                    <>
                      <b>{h.employer_name}</b>
                      <div className="lock">
                        {h.title}
                        {h.requisition && ` · ${h.requisition}`}
                        {(h.apply_url || h.posting_url) && (
                          <>
                            {" · "}
                            <a href={h.apply_url || h.posting_url || undefined} target="_blank" rel="noopener noreferrer">
                              link
                            </a>
                          </>
                        )}
                      </div>
                    </>
                  ),
                  pay: (
                    <span style={{ fontSize: "var(--text-sm)" }}>
                      {[h.wage_range, h.hours_week].filter(Boolean).join(" · ") || "—"}
                    </span>
                  ),
                  status: (
                    <>
                      <span className="chip">{h.status}</span>
                      {h.outcome && <div className="lock">{h.outcome}</div>}
                    </>
                  ),
                },
              };
            })}
            empty="No applications on record yet."
          />
        </div>
      </section>

      {/* ── Openings ─────────────────────────────────────────── */}
      <section className="page-section" id="openings">
        <h2 className="h2" style={{ marginBottom: 12 }}>Openings</h2>
        {canEdit && (
          <div style={{ marginBottom: 14 }}>
            <AddLeadForm employers={employers} staff={staff} />
          </div>
        )}

        {/*
          One table, not a board of status columns: a board cannot be sorted,
          and on a phone its columns were a sideways scroll of narrow cards.
          Status is a column, and the rows start in the board's order - by
          status, newest first within each.
        */}
        <div className="card" style={{ padding: 0 }}>
          <DataTable
            label="openings"
            sortBy
            pageSize={50}
            columns={[
              { key: "title", label: "Opening" },
              { key: "employer", label: "Employer" },
              { key: "status", label: "Status" },
              { key: "pay", label: "Pay and hours" },
              { key: "clients", label: "Clients put forward", align: "right" },
              { key: "owner", label: "Owner" },
              { key: "posted", label: "Posted" },
            ]}
            rows={[...leads]
              .sort(
                (a, b) =>
                  (LEAD_STATUSES as readonly string[]).indexOf(a.status) -
                  (LEAD_STATUSES as readonly string[]).indexOf(b.status),
              )
              .map((l) => {
                const put = matchCount.get(l.id) ?? 0;
                const hired = hiredCount.get(l.id) ?? 0;
                const employer = employerName.get(l.employer_id) ?? "—";
                const owner = l.owner_staff_id ? (staffName.get(l.owner_staff_id) ?? "") : "";
                const pay = [l.wage_range, l.hours_week && (/^[\d\s.\-–]+$/.test(l.hours_week) ? `${l.hours_week} hrs` : l.hours_week)].filter(Boolean).join(" · ");
                return {
                  key: l.id,
                  sort: {
                    title: l.title,
                    employer,
                    status: (LEAD_STATUSES as readonly string[]).indexOf(l.status),
                    pay: l.wage_range,
                    clients: put,
                    owner,
                    posted: l.posted_date,
                  },
                  text: [l.title, employer, l.status, pay, owner].filter(Boolean).join(" "),
                  cells: {
                    title: (
                      <Link href={`/leads/${l.id}`} style={{ fontWeight: 600 }}>
                        {l.title}
                      </Link>
                    ),
                    employer,
                    status: <span className={"chip " + (l.status === "Filled" ? "ok" : "")}>{l.status}</span>,
                    pay: pay || <span className="lock">—</span>,
                    clients: (
                      <>
                        {put}
                        {hired > 0 && (
                          <div>
                            <span className="chip ok">{hired} hired</span>
                          </div>
                        )}
                      </>
                    ),
                    owner: owner || <span className="lock">—</span>,
                    posted: <span style={{ whiteSpace: "nowrap" }}>{l.posted_date ?? "—"}</span>,
                  },
                };
              })}
            empty="No openings yet. Add one from an employer in the directory and start putting clients forward."
          />
        </div>
      </section>

      {/* ── Employers ────────────────────────────────────────── */}
      <section className="page-section" id="employers">
        <h2 className="h2" style={{ marginBottom: 12 }}>Employers</h2>
        {canEdit && (
          <div style={{ marginBottom: 14 }}>
            <AddEmployerForm />
          </div>
        )}

        <div className="card" style={{ padding: 0 }}>
          <DataTable
            label="employers"
            columns={[
              { key: "name", label: "Employer" },
              { key: "contact", label: "Contact" },
              { key: "hiring", label: "Hiring pattern and notes" },
              { key: "openings", label: "Openings", align: "right" },
              { key: "status", label: "Relationship" },
            ]}
            rows={employers.map((e) => {
              const openings = leadsByEmployer.get(e.id) ?? 0;
              return {
                key: e.id,
                sort: {
                  name: e.name,
                  contact: e.contact_name,
                  hiring: e.hiring_pattern,
                  openings,
                  status: e.relationship_status,
                },
                text: [
                  e.name,
                  e.industry,
                  e.contact_name,
                  e.contact_phone,
                  e.contact_email,
                  e.hiring_pattern,
                  e.notes,
                  e.relationship_status,
                ]
                  .filter(Boolean)
                  .join(" "),
                cells: {
                  name: (
                    <>
                      <b>{e.name}</b>
                      {e.industry && <div style={{ fontSize: "var(--text-sm)", color: "var(--muted)" }}>{e.industry}</div>}
                    </>
                  ),
                  contact: (
                    <span style={{ fontSize: "var(--text-md)" }}>
                      {e.contact_name && <div>{e.contact_name}</div>}
                      {e.contact_phone && <div>{e.contact_phone}</div>}
                      {e.contact_email && <div>{e.contact_email}</div>}
                      {!e.contact_name && !e.contact_phone && !e.contact_email && "—"}
                    </span>
                  ),
                  hiring: (
                    <span style={{ fontSize: "var(--text-sm)", color: "var(--muted)" }}>
                      {e.hiring_pattern && <div>{e.hiring_pattern}</div>}
                      {e.notes && <div>{e.notes}</div>}
                      {!e.hiring_pattern && !e.notes && "—"}
                    </span>
                  ),
                  openings,
                  status: (
                    <EmployerStatusControl
                      employerId={e.id}
                      status={e.relationship_status}
                      canEdit={canEdit}
                    />
                  ),
                },
              };
            })}
            empty="No employers yet. Add the businesses the team already talks to — the ones that hire, and the ones that do not, so nobody wastes a second call on them."
          />
        </div>
      </section>
    </>
  );
}
