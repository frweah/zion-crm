import Link from "next/link";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import {
  AddEmployerForm,
  AddLeadForm,
  EmployerStatusControl,
  LEAD_STATUSES,
} from "./leads-forms";

const TABS = [
  { key: "board", label: "Board" },
  { key: "employers", label: "Employers" },
];

const CAN_EDIT = ["Admin", "Job Search"];

export default async function LeadsPage({
  searchParams,
}: {
  searchParams: Promise<{ tab?: string }>;
}) {
  const me = await requireStaff();
  const { tab: rawTab } = await searchParams;
  const tab = TABS.some((t) => t.key === rawTab) ? rawTab! : "board";
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

  const header = (
    <>
      <h1 className="h1">Job leads</h1>
      <p className="sub">
        Employers and the openings the team is working. Putting a client forward writes the note on
        their record, so the effort is logged once.
      </p>
      <nav className="tabs">
        {TABS.map((t) => (
          <Link key={t.key} href={`/leads?tab=${t.key}`} className={t.key === tab ? "on" : ""}>
            {t.label}
          </Link>
        ))}
      </nav>
    </>
  );

  if (tab === "employers") {
    const leadsByEmployer = new Map<string, number>();
    for (const l of leads) {
      leadsByEmployer.set(l.employer_id, (leadsByEmployer.get(l.employer_id) ?? 0) + 1);
    }

    return (
      <>
        {header}
        {canEdit && <div style={{ marginBottom: 14 }}><AddEmployerForm /></div>}

        {employers.length === 0 ? (
          <div className="empty">
            No employers yet. Add the businesses the team already talks to — the ones that hire, and
            the ones that do not, so nobody wastes a second call on them.
          </div>
        ) : (
          <div
            className="grid"
            style={{ gridTemplateColumns: "repeat(auto-fit, minmax(300px, 1fr))" }}
          >
            {employers.map((e) => (
              <div key={e.id} className="card">
                <div className="row2" style={{ justifyContent: "space-between" }}>
                  <b>{e.name}</b>
                  <EmployerStatusControl
                    employerId={e.id}
                    status={e.relationship_status}
                    canEdit={canEdit}
                  />
                </div>
                {e.industry && (
                  <div style={{ fontSize: 13, color: "var(--muted)" }}>{e.industry}</div>
                )}
                <div style={{ fontSize: 13, marginTop: 6 }}>
                  {e.contact_name && <div>{e.contact_name}</div>}
                  {e.contact_phone && <div>{e.contact_phone}</div>}
                  {e.contact_email && <div>{e.contact_email}</div>}
                  {e.hiring_pattern && (
                    <div style={{ color: "var(--muted)" }}>{e.hiring_pattern}</div>
                  )}
                </div>
                {e.notes && (
                  <div style={{ fontSize: 12, color: "var(--muted)", marginTop: 6 }}>{e.notes}</div>
                )}
                <div style={{ fontSize: 12, marginTop: 8 }}>
                  {leadsByEmployer.get(e.id) ?? 0} opening
                  {(leadsByEmployer.get(e.id) ?? 0) === 1 ? "" : "s"} on record
                </div>
              </div>
            ))}
          </div>
        )}
      </>
    );
  }

  // ── Board ────────────────────────────────────────────────────
  return (
    <>
      {header}
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

                {column.map((l) => (
                  <Link
                    key={l.id}
                    href={`/leads/${l.id}`}
                    className="card"
                    style={{
                      display: "block",
                      marginBottom: 8,
                      padding: 12,
                      textDecoration: "none",
                      color: "inherit",
                    }}
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
            );
          })}
        </div>
      )}
    </>
  );
}
