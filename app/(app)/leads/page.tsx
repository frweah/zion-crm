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

  const [employersResult, leadsResult, matchesResult, staffResult] = await Promise.all([
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
  ]);

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
          ["openings", "Openings"],
          ["employers", "Employers"],
        ]}
      />

      {/* ── Openings ─────────────────────────────────────────── */}
      <section className="page-section" id="openings">
        <h2 className="h2" style={{ marginBottom: 12 }}>Openings</h2>
        {canEdit && (
          <div style={{ marginBottom: 14 }}>
            <AddLeadForm employers={employers} staff={staff} />
          </div>
        )}

        {leads.length === 0 ? (
          <div className="empty">
            No openings yet. Add one from an employer in the directory and start putting clients
            forward.
          </div>
        ) : (
          <div
            className="grid"
            style={{ gridTemplateColumns: `repeat(${LEAD_STATUSES.length}, minmax(190px, 1fr))`, alignItems: "start", overflowX: "auto" }}
          >
            {LEAD_STATUSES.map((status) => {
              const column = leads.filter((l) => l.status === status);
              return (
                <div key={status}>
                  <h3 style={{ fontSize: 13, margin: "0 0 8px" }}>
                    {status}{" "}
                    <span className="chip" style={{ marginLeft: 4 }}>
                      {column.length}
                    </span>
                  </h3>

                  {column.length === 0 && <div className="empty" style={{ fontSize: 12 }}>—</div>}

                  {/* One container per column, an opening to each item. */}
                  {column.length > 0 && (
                    <div className="list">
                      {column.map((l) => (
                        <Link
                          key={l.id}
                          href={`/leads/${l.id}`}
                          className="list-item"
                          style={{ display: "block", padding: 12, textDecoration: "none", color: "inherit" }}
                        >
                          <b style={{ fontSize: 13 }}>{l.title}</b>
                          <div style={{ fontSize: 12, color: "var(--muted)" }}>
                            {employerName.get(l.employer_id) ?? "—"}
                          </div>
                          {(l.wage_range || l.hours_week) && (
                            <div style={{ fontSize: 12, marginTop: 4 }}>
                              {[l.wage_range, l.hours_week && `${l.hours_week} hrs`]
                                .filter(Boolean)
                                .join(" · ")}
                            </div>
                          )}
                          <div style={{ marginTop: 6, display: "flex", gap: 4, flexWrap: "wrap" }}>
                            <span className="chip">
                              {matchCount.get(l.id) ?? 0} client
                              {(matchCount.get(l.id) ?? 0) === 1 ? "" : "s"}
                            </span>
                            {(hiredCount.get(l.id) ?? 0) > 0 && (
                              <span className="chip ok">{hiredCount.get(l.id)} hired</span>
                            )}
                          </div>
                          {l.owner_staff_id && (
                            <div style={{ fontSize: 11, color: "var(--muted)", marginTop: 6 }}>
                              {staffName.get(l.owner_staff_id) ?? ""}
                            </div>
                          )}
                        </Link>
                      ))}
                    </div>
                  )}
                </div>
              );
            })}
          </div>
        )}
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
                      {e.industry && <div style={{ fontSize: 12, color: "var(--muted)" }}>{e.industry}</div>}
                    </>
                  ),
                  contact: (
                    <span style={{ fontSize: 13 }}>
                      {e.contact_name && <div>{e.contact_name}</div>}
                      {e.contact_phone && <div>{e.contact_phone}</div>}
                      {e.contact_email && <div>{e.contact_email}</div>}
                      {!e.contact_name && !e.contact_phone && !e.contact_email && "—"}
                    </span>
                  ),
                  hiring: (
                    <span style={{ fontSize: 12, color: "var(--muted)" }}>
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
